// Socket.IO routes, served: Engine.IO v4 and Socket.IO v5 (what
// socket.io-client 3 and 4 speak) over the served WebSocket.
//
//     fn on_chat(app: App, s: zokor.Socket, e: zokor.SioEvent) {
//         if e.name == "chat message" {
//             app.hub.emit_to_room("lobby", "/", "chat message", e.args_json, s.id);
//             if e.ack >= 0 { s.sio_ack(e.namespace, e.ack, "[\"ok\"]"); }
//         }
//     }
//
//     r.socketio("/socket.io/", chat_open,
//                zokor.sio_route(on_chat).on_connect(joined).on_disconnect(left));
//
// The open handler is the Engine.IO handshake's, exactly as for
// r.websocket: its `before`s run first, and it answers c.accept_ws() or
// refuses. A namespace's CONNECT (with the client's `auth` object) goes to
// on_connect, which accepts or answers with a connect_error the client
// sees as an error. Engine.IO's heartbeat is run here: a ping every
// pingInterval, and a client that does not answer within pingTimeout is
// gone.

import "internal/sio";

pub gc struct SioRoute[S] {
    settings: SioSettings,
    event: fn(S, Socket, SioEvent),
    // CONNECT to a namespace: the namespace and the client's auth payload
    // (JSON, "" when it sent none). ok accepts; err(message) refuses.
    // Without one every namespace is accepted.
    connect: opt[fn(S, Socket, str, str) -> result[bool, str]],
    // Once per connected namespace when it ends: the namespace and why
    // ("client namespace disconnect", "transport close", "ping timeout",
    // "server shutting down" ...).
    disconnect: opt[fn(S, Socket, str, str)],
}

pub fn sio_route[S](event: fn(S, Socket, SioEvent)) -> SioRoute[S] {
    return SioRoute[S] { settings: default_sio(), event: event, connect: none,
                         disconnect: none };
}

impl SioRoute[S] {
    pub fn on_connect(self: SioRoute[S], f: fn(S, Socket, str, str) -> result[bool, str]) -> SioRoute[S] {
        self.connect = some(f);
        return self;
    }

    pub fn on_disconnect(self: SioRoute[S], f: fn(S, Socket, str, str)) -> SioRoute[S] {
        self.disconnect = some(f);
        return self;
    }
}

// The WebSocket transport's settings for a Socket.IO route: Engine.IO's
// timers, and its maxPayload as the largest message.
fn sio_ws_rules(s: SioSettings) -> WsRules {
    let r = default_ws();
    r.ping_interval = s.ping_interval_ms * 1000000;
    r.pong_timeout = s.ping_timeout_ms * 1000000;
    if s.max_payload > 0 && s.max_payload < r.max_message_bytes {
        r.max_message_bytes = s.max_payload;
    }
    if r.max_frame_bytes > r.max_message_bytes {
        r.max_frame_bytes = r.max_message_bytes;
    }
    return r;
}

fn sio_as_ws[S](s: SioRoute[S]) -> WsRoute[S] {
    return WsRoute[S] { rules: sio_ws_rules(s.settings), message: none, closed: none,
                        sio: some(s) };
}

// What is wrong with an Engine.IO handshake's query, "" when nothing is.
fn sio_handshake_problem(eio: str, transport: str, sid: str) -> str {
    if eio != "4" {
        return "unsupported Engine.IO protocol version '" + eio +
               "': this server speaks EIO=4 (socket.io-client 3 and 4)";
    }
    if transport == "polling" {
        return "the polling transport is not served: connect with transports: [\"websocket\"]";
    }
    if transport != "websocket" {
        return "unknown Engine.IO transport '" + transport + "'";
    }
    if len(sid) > 0 {
        return "no polling session to upgrade: connect with transports: [\"websocket\"]";
    }
    return "";
}

fn sio_open_packet(s: Socket, st: SioSettings) -> str {
    return sio.open_packet(s.id, st.ping_interval_ms, st.ping_timeout_ms, st.max_payload);
}

fn sio_ping_packet() -> str {
    return sio.ping();
}

fn sio_deliver[S](on_event: fn(S, Socket, SioEvent), state: S, s: Socket,
                  e: SioEvent) -> int {
    on_event(state, s, e);
    return 0;
}

fn sio_connect_hook[S](on_connect: fn(S, Socket, str, str) -> result[bool, str], state: S,
                       s: Socket, ns: str, auth: str) -> result[bool, str] {
    return on_connect(state, s, ns, auth);
}

fn sio_disconnect_hook[S](on_disconnect: fn(S, Socket, str, str), state: S, s: Socket,
                          ns: str, why: str) -> int {
    on_disconnect(state, s, ns, why);
    return 0;
}

// The Engine.IO packets in one read, in order.
fn sio_feed[S](r: Router[S], sr: SioRoute[S], s: Socket, ss: WsSession,
               msgs: [Message], lg: Logger) {
    for m in msgs {
        if m.kind == Incoming.Close {
            if !ss.ours {
                ss.code = m.code;
                ss.reason = m.reason;
            }
            if len(ss.why) == 0 {
                ss.why = "transport close";
            }
            ss.done = true;
            continue;
        }
        if m.kind != Incoming.Text || ss.done || !s.is_open() {
            continue;
        }
        let er = sio_receive(ss.conn, m);
        guard let e = er else let why = err_of(er) {
            // not Engine.IO: this is not a socket.io client
            ss.why = "parse error";
            s.close(1003, why);
            return;
        }
        if e.kind == SioKind.Disconnect && e.namespace == "/" && sio_closes_session(m.text) {
            // Engine.IO close ("1"): the client is leaving altogether
            ss.why = "client namespace disconnect";
            s.close(1000, "");
            return;
        }
        if e.kind == SioKind.Connect {
            sio_connect(r, sr, s, e, lg);
        } else if e.kind == SioKind.Disconnect {
            if sio_left(s, e.namespace) {
                sio_say_disconnect(r, sr, s, e.namespace, "client namespace disconnect", lg);
            }
        } else if e.kind == SioKind.Event || e.kind == SioKind.Ack {
            if !sio_in(s, e.namespace) {
                // a namespace it never connected to: dropped, as socket.io does
                continue;
            }
            let jr = join_wait(spawn sio_deliver(sr.event, r.state, s, e));
            guard let _ok = jr else let pe = err_of(jr) {
                lg.error("Socket.IO", "event handler panicked on " + s.route + " (" +
                         s.id + ", " + e.name + "): " + pe);
                ss.why = "server error";
                s.close(1011, "internal error");
                return;
            }
        }
    }
}

// "1" is Engine.IO's close; "41" is a namespace's disconnect. sio_receive
// reports both as Disconnect.
fn sio_closes_session(text: str) -> bool {
    return text == "1";
}

fn sio_in(s: Socket, ns: str) -> bool {
    mutex_lock(s.lock);
    let yes = has(s.namespaces, ns);
    mutex_unlock(s.lock);
    return yes;
}

fn sio_left(s: Socket, ns: str) -> bool {
    mutex_lock(s.lock);
    let was = has(s.namespaces, ns);
    if was {
        del(s.namespaces, ns);
    }
    mutex_unlock(s.lock);
    return was;
}

fn sio_connect[S](r: Router[S], sr: SioRoute[S], s: Socket, e: SioEvent, lg: Logger) {
    let ns = e.namespace;
    let auth = e.args_json;
    if auth == "[]" {
        auth = "";
    }
    if let on_connect = sr.connect {
        let jr = join_wait(spawn sio_connect_hook(on_connect, r.state, s, ns, auth));
        guard let decided = jr else let pe = err_of(jr) {
            lg.error("Socket.IO", "connect handler panicked on " + s.route + " (" + s.id +
                     ", " + ns + "): " + pe);
            s.send_packet(sio.connect_error(ns, "internal error"));
            return;
        }
        guard let _yes = decided else let why = err_of(decided) {
            s.send_packet(sio.connect_error(ns, why));
            return;
        }
    }
    mutex_lock(s.lock);
    s.namespaces[ns] = true;
    mutex_unlock(s.lock);
    s.send_packet(sio.connect_ok(ns, s.id));
}

fn sio_say_disconnect[S](r: Router[S], sr: SioRoute[S], s: Socket, ns: str, why: str,
                         lg: Logger) {
    guard let on_disconnect = sr.disconnect else {
        return;
    }
    let jr = join_wait(spawn sio_disconnect_hook(on_disconnect, r.state, s, ns, why));
    if let _ok = jr {
    } else let pe = err_of(jr) {
        lg.error("Socket.IO", "disconnect handler panicked on " + s.route + " (" + s.id +
                 "): " + pe);
    }
}

// The session is over: every namespace still connected hears why.
fn sio_end[S](r: Router[S], sr: SioRoute[S], s: Socket, known: str) {
    let why = known;
    if s.ended == "ping timeout" {
        why = "ping timeout";
    } else if s.ended == "overflow" {
        why = "transport error";
    } else if len(why) == 0 {
        why = "transport close";
    }
    mutex_lock(s.lock);
    let left: [str] = [];
    for ns, _b in s.namespaces {
        push(left, ns);
    }
    let none_left: map[str]bool = {};
    s.namespaces = none_left;
    mutex_unlock(s.lock);
    for ns in left {
        sio_say_disconnect(r, sr, s, ns, why, r.ready.logger);
    }
}
