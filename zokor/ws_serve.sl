// WebSocket routes, served: the handshake goes through the router like
// any request -- its `before`s run, so authentication and rate limits
// apply -- and once the 101 is written the serve loop gives the
// connection to the socket for good.
//
//     fn chat_open(c: zokor.Ctx[App]) -> http.Response {
//         if c.local("user") == "" {               // set by an auth before
//             return c.state.errors... 401;         // refused: no upgrade
//         }
//         c.state.hub.join_room(c.socket(), "lobby");
//         return c.accept_ws();                     // the 101
//     }
//
//     fn chat_message(app: App, s: zokor.Socket, m: zokor.Message) {
//         app.hub.to_room("lobby", s.local("user") + ": " + m.text, s.id);
//     }
//
//     r.websocket("/chat", chat_open,
//                 zokor.ws_route(zokor.default_ws(), chat_message)
//                     .on_close(chat_left));
//
// Each connection is two tasks: this one reads, decodes and calls the
// handlers in order, one message at a time; a writer task owns the
// other half of the connection (link.split) and drains the socket's
// queue onto it. A handler that panics closes its connection with 1011;
// the process and every other connection carry on.

import "http";
import "proc";
import "time";

pub gc struct WsRoute[S] {
    rules: WsRules,
    // Always set by ws_route; none on a Socket.IO route, whose messages
    // are Engine.IO packets for `sio` instead.
    message: opt[fn(S, Socket, Message)],
    closed: opt[fn(S, Socket, int, str)],
    sio: opt[SioRoute[S]],
}

// The message handler is the one a route cannot do without; on_close is
// optional.
pub fn ws_route[S](rules: WsRules, message: fn(S, Socket, Message)) -> WsRoute[S] {
    return WsRoute[S] { rules: rules, message: some(message), closed: none, sio: none };
}

impl WsRoute[S] {
    // Called once when the connection ends, however it ended, with the
    // code and reason: the peer's, the ones this side closed with, 1006
    // when the peer vanished, 1002 for a protocol violation.
    pub fn on_close(self: WsRoute[S], f: fn(S, Socket, int, str)) -> WsRoute[S] {
        self.closed = some(f);
        return self;
    }
}

fn ws_socket_id() -> str {
    return "ws_" + new_session_id();
}

// A copy, so a socket's locals are its own from here on.
fn locals_of[S](c: Ctx[S]) -> map[str]str {
    let out: map[str]str = {};
    if let m = c.locals {
        for k, v in m {
            out[k] = v;
        }
    }
    return out;
}

// The handshake, in the route's place: a request that is not a valid
// upgrade is answered 400 without the route's handler running; one that
// is gets its Socket (c.socket()) and the 101 (c.accept_ws()), and the
// handler decides. Anything but a 101 from it refuses the upgrade, and
// the socket is dropped from any hub the handler had already put it in.
fn ws_handshake[S](r: Router[S], c: Ctx[S], rt: Route[S]) -> http.Response {
    let wr = r.sockets[rt.ws];
    if let _so = wr.sio {
        let why = sio_handshake_problem(c.query("EIO"), c.query("transport"), c.query("sid"));
        if len(why) > 0 {
            return respond_with(r.errors, "bad_request", why, c.request_id);
        }
    }
    let ur = upgrade(c.req, wr.rules);
    guard let accept = ur else let e = err_of(ur) {
        return http.with_header(respond_with(r.errors, "bad_request", e, c.request_id),
                                "sec-websocket-version", "13");
    }
    let protocol = http.resp_header(accept, "sec-websocket-protocol") ?? "";
    let sock = new_socket(ws_socket_id(), rt.pattern, protocol, c.client_ip,
                          locals_of(c), wr.rules.max_queue, rt.ws, accept);
    if let _so = wr.sio {
        sock.sio = true;
    }
    c.upgrade = some(sock);
    let open = rt.handler;
    let out = open(c);
    if out.status != 101 {
        c.upgrade = r.no_socket;
        sock.finish("refused");
        leave_hubs(sock);
        return out;
    }
    // what the handler put on the request after the socket was made
    for k, v in locals_of(c) {
        sock.locals[k] = v;
    }
    return out;
}

// ---------------------------------------------------------------- //
// The connection, after the 101                                      //
// ---------------------------------------------------------------- //

// One message to the route's handler, in a task of its own so a panic
// there is this message's failure, not the connection task's.
fn ws_deliver[S](on_message: fn(S, Socket, Message), state: S, s: Socket,
                 m: Message) -> int {
    on_message(state, s, m);
    return 0;
}

fn ws_close_hook[S](on_close: fn(S, Socket, int, str), state: S, s: Socket,
                    code: int, reason: str) -> int {
    on_close(state, s, code, reason);
    return 0;
}

// The writer task: everything queued, in order, onto its half of the
// connection, until the socket stops taking messages and the queue is
// empty -- or a write fails, which means the peer is gone. A close is
// written last, after whatever was queued ahead of it.
fn ws_writer(w: link, s: Socket, write_timeout: int, done: chan[int]) {
    let mut_w = w;
    while true {
        let m = chan_recv(s.out);
        guard let o = m else {
            break;
        }
        let frame: bytes = b"";
        if o.kind == 0 {
            frame = text_frame(o.text);
        } else if o.kind == 1 {
            frame = binary_frame(o.data);
        } else if o.kind == 2 {
            frame = o.data;
        } else {
            frame = close_frame(s.close_code, s.close_reason);
        }
        let sr = mut_w.send_bytes(frame, until_of(time.mono() + write_timeout));
        guard let _n = sr else {
            s.finish("write failed");
            break;
        }
    }
    chan_send(done, 1);
}

// The reader's state between reads.
gc struct WsSession {
    conn: Conn,
    // The close to report to on_close.
    code: int,
    reason: str,
    // The peer's close arrived, or a protocol error ended it.
    done: bool,
    // This side closed first: code and reason are ours, and the peer's
    // answer does not replace them.
    ours: bool,
    // Socket.IO: the disconnect reason its handlers are told, once known.
    why: str,
}

// Feeds one read through the decoder and the handlers. Messages run in
// arrival order, each finished before the next starts.
fn ws_feed[S](r: Router[S], wr: WsRoute[S], s: Socket, ss: WsSession,
              chunk: bytes, lg: Logger) {
    let got = receive(ss.conn, chunk);
    guard let msgs = got else let why = err_of(got) {
        s.enqueue_frame(close_because(ss.conn, why));
        s.finish("protocol error");
        ss.code = 1002;
        ss.reason = why;
        ss.done = true;
        return;
    }
    if let sr = wr.sio {
        sio_feed(r, sr, s, ss, msgs, lg);
        s.enqueue_frame(pending(ss.conn));
        if ss.done {
            s.finish("closed by peer");
        }
        return;
    }
    for m in msgs {
        if m.kind == Incoming.Close {
            if !ss.ours {
                ss.code = m.code;
                ss.reason = m.reason;
            }
            ss.done = true;
        } else if m.kind == Incoming.Text || m.kind == Incoming.Binary {
            guard let on_message = wr.message else { continue; }
            if !ss.done && s.is_open() {
                let jr = join_wait(spawn ws_deliver(on_message, r.state, s, m));
                guard let _ok = jr else let pe = err_of(jr) {
                    lg.error("WebSocket", "message handler panicked on " + s.route +
                             " (" + s.id + "): " + pe);
                    s.close(1011, "internal error");
                    return;
                }
            }
        }
    }
    // pongs and the close echo, after the handlers: handling a message
    // never changes what the protocol owes, but the echo must be last
    s.enqueue_frame(pending(ss.conn));
    if ss.done {
        s.finish("closed by peer");
    }
}

// Earliest of what the reader is waiting for: the peer's next bytes, the
// ping that is due, the pong that is owed, the end of a close we started.
fn ws_deadline(rules: WsRules, next_ping: int, pinged: int, closing: int) -> until {
    if closing > 0 {
        return until_of(closing + rules.close_timeout);
    }
    if rules.ping_interval <= 0 {
        return until_never();
    }
    if pinged > 0 {
        return until_of(pinged + rules.pong_timeout);
    }
    return until_of(next_ping);
}

// The reader's loop, from the 101 to the end of the connection; returns
// once the writer has written what it was given (bounded by
// write_timeout per frame), so the close frames go out before the
// connection is shut. `c` is freed by the caller, which ends both halves.
fn ws_session[S](r: Router[S], c: &mut link, buf: wire, filled: int,
                 sc: ServerConfig, s: Socket) {
    let wr = r.sockets[s.handler];
    let rules = wr.rules;
    let lg = sc.logger;
    let ss = WsSession { conn: new_conn(rules), code: 1006, reason: "", done: false,
                         ours: false, why: "" };
    let sr = c.split();
    guard let w = sr else let se = err_of(sr) {
        lg.error("WebSocket", "cannot split the connection: " + to_str(se));
        s.finish("split failed");
        ws_end(r, wr, s, 1011, "internal error");
        return;
    }
    let wdone: chan[int] = make_chan(1);
    spawn ws_writer(w, s, sc.write_timeout, wdone);
    if let so = wr.sio {
        // Engine.IO's handshake: the session id and the timers, first
        s.send_packet(sio_open_packet(s, so.settings));
    }
    // A WebSocket peer is pinged when it goes quiet. A Socket.IO client
    // must hear a ping every pingInterval whatever else it hears -- it
    // counts the time between pings, and gives up on a server that skips
    // one -- so its pings keep their schedule.
    let on_schedule = false;
    if let _sr = wr.sio {
        on_schedule = true;
    }
    let next_ping = time.mono() as int + rules.ping_interval;
    let pinged = 0;
    let closing = 0;
    if filled > 0 {
        ws_feed(r, wr, s, ss, to_bytes(buf[0..filled]), lg);
    }
    while !ss.done {
        if !s.is_open() {
            // closed from this side (close(), a full queue, a panic): the
            // close frame is queued, so the decoder must not echo the
            // peer's answer to it with a second one
            ss.conn.closed = true;
            if closing == 0 {
                closing = time.mono() as int;
                ss.ours = true;
                ss.code = s.close_code;
                ss.reason = s.close_reason;
            }
        }
        let rr = c.recv(buf, ws_deadline(rules, next_ping, pinged, closing));
        guard let n = rr else let e = err_of(rr) {
            if e != fault_timeout() {
                if proc.shutdown_requested() && closing == 0 {
                    // SIGTERM wakes every read: say goodbye properly, so
                    // clients reconnect elsewhere instead of seeing 1006
                    ss.why = "server shutting down";
                    s.close(1001, "server shutting down");
                    ss.ours = true;
                    ss.code = 1001;
                    ss.reason = "server shutting down";
                }
                // otherwise reset or closed: the peer is gone
                break;
            }
            if closing > 0 {
                break;
            }
            if pinged > 0 {
                ss.code = 1006;
                ss.reason = "no answer to ping";
                s.finish("ping timeout");
                break;
            }
            pinged = time.mono() as int;
            next_ping = pinged + rules.ping_interval;
            if on_schedule {
                s.send_packet(sio_ping_packet());
            } else {
                s.enqueue_frame(ping_frame(b""));
            }
            continue;
        }
        if n == 0 {
            break;
        }
        pinged = 0;
        if !on_schedule {
            next_ping = time.mono() as int + rules.ping_interval;
        }
        ws_feed(r, wr, s, ss, to_bytes(buf[0..n]), lg);
    }
    s.finish("ended");
    let _w = chan_recv(wdone);
    if let so = wr.sio {
        sio_end(r, so, s, ss.why);
        leave_hubs(s);
        return;
    }
    ws_end(r, wr, s, ss.code, ss.reason);
}

// on_close, isolated like a message, then out of every hub.
fn ws_end[S](r: Router[S], wr: WsRoute[S], s: Socket, code: int, reason: str) {
    if let on_close = wr.closed {
        let jr = join_wait(spawn ws_close_hook(on_close, r.state, s, code, reason));
        if let _ok = jr {
        } else let pe = err_of(jr) {
            r.ready.logger.error("WebSocket", "close handler panicked on " + s.route +
                                 " (" + s.id + "): " + pe);
        }
    }
    leave_hubs(s);
}
