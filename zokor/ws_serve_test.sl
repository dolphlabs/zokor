import "http";
import "net";
import "strings";
import "time";
import "internal/ws";

// A chat over real connections: serve_conn on one end, a hand-rolled
// client (masked frames, as a browser sends) on the other.

gc struct Chat {
    hub: Hub,
    events: chan[str],
}

fn chat_open(c: Ctx[Chat]) -> http.Response {
    let name = c.query("name");
    if name == "" {
        return respond_with(c.errors, "unauthorized", "a name is required", c.request_id);
    }
    if name == "panic-open" {
        panic("open hook exploded");
    }
    let s = c.socket();
    s.set_local("name", name);
    c.state.hub.join_room(s, "lobby");
    return c.accept_ws();
}

fn chat_message(app: Chat, s: Socket, m: Message) {
    if m.kind == Incoming.Binary {
        s.send_binary(m.data);
        return;
    }
    if m.text == "boom" {
        panic("handler exploded");
    }
    if m.text == "leave" {
        s.close(4000, "asked to leave");
        return;
    }
    if m.text == "who" {
        s.send_text("you are " + s.local("name") + " in a room of " +
                    to_str(app.hub.room_size("lobby")));
        return;
    }
    app.hub.to_room("lobby", s.local("name") + ": " + m.text, s.id);
}

fn chat_closed(app: Chat, s: Socket, code: int, reason: str) {
    chan_send(app.events, s.local("name") + " closed " + to_str(code) + " " + reason);
}

fn chat_rules() -> WsRules {
    return default_ws();
}

fn chat_router(rules: WsRules) -> Router[Chat] {
    let ev: chan[str] = make_chan(64);
    let r = new_router(Chat { hub: new_hub(), events: ev });
    r.websocket("/chat", chat_open, ws_route(rules, chat_message).on_close(chat_closed));
    r.get("/plain", ok_plain);
    return r;
}

fn ok_plain(c: Ctx[Chat]) -> http.Response {
    return text(200, "plain");
}

fn ws_quiet() -> ServerConfig {
    let sc = default_server_config();
    sc.logger = no_logger();
    return sc;
}

// Serves every connection to `ln` until the test process ends.
fn serve_all(ln: link, r: Router[Chat], sc: ServerConfig) {
    let mut_ln = ln;
    while true {
        let ar = mut_ln.accept(until_never());
        guard let c = ar else { return; }
        spawn serve_conn(r, c, sc);
    }
}

fn ws_start(r: Router[Chat], sc: ServerConfig) -> int {
    let lr = link_listen(0);
    guard let ln = lr else { panic("listen"); }
    let port = ln.port();
    spawn serve_all(ln, r, sc);
    return port;
}

fn ws_soon(ms: int) -> until {
    return until_of(time.mono() + ms * 1000000);
}

// A masked client frame, as RFC 6455 requires of a client.
fn masked(op: int, payload: bytes) -> bytes {
    let n = len(payload);
    let head = b"..";
    head[0] = 128 | op;
    let ext = b"";
    if n < 126 {
        head[1] = 128 | n;
    } else {
        head[1] = 128 | 126;
        ext = b"..";
        ext[0] = (n >> 8) & 255;
        ext[1] = n & 255;
    }
    let key = b"\x11\x22\x33\x44";
    let body = b"";
    let i = 0;
    let one = b".";
    while i < n {
        one[0] = payload[i] ^ key[i % 4];
        body = body + one;
        i = i + 1;
    }
    return head + ext + key + body;
}

fn close_payload(code: int, reason: str) -> bytes {
    let b = b"..";
    b[0] = (code >> 8) & 255;
    b[1] = code & 255;
    return b + to_bytes(reason);
}

// A connected client: the request sent, the response head read. Returns
// the status line and whatever arrived after the head.
gc struct Client {
    status: str,
    head: str,
    rest: bytes,
}

fn read_some(c: &mut link, ms: int) -> bytes {
    let a = arena_new(65536);
    let w = a.wire(65536);
    let rr = c.recv(w, ws_soon(ms));
    guard let n = rr else { return b""; }
    return to_bytes(w[0..n]);
}

fn handshake(c: &mut link, path: str) -> Client {
    let req = "GET " + path + " HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\n" +
              "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" +
              "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    let _s = c.send_bytes(to_bytes(req), ws_soon(2000));
    let got = b"";
    let a = arena_new(65536);
    let w = a.wire(65536);
    while true {
        let rr = c.recv(w, ws_soon(2000));
        guard let n = rr else { break; }
        if n == 0 { break; }
        got = got + to_bytes(w[0..n]);
        let t = to_str(got);
        let at = strings.find(t, "\r\n\r\n");
        if at >= 0 {
            let head = strings.slice(t, 0, at);
            let line_end = strings.find(head, "\r\n");
            return Client { status: strings.slice(head, 0, line_end), head: head,
                            rest: got[at + 4..len(got)] };
        }
    }
    return Client { status: "no response", head: "", rest: b"" };
}

// Reads server frames until `want` whole ones have arrived (or 2s pass),
// as "text:..", "binary:<n>", "close:<code> <reason>", "ping".
fn frames(c: &mut link, pending: bytes, want: int) -> [str] {
    let out: [str] = [];
    let buf = pending;
    let at = 0;
    let a = arena_new(65536);
    let w = a.wire(65536);
    let deadline = time.mono() + 2000000000;
    while len(out) < want && time.mono() < deadline {
        let dr = ws.decode(buf, at, 16777216, false);
        guard let d = dr else { push(out, "undecodable"); return out; }
        if d.kind == ws.Decoded.Incomplete {
            let rr = c.recv(w, ws_soon(2000));
            guard let n = rr else { push(out, "eof"); return out; }
            if n == 0 { push(out, "eof"); return out; }
            buf = buf[at..len(buf)] + to_bytes(w[0..n]);
            at = 0;
            continue;
        }
        let f = d.frame;
        at = at + f.size;
        if f.op == ws.Op.Text {
            push(out, "text:" + to_str(f.payload));
        } else if f.op == ws.Op.Binary {
            push(out, "binary:" + to_str(len(f.payload)));
        } else if f.op == ws.Op.Ping {
            push(out, "ping");
        } else if f.op == ws.Op.Close {
            let cr = ws.decode_close(f.payload);
            if let body = cr {
                push(out, "close:" + to_str(body.code) + " " + body.reason);
            } else {
                push(out, "close");
            }
        }
    }
    return out;
}

fn ws_connect(port: int, path: str) -> link {
    let dr = link_dial("127.0.0.1", port, ws_soon(2000));
    guard let c = dr else { panic("dial"); }
    return c;
}

fn chat_event(r: Router[Chat]) -> str {
    let deadline = time.mono() + 3000000000;
    while time.mono() < deadline {
        select {
            case let v = chan_recv(r.state.events) {
                return v ?? "";
            }
            default { }
        }
        time.sleep(5000000);
    }
    return "no event";
}

fn test_ws_two_clients_talk_through_a_room() {
    let r = chat_router(chat_rules());
    let port = ws_start(r, ws_quiet());
    let a = ws_connect(port, "/chat?name=ada");
    let ha = handshake(&mut a, "/chat?name=ada");
    assert(ha.status == "HTTP/1.1 101 Switching Protocols", ha.status);
    assert(strings.contains(strings.to_lower(ha.head), "sec-websocket-accept: s3pplmbitxaq9kygzzhzrbk+xoo="), ha.head);
    let b = ws_connect(port, "/chat?name=bo");
    let hb = handshake(&mut b, "/chat?name=bo");
    assert(hb.status == "HTTP/1.1 101 Switching Protocols", hb.status);
    // bo is parked waiting for frames; ada's message reaches it through
    // bo's writer task
    let _s = a.send_bytes(masked(1, to_bytes("hello")), ws_soon(1000));
    let got = frames(&mut b, hb.rest, 1);
    assert(got[0] == "text:ada: hello", got[0]);
    let _w = b.send_bytes(masked(1, to_bytes("who")), ws_soon(1000));
    let who = frames(&mut b, b"", 1);
    assert(who[0] == "text:you are bo in a room of 2", who[0]);
    // the sender does not hear itself
    let _s2 = b.send_bytes(masked(1, to_bytes("hi ada")), ws_soon(1000));
    let at_a = frames(&mut a, ha.rest, 1);
    assert(at_a[0] == "text:bo: hi ada", at_a[0]);
    // ada says goodbye: the echo, then on_close with ada's code
    let _c = a.send_bytes(masked(8, close_payload(1000, "bye")), ws_soon(1000));
    let echo = frames(&mut a, b"", 1);
    assert(echo[0] == "close:1000 ", echo[0]);
    assert(chat_event(r) == "ada closed 1000 bye");
    let after = read_some(&mut a, 2000);
    assert(len(after) == 0, "the connection stays open after the close");
    // ada left the room with the connection
    let _w2 = b.send_bytes(masked(1, to_bytes("who")), ws_soon(1000));
    let who2 = frames(&mut b, b"", 1);
    assert(who2[0] == "text:you are bo in a room of 1", who2[0]);
}

fn test_ws_handshake_refused_by_the_open_handler() {
    let r = chat_router(chat_rules());
    let port = ws_start(r, ws_quiet());
    let c = ws_connect(port, "/chat");
    let h = handshake(&mut c, "/chat");
    assert(strings.has_prefix(h.status, "HTTP/1.1 401"), h.status);
    assert(r.state.hub.count() == 0);
}

fn test_ws_route_answers_a_plain_get_with_400() {
    let r = chat_router(chat_rules());
    let port = ws_start(r, ws_quiet());
    let c = ws_connect(port, "/chat?name=x");
    let _s = c.send_bytes(b"GET /chat?name=x HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n", ws_soon(1000));
    let got = to_str(read_some(&mut c, 2000));
    assert(strings.has_prefix(got, "HTTP/1.1 400"), got);
    assert(strings.contains(got, "the Upgrade header must be 'websocket'"), got);
}

// A panicking open handler is the request's 500, like any handler.
fn test_ws_open_handler_panic_is_a_500() {
    let r = chat_router(chat_rules());
    let port = ws_start(r, ws_quiet());
    let c = ws_connect(port, "/chat?name=panic-open");
    let h = handshake(&mut c, "/chat?name=panic-open");
    assert(strings.has_prefix(h.status, "HTTP/1.1 500"), h.status);
}

// A panic in one message closes that connection with 1011; the
// connection next to it is untouched.
fn test_ws_message_handler_panic_closes_only_its_connection() {
    let r = chat_router(chat_rules());
    let port = ws_start(r, ws_quiet());
    let a = ws_connect(port, "/chat?name=ada");
    let ha = handshake(&mut a, "/chat?name=ada");
    let b = ws_connect(port, "/chat?name=bo");
    let hb = handshake(&mut b, "/chat?name=bo");
    let _s = a.send_bytes(masked(1, to_bytes("boom")), ws_soon(1000));
    let got = frames(&mut a, ha.rest, 1);
    assert(got[0] == "close:1011 internal error", got[0]);
    let _e = a.send_bytes(masked(8, close_payload(1011, "")), ws_soon(1000));
    assert(chat_event(r) == "ada closed 1011 internal error");
    let _w = b.send_bytes(masked(1, to_bytes("who")), ws_soon(1000));
    let who = frames(&mut b, hb.rest, 1);
    assert(who[0] == "text:you are bo in a room of 1", who[0]);
}

// close() from a handler: the client gets the code, answers, and the
// connection ends with on_close told the same code.
fn test_ws_server_close_handshake() {
    let r = chat_router(chat_rules());
    let port = ws_start(r, ws_quiet());
    let a = ws_connect(port, "/chat?name=ada");
    let ha = handshake(&mut a, "/chat?name=ada");
    let _s = a.send_bytes(masked(1, to_bytes("leave")), ws_soon(1000));
    let got = frames(&mut a, ha.rest, 1);
    assert(got[0] == "close:4000 asked to leave", got[0]);
    let _e = a.send_bytes(masked(8, close_payload(4000, "")), ws_soon(1000));
    assert(chat_event(r) == "ada closed 4000 asked to leave");
    assert(len(read_some(&mut a, 2000)) == 0, "still open after the close handshake");
}

// A client that answers nothing is pinged after ping_interval and closed
// pong_timeout later; one that answers pings stays.
fn test_ws_unanswered_ping_closes_the_connection() {
    let rules = chat_rules();
    rules.ping_interval = 100000000;
    rules.pong_timeout = 150000000;
    let r = chat_router(rules);
    let port = ws_start(r, ws_quiet());
    let quiet_one = ws_connect(port, "/chat?name=mute");
    let hq = handshake(&mut quiet_one, "/chat?name=mute");
    let lively = ws_connect(port, "/chat?name=live");
    let hl = handshake(&mut lively, "/chat?name=live");
    let t0 = time.mono();
    let pings = frames(&mut lively, hl.rest, 1);
    assert(pings[0] == "ping", pings[0]);
    let _p = lively.send_bytes(masked(10, b""), ws_soon(1000));
    // the mute one gets its ping and says nothing back
    let mute_ping = frames(&mut quiet_one, hq.rest, 1);
    assert(mute_ping[0] == "ping", mute_ping[0]);
    assert(chat_event(r) == "mute closed 1006 no answer to ping");
    let took = (time.mono() - t0) as int;
    assert(took >= 150000000 && took < 2000000000, "took " + to_str(took));
    let _w = lively.send_bytes(masked(1, to_bytes("who")), ws_soon(1000));
    let who = frames(&mut lively, b"", 2);
    let saw = false;
    for f in who {
        if f == "text:you are live in a room of 1" { saw = true; }
    }
    assert(saw, inspect(who));
}

// A protocol violation (an unmasked frame) is closed with 1002.
fn test_ws_protocol_error_closes_with_1002() {
    let r = chat_router(chat_rules());
    let port = ws_start(r, ws_quiet());
    let a = ws_connect(port, "/chat?name=rude");
    let ha = handshake(&mut a, "/chat?name=rude");
    let _s = a.send_bytes(b"\x81\x03abc", ws_soon(1000));
    let got = frames(&mut a, ha.rest, 1);
    assert(strings.has_prefix(got[0], "close:1002 "), got[0]);
    assert(strings.has_prefix(chat_event(r), "rude closed 1002 "));
}

// A message larger than one read, binary, echoed back whole.
fn test_ws_large_binary_round_trip() {
    let r = chat_router(chat_rules());
    let port = ws_start(r, ws_quiet());
    let a = ws_connect(port, "/chat?name=big");
    let ha = handshake(&mut a, "/chat?name=big");
    let blob = b"";
    let i = 0;
    while i < 6000 {
        blob = blob + b"0123456789";
        i = i + 1;
    }
    let _s = a.send_bytes(masked(2, blob), ws_soon(2000));
    let got = frames(&mut a, ha.rest, 1);
    assert(got[0] == "binary:60000", got[0]);
}

// A queue that fills closes the socket instead of making the sender wait.
fn test_ws_full_queue_closes_the_socket() {
    let no: map[str]str = {};
    let s = new_socket("ws_t", "/t", "", "", no, 2, 0, text(101, ""));
    assert(s.send_text("one"));
    assert(s.send_text("two"));
    assert(!s.send_text("three"), "a third message fit in a queue of two");
    assert(!s.is_open());
    assert(s.ended == "overflow");
    assert(!s.send_text("four"));
    assert(!s.close(1000, ""), "close after overflow");
}

fn test_ws_hub_rooms_and_broadcast() {
    let no: map[str]str = {};
    let h = new_hub();
    let a = new_socket("a", "/t", "", "", no, 8, 0, text(101, ""));
    let b = new_socket("b", "/t", "", "", no, 8, 0, text(101, ""));
    let c = new_socket("c", "/t", "", "", no, 8, 0, text(101, ""));
    h.add(a);
    h.join_room(b, "x");
    h.join_room(c, "x");
    assert(h.count() == 3);
    assert(h.room_size("x") == 2);
    assert(h.broadcast("all", "") == 3);
    assert(h.to_room("x", "some", "b") == 1);
    h.leave_room(c, "x");
    assert(h.room_size("x") == 1);
    leave_hubs(b);
    assert(h.count() == 2 && h.room_size("x") == 0);
    let found = h.get("a");
    guard let got = found else { panic("a is in the hub"); }
    assert(got.id == "a");
}

// The same chat over TLS: the writer and reader share one session.
fn wss_serve(ln: link, r: Router[Chat], ctx: rawptr) {
    let mut_ln = ln;
    while true {
        let ar = mut_ln.accept(until_never());
        guard let c = ar else { return; }
        let sc = ws_quiet();
        spawn serve_tls_conn(r, c, sc, ctx);
    }
}

fn test_ws_over_tls() {
    let sc = ws_quiet();
    sc.tls = tls_files("testdata/tls/cert.pem", "testdata/tls/key.pem");
    let lt = load_tls(sc.tls);
    guard let maybe = lt else { panic("load tls"); }
    guard let ctx = maybe else { panic("no ctx"); }
    let r = chat_router(chat_rules());
    let lr = link_listen(0);
    guard let ln = lr else { panic("listen"); }
    let port = ln.port();
    spawn wss_serve(ln, r, ctx);
    let cr: result[rawptr, str] = net.tls_client_ctx("testdata/tls/ca.pem");
    guard let cctx = cr else { panic("client ctx"); }
    let dr: result[rawptr, str] = net.tls_dial("localhost", port, cctx);
    guard let cc = dr else let e = err_of(dr) { panic("dial: " + e); }
    net.tls_send(cc, to_bytes("GET /chat?name=sec HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\n" +
                              "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" +
                              "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"));
    let got = b"";
    while !strings.contains(to_str(got), "\r\n\r\n") {
        let rr: result[bytes, str] = net.tls_recv_until(cc, 4096, ws_soon(2000));
        guard let b = rr else { panic("tls recv"); }
        if len(b) == 0 { panic("tls eof"); }
        got = got + b;
    }
    assert(strings.has_prefix(to_str(got), "HTTP/1.1 101"), to_str(got));
    net.tls_send(cc, masked(1, to_bytes("who")));
    let reply = b"";
    let want = "you are sec in a room of 1";
    while !strings.contains(to_str(reply), want) {
        let rr: result[bytes, str] = net.tls_recv_until(cc, 4096, ws_soon(2000));
        guard let b = rr else { panic("tls recv reply"); }
        if len(b) == 0 { panic("tls eof before reply"); }
        reply = reply + b;
    }
    net.tls_close(cc);
    assert(chat_event(r) == "sec closed 1006 ");
}
