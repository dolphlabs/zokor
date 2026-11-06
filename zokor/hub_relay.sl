// A Hub across instances.
//
// A hub only reaches the sockets of its own process, so behind a balancer
// a message reaches whoever happens to be connected to the same instance.
// share() joins it to a Redis pub/sub channel:
//
//     let hub = zokor.new_hub();
//     hub.share(redis_url, "chat")?;      // then use the hub as before
//
// Every broadcast, to_room and emit then goes to the local sockets at
// once, as it always did, and to Redis. Each instance's listener delivers
// what the others sent. What it promises, and what it does not:
//
//   - a send never waits: it queues for a publisher task, and when Redis
//     falls behind by relay_capacity messages, new ones are dropped and
//     counted. Local sockets get theirs regardless;
//   - delivery between instances is at most once, as Redis pub/sub is: an
//     instance reconnecting misses what was sent meanwhile. relay_losses
//     counts what it can see. A message that must arrive needs a table;
//   - a send's return value counts this instance's sockets only;
//   - rooms and membership stay per instance: room_size and count do not
//     add up other instances' sockets;
//   - anyone who can publish on the channel can send to your sockets, so
//     treat Redis as part of your trusted network, as sessions do.

import "encoding";
import "proc";
import "redis";
import "time";

// One message between instances. `room` is "" for the whole hub.
gc struct HubWire {
    from: str,
    kind: str,
    room: str,
    // The text, or a Socket.IO event's arguments as JSON.
    text: str,
    except: str,
    namespace: str,
    name: str,
    // Binary parts, base64.
    data: [str],
}

pub struct RelayLosses {
    // Not sent: Redis was behind and the queue was full.
    dropped: int,
    // Sent to Redis, which refused or did not answer.
    lost: int,
    // Received, and not something a hub sends.
    malformed: int,
    // Times the subscription was lost and made again; what was published
    // during each is missed.
    reconnects: int,
}

gc struct HubRelay {
    pool: redis.Pool,
    url: str,
    channel: str,
    outbox: chan[str],
    lock: mutex,
    stopped: bool,
    dropped: int,
    lost: int,
    malformed: int,
    reconnects: int,
}

fn relay_capacity() -> int {
    return 1024;
}

fn relay_connect_timeout() -> int {
    return 2000000000;
}

fn relay_publish_timeout() -> int {
    return 1000000000;
}

// How often a parked listener looks up to see whether to stop.
fn relay_poll() -> int {
    return 250000000;
}

fn relay_no_patterns() -> [str] {
    let none_yet: [str] = [];
    return none_yet;
}

fn room_all() -> str {
    return "";
}

fn relay_no_data() -> [str] {
    let nothing: [str] = [];
    return nothing;
}

fn relay_text(room: str, text: str, except: str) -> HubWire {
    return HubWire { from: "", kind: "text", room: room, text: text, except: except,
                     namespace: "", name: "", data: relay_no_data() };
}

fn relay_binary(room: str, b: bytes, except: str) -> HubWire {
    return HubWire { from: "", kind: "binary", room: room, text: "", except: except,
                     namespace: "", name: "", data: [encoding.base64_encode(b)] };
}

fn relay_event(room: str, namespace: str, name: str, args_json: str, except: str) -> HubWire {
    return HubWire { from: "", kind: "event", room: room, text: args_json, except: except,
                     namespace: namespace, name: name, data: relay_no_data() };
}

fn relay_binary_event(room: str, namespace: str, name: str, args_json: str, data: [bytes],
                      except: str) -> HubWire {
    let parts: [str] = [];
    for d in data {
        push(parts, encoding.base64_encode(d));
    }
    return HubWire { from: "", kind: "binary_event", room: room, text: args_json, except: except,
                     namespace: namespace, name: name, data: parts };
}

fn relay_unpack(parts: [str]) -> result[[bytes], str] {
    let out: [bytes] = [];
    for p in parts {
        let d = encoding.base64_decode(p);
        guard let b = d else {
            return err("not base64");
        }
        push(out, b);
    }
    return ok(out);
}

impl HubRelay {
    // Under the lock the channel closes under, so a send racing stop()
    // never lands on a closed channel. The send cannot block: it has a
    // default.
    fn queue(self: HubRelay, text: str) {
        mutex_lock(self.lock);
        if self.stopped {
            mutex_unlock(self.lock);
            return;
        }
        select {
            case chan_send(self.outbox, text) { }
            default {
                self.dropped = self.dropped + 1;
            }
        }
        mutex_unlock(self.lock);
    }

    fn stop(self: HubRelay) {
        mutex_lock(self.lock);
        self.stopped = true;
        chan_close(self.outbox);
        mutex_unlock(self.lock);
    }

    fn stopping(self: HubRelay) -> bool {
        mutex_lock(self.lock);
        let s = self.stopped;
        mutex_unlock(self.lock);
        return s || proc.shutdown_requested();
    }

    fn count_lost(self: HubRelay) {
        mutex_lock(self.lock);
        self.lost = self.lost + 1;
        mutex_unlock(self.lock);
    }

    fn count_malformed(self: HubRelay) {
        mutex_lock(self.lock);
        self.malformed = self.malformed + 1;
        mutex_unlock(self.lock);
    }

    fn count_reconnect(self: HubRelay) {
        mutex_lock(self.lock);
        self.reconnects = self.reconnects + 1;
        mutex_unlock(self.lock);
    }

    fn losses(self: HubRelay) -> RelayLosses {
        mutex_lock(self.lock);
        let l = RelayLosses { dropped: self.dropped, lost: self.lost, malformed: self.malformed,
                              reconnects: self.reconnects };
        mutex_unlock(self.lock);
        return l;
    }
}

fn relay_publisher(rl: HubRelay) {
    while true {
        let m = chan_recv(rl.outbox);
        guard let text = m else {
            return;
        }
        let r = redis.pool_do(rl.pool, [to_bytes("PUBLISH"), to_bytes(rl.channel), to_bytes(text)],
                              until_of(time.mono() + relay_publish_timeout()));
        guard let _n = r else {
            rl.count_lost();
            continue;
        }
    }
}

fn relay_listener(h: Hub, rl: HubRelay, first: redis.Sub) {
    let sub = first;
    while !rl.stopping() {
        let r = redis.sub_next(sub, until_of(time.mono() + relay_poll()));
        guard let got = r else {
            redis.sub_close(sub);
            rl.count_reconnect();
            let back = relay_reconnect(rl);
            guard let fresh = back else {
                return;
            }
            sub = fresh;
            continue;
        }
        if let m = got {
            h.relay_receive(rl, to_str(m.payload));
        }
    }
    redis.sub_close(sub);
}

// A subscription again, retrying once a second; none when told to stop.
fn relay_reconnect(rl: HubRelay) -> opt[redis.Sub] {
    while !rl.stopping() {
        let sr = redis.subscribe(rl.url, [rl.channel], relay_no_patterns(),
                                 until_of(time.mono() + relay_connect_timeout()));
        if let sub = sr {
            return some(sub);
        }
        time.sleep(1000000000);
    }
    return none;
}
