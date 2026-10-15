// Socket.IO routes, served: Engine.IO v4 and Socket.IO v5 (what
// socket.io-client 3 and 4 speak), on both of its transports.
//
//     fn on_chat(app: App, s: zokor.Socket, e: zokor.SioEvent) {
//         if e.name == "chat message" {
//             app.hub.emit_to_room("lobby", "/", "chat message", e.args_json, s.id);
//             if e.ack >= 0 { s.ack(e.namespace, e.ack, "[\"ok\"]"); }
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
//
// A client with default options starts on HTTP long-polling -- a GET that
// waits for packets, a POST that carries the client's -- and moves to
// WebSocket once a probe over it succeeds. The session (its id, hubs,
// namespaces, locals, queue) is the same Socket throughout; handlers
// cannot tell which transport a packet came by.

import "encoding";
import "http";
import "proc";
import "time";
import "builder";
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
    // The route's long-polling sessions, by session id.
    sessions: SioSessions,
}

pub fn sio_route[S](event: fn(S, Socket, SioEvent)) -> SioRoute[S] {
    return SioRoute[S] { settings: default_sio(), event: event, connect: none,
                         disconnect: none, sessions: new_sio_sessions() };
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

// What is wrong with an Engine.IO request's query, "" when nothing is.
fn sio_handshake_problem(eio: str, transport: str, method: str) -> str {
    if eio != "4" {
        return "unsupported Engine.IO protocol version '" + eio +
               "': this server speaks EIO=4 (socket.io-client 3 and 4)";
    }
    if transport != "polling" && transport != "websocket" {
        return "unknown Engine.IO transport '" + transport + "'";
    }
    if transport == "websocket" && method != "GET" {
        return "a WebSocket upgrade is a GET";
    }
    return "";
}

fn sio_open_packet(s: Socket, st: SioSettings) -> str {
    return sio.open_packet(s.id, st.ping_interval_ms, st.ping_timeout_ms, st.max_payload);
}

fn sio_ping_packet() -> str {
    return sio.ping();
}

// ---------------------------------------------------------------- //
// Packets, whichever transport they came by                          //
// ---------------------------------------------------------------- //

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

// The WebSocket transport's messages, in order: Engine.IO packets in text
// frames, binary attachments in binary frames.
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
        if ss.done || !s.is_open() {
            continue;
        }
        if m.kind == Incoming.Text {
            if !sio_text(r, sr, s, ss, m.text, lg) {
                return;
            }
        } else if m.kind == Incoming.Binary {
            if !sio_attachment(r, sr, s, ss, m.data, lg) {
                return;
            }
        }
    }
}

// One Engine.IO packet. false when it ended the session.
fn sio_text[S](r: Router[S], sr: SioRoute[S], s: Socket, ss: WsSession, text: str,
               lg: Logger) -> bool {
    if ss.bin_left > 0 {
        return sio_broken(s, ss, "a packet arrived while a binary event's attachments were owed");
    }
    if text == "1" {
        // Engine.IO close: the client is leaving altogether
        ss.why = "client namespace disconnect";
        s.close(1000, "");
        return false;
    }
    let er = sio_receive(ss.conn, Message { kind: Incoming.Text, text: text, data: b"",
                                            code: 0, reason: "" });
    guard let e = er else let why = err_of(er) {
        return sio_broken(s, ss, why);
    }
    if e.kind == SioKind.Connect {
        sio_connect(r, sr, s, e, lg);
        return true;
    }
    if e.kind == SioKind.Disconnect {
        if sio_left(s, e.namespace) {
            sio_say_disconnect(r, sr, s, e.namespace, "client namespace disconnect", lg);
        }
        return true;
    }
    if e.kind == SioKind.Event || e.kind == SioKind.Ack {
        if e.expecting > 0 {
            if e.expecting > sr.settings.max_attachments {
                return sio_broken(s, ss, "an event with " + to_str(e.expecting) +
                                  " attachments, over the limit of " +
                                  to_str(sr.settings.max_attachments));
            }
            ss.bin = some(e);
            ss.bin_left = e.expecting;
            return true;
        }
        return sio_dispatch(r, sr, s, ss, e, lg);
    }
    // pong, noop, upgrade: nothing for the application
    return true;
}

// One binary attachment for the event waiting for it.
fn sio_attachment[S](r: Router[S], sr: SioRoute[S], s: Socket, ss: WsSession, data: bytes,
                     lg: Logger) -> bool {
    guard let e = ss.bin else {
        return sio_broken(s, ss, "a binary packet with no event to attach it to");
    }
    push(e.attachments, data);
    ss.bin_left = ss.bin_left - 1;
    if ss.bin_left > 0 {
        return true;
    }
    let nothing: opt[SioEvent] = none;
    ss.bin = nothing;
    return sio_dispatch(r, sr, s, ss, e, lg);
}

// A client that is not speaking Socket.IO: closed (1003), never guessed at.
fn sio_broken(s: Socket, ss: WsSession, why: str) -> bool {
    ss.why = "parse error";
    s.close(1003, why);
    return false;
}

fn sio_dispatch[S](r: Router[S], sr: SioRoute[S], s: Socket, ss: WsSession, e: SioEvent,
                   lg: Logger) -> bool {
    if !sio_in(s, e.namespace) {
        // a namespace it never connected to: dropped, as socket.io does
        return true;
    }
    let jr = join_wait(spawn sio_deliver(sr.event, r.state, s, e));
    guard let _ok = jr else let pe = err_of(jr) {
        lg.error("Socket.IO", "event handler panicked on " + s.route + " (" +
                 s.id + ", " + e.name + "): " + pe);
        ss.why = "server error";
        s.close(1011, "internal error");
        return false;
    }
    return true;
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

// ---------------------------------------------------------------- //
// HTTP long-polling                                                  //
// ---------------------------------------------------------------- //

// A session on the polling transport, between its requests.
gc struct PollSession {
    sock: Socket,
    lock: mutex,
    // Still on long-polling; false once it has moved to WebSocket, after
    // which the WebSocket connection owns it.
    polling: bool,
    // A WebSocket probe is under way.
    upgrading: bool,
    // A GET is waiting for packets / a POST is being handled: one of each
    // at a time, as Engine.IO requires.
    waiting: bool,
    posting: bool,
    // When the unanswered ping went out (time.mono), 0 when none is; and
    // when the next one is due.
    pinged: int,
    next_ping: int,
    ended: bool,
    st: WsSession,
}

gc struct SioSessions {
    lock: mutex,
    by_sid: map[str]PollSession,
    // The route's one heartbeat task is running.
    ticking: bool,
}

fn new_sio_sessions() -> SioSessions {
    let m: map[str]PollSession = {};
    return SioSessions { lock: make_mutex(), by_sid: m, ticking: false };
}

fn sio_session(sr: SioSessions, sid: str) -> opt[PollSession] {
    mutex_lock(sr.lock);
    let found: opt[PollSession] = none;
    if has(sr.by_sid, sid) {
        found = some(sr.by_sid[sid]);
    }
    mutex_unlock(sr.lock);
    return found;
}

fn sio_unknown_session[S](r: Router[S], c: Ctx[S]) -> http.Response {
    return respond_with(r.errors, "bad_request", "Session ID unknown", c.request_id);
}

// Every polling request: the handshake (no sid), a GET for packets, a
// POST of the client's.
fn sio_polling[S](r: Router[S], wr: WsRoute[S], sr: SioRoute[S], c: Ctx[S],
                  rt: Route[S]) -> http.Response {
    let sid = c.query("sid");
    if len(sid) == 0 {
        if c.req.method != "GET" {
            return respond_with(r.errors, "bad_request", "a polling session starts with a GET",
                                c.request_id);
        }
        return sio_poll_open(r, wr, sr, c, rt);
    }
    let found = sio_session(sr.sessions, sid);
    guard let ps = found else {
        return sio_unknown_session(r, c);
    }
    if c.req.method == "GET" {
        return sio_poll_get(r, sr, ps, c);
    }
    if c.req.method == "POST" {
        return sio_poll_post(r, sr, ps, c);
    }
    return respond_with(r.errors, "bad_request", "a polling request is a GET or a POST",
                        c.request_id);
}

fn sio_poll_open[S](r: Router[S], wr: WsRoute[S], sr: SioRoute[S], c: Ctx[S],
                    rt: Route[S]) -> http.Response {
    mutex_lock(sr.sessions.lock);
    let full = len(sr.sessions.by_sid) >= sr.settings.max_polling_sessions;
    mutex_unlock(sr.sessions.lock);
    if full {
        return http.with_header(respond_with(r.errors, "unavailable",
            "too many polling sessions: try again, or connect over WebSocket", c.request_id),
            "retry-after", "1");
    }
    let sid = new_session_id();
    let st = sr.settings;
    let open_packet = sio.open_packet_with(sid, "[\"websocket\"]", st.ping_interval_ms,
                                           st.ping_timeout_ms, st.max_payload);
    let resp = sio_payload_response(open_packet);
    let sock = new_socket(sid, rt.pattern, "", c.client_ip, locals_of(c), wr.rules.max_queue,
                          rt.ws, resp);
    sock.sio = true;
    c.upgrade = some(sock);
    let open = rt.handler;
    let out = open(c);
    // polling never takes the connection over: there is nothing to upgrade
    c.upgrade = r.no_socket;
    if !sock.accepted || out.status != 200 {
        sock.finish("refused");
        leave_hubs(sock);
        return out;
    }
    for k, v in locals_of(c) {
        sock.locals[k] = v;
    }
    let now = time.mono() as int;
    let ps = PollSession { sock: sock, lock: make_mutex(), polling: true, upgrading: false,
                           waiting: false, posting: false, pinged: 0,
                           next_ping: now + st.ping_interval_ms * 1000000, ended: false,
                           st: new_ws_session(wr.rules) };
    mutex_lock(sr.sessions.lock);
    sr.sessions.by_sid[sid] = ps;
    let start = !sr.sessions.ticking;
    sr.sessions.ticking = true;
    mutex_unlock(sr.sessions.lock);
    if start {
        spawn sio_ticker(r, sr);
    }
    return out;
}

fn sio_payload_response(body: str) -> http.Response {
    let resp = http.text_response(200, "OK", "text/plain; charset=UTF-8", body);
    return http.with_header(resp, "cache-control", "no-store");
}

// The packets queued for the session, waiting for the first: the
// heartbeat queues a ping every pingInterval, so a GET never waits longer
// than that. Several packets share one body, up to maxPayload.
fn sio_poll_get[S](r: Router[S], sr: SioRoute[S], ps: PollSession, c: Ctx[S]) -> http.Response {
    mutex_lock(ps.lock);
    if !ps.polling {
        mutex_unlock(ps.lock);
        return respond_with(r.errors, "bad_request", "the session has moved to WebSocket",
                            c.request_id);
    }
    if ps.waiting {
        mutex_unlock(ps.lock);
        // two GETs at once: a broken client, or a replayed request
        sio_poll_end(r, sr, ps, "transport error");
        return respond_with(r.errors, "bad_request", "a GET is already waiting for this session",
                            c.request_id);
    }
    ps.waiting = true;
    mutex_unlock(ps.lock);
    let s = ps.sock;
    let body = builder.new_str();
    let first = chan_recv(s.out);
    if let o = first {
        sio_poll_write(body, o);
        let more = true;
        while more && body.size() < sr.settings.max_payload {
            select {
                case let next = chan_recv(s.out) {
                    if let o2 = next {
                        sio_poll_write(body, o2);
                    } else {
                        more = false;
                    }
                }
                default {
                    more = false;
                }
            }
        }
    } else {
        // the session is over
        body.write(sio.close_packet());
    }
    mutex_lock(ps.lock);
    ps.waiting = false;
    mutex_unlock(ps.lock);
    return sio_payload_response(body.finish());
}

// One queued packet into a polling body: record-separated, binary as
// "b" + base64.
fn sio_poll_write(body: builder.Str, o: Out) {
    if body.size() > 0 {
        body.write(to_str(b"\x1e"));
    }
    if o.kind == 0 {
        body.write(o.text);
    } else if o.kind == 1 {
        body.write("b" + encoding.base64_encode(o.data));
    } else if o.kind == 3 {
        body.write(sio.close_packet());
    } else {
        // a WebSocket frame: meaningless here
        body.write(sio.encode_eio(sio.Eio.Noop, ""));
    }
}

fn sio_poll_post[S](r: Router[S], sr: SioRoute[S], ps: PollSession, c: Ctx[S]) -> http.Response {
    mutex_lock(ps.lock);
    if !ps.polling {
        mutex_unlock(ps.lock);
        return respond_with(r.errors, "bad_request", "the session has moved to WebSocket",
                            c.request_id);
    }
    if ps.posting {
        mutex_unlock(ps.lock);
        sio_poll_end(r, sr, ps, "transport error");
        return respond_with(r.errors, "bad_request", "a POST is already in progress for this session",
                            c.request_id);
    }
    ps.posting = true;
    mutex_unlock(ps.lock);
    let s = ps.sock;
    let lg = r.ready.logger;
    let body = c.body_bytes();
    let n = len(body);
    let start = 0;
    let i = 0;
    let going = true;
    while going && i <= n {
        if i == n || body[i] == 30 {
            if i > start {
                going = sio_poll_packet(r, sr, ps, body[start..i], lg);
            }
            start = i + 1;
        }
        i = i + 1;
    }
    mutex_lock(ps.lock);
    ps.posting = false;
    mutex_unlock(ps.lock);
    if !going && !s.is_open() {
        sio_poll_end(r, sr, ps, ps.st.why);
    }
    return http.text_response(200, "OK", "text/html; charset=UTF-8", "ok");
}

fn sio_poll_packet[S](r: Router[S], sr: SioRoute[S], ps: PollSession, p: bytes,
                      lg: Logger) -> bool {
    let s = ps.sock;
    if !s.is_open() {
        return false;
    }
    if p[0] == 98 {
        let dr = encoding.base64_decode(to_str(p[1..len(p)]));
        guard let data = dr else {
            return sio_broken(s, ps.st, "a binary packet that is not base64");
        }
        return sio_attachment(r, sr, s, ps.st, data, lg);
    }
    let text = to_str(p);
    if text == "3" {
        mutex_lock(ps.lock);
        ps.pinged = 0;
        mutex_unlock(ps.lock);
        return true;
    }
    return sio_text(r, sr, s, ps.st, text, lg);
}

// Out of the registry, out of every hub, and on_disconnect for each
// namespace: once, whoever gets here first.
fn sio_poll_end[S](r: Router[S], sr: SioRoute[S], ps: PollSession, why: str) {
    mutex_lock(ps.lock);
    let first = !ps.ended;
    ps.ended = true;
    mutex_unlock(ps.lock);
    if !first {
        return;
    }
    mutex_lock(sr.sessions.lock);
    if has(sr.sessions.by_sid, ps.sock.id) {
        del(sr.sessions.by_sid, ps.sock.id);
    }
    mutex_unlock(sr.sessions.lock);
    ps.sock.finish("ended");
    sio_end(r, sr, ps.sock, why);
    leave_hubs(ps.sock);
}

fn sio_tick_ns(st: SioSettings) -> int {
    let t = st.ping_interval_ms * 1000000 / 5;
    if t < 20000000 {
        return 20000000;
    }
    if t > 500000000 {
        return 500000000;
    }
    return t;
}

// The heartbeat for every polling session on the route, in one task:
// queues each session's ping when it is due, ends a session whose ping
// went unanswered for pingTimeout or whose socket was closed, and on
// SIGTERM ends them all. It stops when the route has no sessions left,
// and the next one starts it again.
fn sio_ticker[S](r: Router[S], sr: SioRoute[S]) {
    let st = sr.settings;
    let interval = st.ping_interval_ms * 1000000;
    let timeout = st.ping_timeout_ms * 1000000;
    while true {
        time.sleep(sio_tick_ns(st));
        mutex_lock(sr.sessions.lock);
        let all: [PollSession] = [];
        for _sid, ps in sr.sessions.by_sid {
            push(all, ps);
        }
        if len(all) == 0 {
            sr.sessions.ticking = false;
            mutex_unlock(sr.sessions.lock);
            return;
        }
        mutex_unlock(sr.sessions.lock);
        let stopping = proc.shutdown_requested();
        let now = time.mono() as int;
        for ps in all {
            mutex_lock(ps.lock);
            let polling = ps.polling;
            let waiting = ps.waiting;
            let pinged = ps.pinged;
            let due = ps.next_ping <= now;
            mutex_unlock(ps.lock);
            if !polling {
                continue;
            }
            let s = ps.sock;
            if stopping {
                ps.st.why = "server shutting down";
                s.close(1001, "server shutting down");
                sio_poll_end(r, sr, ps, "server shutting down");
            } else if !s.is_open() {
                if !waiting {
                    sio_poll_end(r, sr, ps, ps.st.why);
                }
            } else if pinged > 0 && now - pinged > timeout {
                s.finish("ping timeout");
                sio_poll_end(r, sr, ps, "ping timeout");
            } else if pinged == 0 && due {
                mutex_lock(ps.lock);
                ps.pinged = now;
                ps.next_ping = now + interval;
                mutex_unlock(ps.lock);
                s.send_packet(sio.ping());
            }
        }
    }
}

// ---------------------------------------------------------------- //
// From polling to WebSocket                                          //
// ---------------------------------------------------------------- //

// The WebSocket half of an upgrade: the 101, for the polling session
// named by sid, whose Socket the connection then serves. No open handler
// runs: the session was accepted when it began.
fn sio_upgrade_handshake[S](r: Router[S], wr: WsRoute[S], sr: SioRoute[S],
                            c: Ctx[S]) -> http.Response {
    let found = sio_session(sr.sessions, c.query("sid"));
    guard let ps = found else {
        return sio_unknown_session(r, c);
    }
    mutex_lock(ps.lock);
    if !ps.polling || ps.upgrading || ps.ended {
        mutex_unlock(ps.lock);
        return respond_with(r.errors, "bad_request", "this session cannot be upgraded now",
                            c.request_id);
    }
    ps.upgrading = true;
    mutex_unlock(ps.lock);
    let ur = upgrade(c.req, wr.rules);
    guard let accept = ur else let e = err_of(ur) {
        mutex_lock(ps.lock);
        ps.upgrading = false;
        mutex_unlock(ps.lock);
        return respond_with(r.errors, "bad_request", e, c.request_id);
    }
    c.upgrade = some(ps.sock);
    return accept;
}

fn sio_upgrading[S](sr: SioRoute[S], sid: str) -> opt[PollSession] {
    let found = sio_session(sr.sessions, sid);
    guard let ps = found else {
        return found;
    }
    mutex_lock(ps.lock);
    let yes = ps.upgrading;
    mutex_unlock(ps.lock);
    if yes {
        return found;
    }
    let nothing: opt[PollSession] = none;
    return nothing;
}

// Engine.IO's probe, before the connection is split: the client sends
// "2probe", gets "3probe", stops polling -- the waiting GET is released
// with a noop -- and sends "5". From then on the session is this
// connection's. ws_session reads and writes; this decides.
gc struct Probe {
    probed: bool,
    // "3probe" is owed to the client now.
    answer: bool,
    done: bool,
    failed: str,
    // Messages after the "5", to be handled as the session's first.
    rest: [Message],
}

fn new_probe() -> Probe {
    let none_yet: [Message] = [];
    return Probe { probed: false, answer: false, done: false, failed: "", rest: none_yet };
}

fn sio_probe_messages(msgs: [Message], ps: PollSession, p: Probe) {
    let i = 0;
    while i < len(msgs) {
        let m = msgs[i];
        i = i + 1;
        if p.done {
            push(p.rest, m);
            continue;
        }
        if m.kind == Incoming.Close {
            p.failed = "the client closed the WebSocket";
            return;
        }
        if m.kind != Incoming.Text {
            continue;
        }
        if m.text == "2probe" && !p.probed {
            p.probed = true;
            p.answer = true;
        } else if m.text == "5" && p.probed {
            mutex_lock(ps.lock);
            ps.polling = false;
            ps.upgrading = false;
            mutex_unlock(ps.lock);
            p.done = true;
        } else {
            p.failed = "unexpected '" + m.text + "'";
            return;
        }
    }
}

fn sio_noop() -> str {
    return sio.encode_eio(sio.Eio.Noop, "");
}

fn sio_forget[S](sr: SioRoute[S], sid: str) {
    mutex_lock(sr.sessions.lock);
    if has(sr.sessions.by_sid, sid) {
        del(sr.sessions.by_sid, sid);
    }
    mutex_unlock(sr.sessions.lock);
}

// The probe failed: the session carries on over polling, as Engine.IO
// clients expect when a WebSocket cannot be established.
fn sio_upgrade_failed(ps: PollSession, why: str, lg: Logger) {
    mutex_lock(ps.lock);
    ps.upgrading = false;
    mutex_unlock(ps.lock);
    lg.debug("Socket.IO", "upgrade of " + ps.sock.id + " failed: " + why);
}
