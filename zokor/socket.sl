// A live connection the serve loop holds open after an upgrade, and the
// hub that lets one connection's handler reach the others.
//
// Anything may send to a Socket from any task -- its own message
// handler, another connection's, a background job -- because nothing
// sends on the connection directly: a send queues the message and the
// connection's writer task (ws_serve.sl) puts it on the wire. A send
// never waits. A client that stops reading fills its queue
// (WsRules.max_queue), and is then closed rather than allowed to hold
// memory, or a broadcaster, hostage.

import "http";
import "internal/sio";

// One queued message. `kind`: 0 a text message, 1 a binary message, 2 a
// WebSocket frame already encoded (the connection's own pongs and pings),
// 3 the close the socket's close_code and close_reason describe.
// Socket.IO queues Engine.IO packets as text, and binary attachments as
// binary; the transport decides how each goes on the wire.
gc struct Out {
    kind: int,
    text: str,
    data: bytes,
}

pub gc struct Socket {
    // Unique for the life of the process: "ws_" or a Socket.IO session id.
    id: str,
    // The route pattern it was opened on, and the subprotocol selected.
    route: str,
    protocol: str,
    client_ip: str,
    // What the handshake's hooks put on the request (c.set_local): the
    // authenticated user, a tenant. Copied when the socket opens, so it
    // never changes under a handler; set_local below adds to it.
    locals: map[str]str,
    lock: mutex,
    out: chan[Out],
    open: bool,
    // Why it stopped taking messages: "" while open, "closed" after
    // close(), "overflow" when its queue filled.
    ended: str,
    close_code: int,
    close_reason: str,
    // Hubs it was added to, so the connection's end removes it from each.
    hubs: [Hub],
    // Socket.IO only: the namespaces this session has connected to.
    namespaces: map[str]bool,
    // Its route's index in Router.sockets, and the 101 its handshake
    // answers with (c.accept_ws()).
    handler: int,
    handshake: http.Response,
    // A Socket.IO session: it takes events (emit), not raw messages.
    sio: bool,
}

fn new_socket(id: str, route: str, protocol: str, client_ip: str,
              locals: map[str]str, max_queue: int, handler: int,
              handshake: http.Response) -> Socket {
    let q = max_queue;
    if q < 1 {
        q = 1;
    }
    let out: chan[Out] = make_chan(q);
    let no_hubs: [Hub] = [];
    let no_ns: map[str]bool = {};
    return Socket {
        id: id,
        route: route,
        protocol: protocol,
        client_ip: client_ip,
        locals: locals,
        lock: make_mutex(),
        out: out,
        open: true,
        ended: "",
        close_code: 0,
        close_reason: "",
        hubs: no_hubs,
        namespaces: no_ns,
        handler: handler,
        handshake: handshake,
        sio: false
    };
}

impl Socket {
    // Queues a text message. false when the socket is closed, or when its
    // queue was full -- which closes it -- or when it is a Socket.IO
    // session, whose client expects Engine.IO packets: use emit there.
    pub fn send_text(self: Socket, s: str) -> bool {
        if self.sio {
            return false;
        }
        return self.enqueue(Out { kind: 0, text: s, data: b"" });
    }

    pub fn send_binary(self: Socket, b: bytes) -> bool {
        if self.sio {
            return false;
        }
        return self.enqueue(Out { kind: 1, text: "", data: b });
    }

    // An Engine.IO packet, as is.
    fn send_packet(self: Socket, p: str) -> bool {
        return self.enqueue(Out { kind: 0, text: p, data: b"" });
    }

    // Socket.IO: `emit(name, ...args)` on a namespace ("/" by default).
    // `args_json` is the arguments as the inside of a JSON array, encoded
    // by the caller: `"\"hi\", 3"`, or "" for none.
    pub fn emit(self: Socket, namespace: str, name: str, args_json: str) -> bool {
        return self.send_packet(sio.event(namespace, name, args_json));
    }

    // The same, asking the client to acknowledge: its answer arrives as
    // an Ack event carrying `id`.
    pub fn emit_with_ack(self: Socket, namespace: str, name: str, args_json: str,
                         id: int) -> bool {
        return self.send_packet(sio.event_with_ack(namespace, name, args_json, id));
    }

    // The answer to a client event that asked for one (SioEvent.ack >= 0).
    pub fn ack(self: Socket, namespace: str, id: int, args_json: str) -> bool {
        return self.send_packet(sio.ack(namespace, id, args_json));
    }

    // Disconnects the client from one namespace; the session stays.
    pub fn disconnect_ns(self: Socket, namespace: str) -> bool {
        mutex_lock(self.lock);
        let was = has(self.namespaces, namespace);
        if was {
            del(self.namespaces, namespace);
        }
        mutex_unlock(self.lock);
        if !was {
            return false;
        }
        return self.send_packet(sio.disconnect(namespace));
    }

    // Starts the closing handshake with `code` (1000 normal, 1001 going
    // away, 1008 policy, 4000-4999 the application's own) and stops
    // taking messages. Whatever was queued before it is still sent first.
    pub fn close(self: Socket, code: int, reason: str) -> bool {
        mutex_lock(self.lock);
        if !self.open {
            mutex_unlock(self.lock);
            return false;
        }
        self.close_code = code;
        self.close_reason = reason;
        let sent = false;
        let o = Out { kind: 3, text: reason, data: b"" };
        select {
            case chan_send(self.out, o) { sent = true; }
            default { }
        }
        self.open = false;
        self.ended = "closed";
        chan_close(self.out);
        mutex_unlock(self.lock);
        return sent;
    }

    pub fn is_open(self: Socket) -> bool {
        mutex_lock(self.lock);
        let o = self.open;
        mutex_unlock(self.lock);
        return o;
    }

    // A value the handshake's hooks set on the request, "" when none did.
    pub fn local(self: Socket, key: str) -> str {
        mutex_lock(self.lock);
        let v = "";
        if has(self.locals, key) {
            v = self.locals[key];
        }
        mutex_unlock(self.lock);
        return v;
    }

    pub fn set_local(self: Socket, key: str, v: str) -> int {
        mutex_lock(self.lock);
        self.locals[key] = v;
        mutex_unlock(self.lock);
        return 0;
    }

    // Never waits: a full queue is a client that is not reading, and it
    // is closed (1008 is what its close frame would say, but there is no
    // room for one) instead of making the sender wait for it.
    fn enqueue(self: Socket, o: Out) -> bool {
        mutex_lock(self.lock);
        if !self.open {
            mutex_unlock(self.lock);
            return false;
        }
        let sent = false;
        select {
            case chan_send(self.out, o) { sent = true; }
            default { }
        }
        if !sent {
            self.open = false;
            self.ended = "overflow";
            self.close_code = 1008;
            self.close_reason = "too slow: send queue full";
            chan_close(self.out);
        }
        mutex_unlock(self.lock);
        return sent;
    }

    // The connection's own frames (pong, ping, the close echo). Dropped
    // rather than queued when the socket has stopped taking messages:
    // the writer is then draining towards its end.
    fn enqueue_frame(self: Socket, frame: bytes) -> bool {
        if len(frame) == 0 {
            return true;
        }
        return self.enqueue(Out { kind: 2, text: "", data: frame });
    }

    // The connection is over: stop taking messages and let the writer
    // finish what was queued.
    fn finish(self: Socket, why: str) {
        mutex_lock(self.lock);
        if self.open {
            self.open = false;
            self.ended = why;
            chan_close(self.out);
        }
        mutex_unlock(self.lock);
    }

    fn joined(self: Socket, h: Hub) {
        mutex_lock(self.lock);
        let i = 0;
        let seen = false;
        while i < len(self.hubs) {
            if self.hubs[i].id == h.id {
                seen = true;
            }
            i = i + 1;
        }
        if !seen {
            push(self.hubs, h);
        }
        mutex_unlock(self.lock);
    }

    fn hubs_now(self: Socket) -> [Hub] {
        mutex_lock(self.lock);
        let out: [Hub] = [];
        for h in self.hubs {
            push(out, h);
        }
        mutex_unlock(self.lock);
        return out;
    }
}

// ---------------------------------------------------------------- //
// Hub                                                                //
// ---------------------------------------------------------------- //

// Sockets by id, and rooms of them: what a chat, a live dashboard or a
// notification fan-out needs to reach more than the one connection a
// handler was called for. In-process: a service on several instances
// needs its own fan-out between them (Redis pub/sub, say) on top.
//
//     let hub = zokor.new_hub();          // in the app's state
//     hub.add(sock);                      // on open
//     hub.join_room(sock, "room:42");
//     hub.to_room("room:42", "hello", sock.id);   // everyone else
//
// A socket leaves every hub it was added to when its connection ends.
pub gc struct Hub {
    id: str,
    lock: mutex,
    sockets: map[str]Socket,
    rooms: map[str]map[str]bool,
}

pub fn new_hub() -> Hub {
    let s: map[str]Socket = {};
    let r: map[str]map[str]bool = {};
    return Hub { id: new_session_id(), lock: make_mutex(), sockets: s, rooms: r };
}

impl Hub {
    pub fn add(self: Hub, s: Socket) -> int {
        mutex_lock(self.lock);
        self.sockets[s.id] = s;
        mutex_unlock(self.lock);
        s.joined(self);
        return len(self.sockets);
    }

    // Takes the socket out of the hub and every room in it.
    pub fn remove(self: Hub, s: Socket) -> int {
        mutex_lock(self.lock);
        if has(self.sockets, s.id) {
            del(self.sockets, s.id);
        }
        let empty: [str] = [];
        for name, members in self.rooms {
            if has(members, s.id) {
                del(members, s.id);
                if len(members) == 0 {
                    push(empty, name);
                }
            }
        }
        for name in empty {
            del(self.rooms, name);
        }
        mutex_unlock(self.lock);
        return 0;
    }

    // Puts the socket in a room (adding it to the hub first if needed).
    pub fn join_room(self: Hub, s: Socket, room: str) -> int {
        mutex_lock(self.lock);
        self.sockets[s.id] = s;
        if !has(self.rooms, room) {
            let m: map[str]bool = {};
            self.rooms[room] = m;
        }
        let members = self.rooms[room];
        members[s.id] = true;
        let n = len(members);
        mutex_unlock(self.lock);
        s.joined(self);
        return n;
    }

    pub fn leave_room(self: Hub, s: Socket, room: str) -> int {
        mutex_lock(self.lock);
        let n = 0;
        if has(self.rooms, room) {
            let members = self.rooms[room];
            if has(members, s.id) {
                del(members, s.id);
            }
            n = len(members);
            if n == 0 {
                del(self.rooms, room);
            }
        }
        mutex_unlock(self.lock);
        return n;
    }

    pub fn count(self: Hub) -> int {
        mutex_lock(self.lock);
        let n = len(self.sockets);
        mutex_unlock(self.lock);
        return n;
    }

    pub fn room_size(self: Hub, room: str) -> int {
        mutex_lock(self.lock);
        let n = 0;
        if has(self.rooms, room) {
            n = len(self.rooms[room]);
        }
        mutex_unlock(self.lock);
        return n;
    }

    // The socket with this id, if it is in the hub.
    pub fn get(self: Hub, id: str) -> opt[Socket] {
        mutex_lock(self.lock);
        let found: opt[Socket] = none;
        if has(self.sockets, id) {
            found = some(self.sockets[id]);
        }
        mutex_unlock(self.lock);
        return found;
    }

    // Text to every WebSocket in the hub but `except` (an id, or ""). How
    // many it was queued for: a socket closed by a full queue is skipped,
    // and so is a Socket.IO session, which takes emit_* instead -- one hub
    // can hold both, and a chat open to both calls both.
    pub fn broadcast(self: Hub, text: str, except: str) -> int {
        return deliver(self.members(""), Out { kind: 0, text: text, data: b"" }, except, false);
    }

    pub fn broadcast_binary(self: Hub, b: bytes, except: str) -> int {
        return deliver(self.members(""), Out { kind: 1, text: "", data: b }, except, false);
    }

    pub fn to_room(self: Hub, room: str, text: str, except: str) -> int {
        return deliver(self.members(room), Out { kind: 0, text: text, data: b"" }, except, false);
    }

    pub fn to_room_binary(self: Hub, room: str, b: bytes, except: str) -> int {
        return deliver(self.members(room), Out { kind: 1, text: "", data: b }, except, false);
    }

    // Socket.IO: one event to every Socket.IO session in the hub, encoded
    // once. WebSockets in the hub are skipped.
    pub fn emit_all(self: Hub, namespace: str, name: str, args_json: str,
                    except: str) -> int {
        let p = Out { kind: 0, text: sio.event(namespace, name, args_json), data: b"" };
        return deliver(self.members(""), p, except, true);
    }

    pub fn emit_to_room(self: Hub, room: str, namespace: str, name: str,
                        args_json: str, except: str) -> int {
        let p = Out { kind: 0, text: sio.event(namespace, name, args_json), data: b"" };
        return deliver(self.members(room), p, except, true);
    }

    // A snapshot, taken under the lock and sent to outside it: a send
    // takes each socket's own lock, and holding both would order them.
    fn members(self: Hub, room: str) -> [Socket] {
        mutex_lock(self.lock);
        let out: [Socket] = [];
        if len(room) == 0 {
            for _id, s in self.sockets {
                push(out, s);
            }
        } else if has(self.rooms, room) {
            for id, _b in self.rooms[room] {
                if has(self.sockets, id) {
                    push(out, self.sockets[id]);
                }
            }
        }
        mutex_unlock(self.lock);
        return out;
    }
}

fn deliver(to: [Socket], o: Out, except: str, sio_only: bool) -> int {
    let n = 0;
    for s in to {
        if s.sio == sio_only && s.id != except && s.enqueue(o) {
            n = n + 1;
        }
    }
    return n;
}

// The connection's end: out of every hub it joined.
fn leave_hubs(s: Socket) {
    for h in s.hubs_now() {
        h.remove(s);
    }
}
