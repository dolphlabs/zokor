import "http";
import "internal/ws";

// A client frame: masked, as RFC 6455 requires of a client.
fn client_frame(op: int, payload: bytes, fin: bool) -> bytes {
    let n = len(payload);
    let out: bytes = b"";
    let one: bytes = b".";
    let b0 = op;
    if fin {
        b0 = b0 | 128;
    }
    one[0] = b0;
    out = out + one;
    if n < 126 {
        one[0] = 128 | n;
        out = out + one;
    } else {
        one[0] = 128 | 126;
        out = out + one;
        one[0] = (n >> 8) & 255;
        out = out + one;
        one[0] = n & 255;
        out = out + one;
    }
    let key = [7, 3, 9, 1];
    let i = 0;
    while i < 4 {
        one[0] = key[i];
        out = out + one;
        i = i + 1;
    }
    i = 0;
    while i < n {
        one[0] = payload[i] ^ key[i % 4];
        out = out + one;
        i = i + 1;
    }
    return out;
}

fn client_text(s: str) -> bytes {
    return client_frame(1, to_bytes(s), true);
}

fn msgs(c: Conn, chunk: bytes) -> [Message] {
    let r = receive(c, chunk);
    guard let m = r else let e = err_of(r) {
        panic("expected messages: " + e);
    }
    return m;
}

fn refusal(c: Conn, chunk: bytes) -> str {
    let r = receive(c, chunk);
    guard let _m = r else let e = err_of(r) {
        return e;
    }
    return "";
}

fn upgrade_req(key: str, protocols: str) -> http.Request {
    let h: map[str]str = {};
    h["upgrade"] = "websocket";
    h["connection"] = "Upgrade";
    h["sec-websocket-version"] = "13";
    h["sec-websocket-key"] = key;
    if len(protocols) > 0 {
        h["sec-websocket-protocol"] = protocols;
    }
    let rr = http.request("GET", "/ws", "HTTP/1.1", h, b"");
    guard let r = rr else {
        panic("upgrade_req: bad test request");
    }
    return r;
}

fn test_upgrade() {
    let req = upgrade_req("dGhlIHNhbXBsZSBub25jZQ==", "");
    assert(is_upgrade(req));
    let r = upgrade(req, default_ws());
    guard let resp = r else {
        panic("expected a 101");
    }
    assert(resp.status == 101);
    assert(resp.headers["sec-websocket-accept"] == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");

    let plain: map[str]str = {};
    let nwr = http.request("GET", "/", "HTTP/1.1", plain, b"");
    guard let not_ws = nwr else {
        panic("not_ws: bad test request");
    }
    assert(!is_upgrade(not_ws));
}

fn test_upgrade_picks_a_subprotocol() {
    let req = upgrade_req("dGhlIHNhbXBsZSBub25jZQ==", "mqtt, chat");
    let r = upgrade(req, ws_allowing(["chat", "superchat"]));
    guard let resp = r else {
        panic("expected a 101");
    }
    assert(resp.headers["sec-websocket-protocol"] == "chat");
}

fn test_text_and_binary_messages() {
    let c = new_conn(default_ws());
    let got = msgs(c, client_text("hello"));
    assert(len(got) == 1);
    assert(got[0].kind == Incoming.Text);
    assert(got[0].text == "hello");

    let bin = client_frame(2, to_bytes("raw"), true);
    let got2 = msgs(c, bin);
    assert(len(got2) == 1);
    assert(got2[0].kind == Incoming.Binary);
    assert(to_str(got2[0].data) == "raw");
}

// A message split across several frames, and a byte stream split at
// arbitrary points: both are normal, and both must come out whole.
fn test_fragmented_message() {
    let c = new_conn(default_ws());
    let a = client_frame(1, to_bytes("Hel"), false);
    let b = client_frame(0, to_bytes("lo "), false);
    let d = client_frame(0, to_bytes("there"), true);
    assert(len(msgs(c, a)) == 0);
    assert(len(msgs(c, b)) == 0);
    let got = msgs(c, d);
    assert(len(got) == 1);
    assert(got[0].text == "Hello there");
}

fn test_a_frame_split_across_reads() {
    let c = new_conn(default_ws());
    let f = client_text("split me");
    let n = len(f);
    let i = 0;
    while i < n - 1 {
        assert(len(msgs(c, f[i..i + 1])) == 0);
        i = i + 1;
    }
    let got = msgs(c, f[n - 1..n]);
    assert(len(got) == 1);
    assert(got[0].text == "split me");
}

fn test_many_frames_in_one_read() {
    let c = new_conn(default_ws());
    let got = msgs(c, client_text("one") + client_text("two") +
                      client_text("three"));
    assert(len(got) == 3);
    assert(got[0].text == "one");
    assert(got[2].text == "three");
}

// A ping is answered by the connection itself, so a service that only
// cares about messages still keeps its clients alive.
fn test_ping_is_answered_automatically() {
    let c = new_conn(default_ws());
    let got = msgs(c, client_frame(9, to_bytes("beat"), true));
    assert(len(got) == 1);
    assert(got[0].kind == Incoming.Ping);
    let owed = pending(c);
    assert(len(owed) > 0);
    let r = ws.decode(owed, 0, 1048576, false);
    guard let d = r else { panic("the pong should decode"); }
    assert(d.frame.op == ws.Op.Pong);
    assert(to_str(d.frame.payload) == "beat");
    assert(len(pending(c)) == 0);
}

// A control frame may arrive in the middle of a fragmented message.
fn test_ping_between_fragments() {
    let c = new_conn(default_ws());
    msgs(c, client_frame(1, to_bytes("part "), false));
    let mid = msgs(c, client_frame(9, b"", true));
    assert(len(mid) == 1);
    assert(mid[0].kind == Incoming.Ping);
    let got = msgs(c, client_frame(0, to_bytes("two"), true));
    assert(len(got) == 1);
    assert(got[0].text == "part two");
}

fn test_close_handshake() {
    let c = new_conn(default_ws());
    let body: bytes = b"..";
    body[0] = 3;
    body[1] = 232;          // 1000
    let got = msgs(c, client_frame(8, body + to_bytes("bye"), true));
    assert(len(got) == 1);
    assert(got[0].kind == Incoming.Close);
    assert(got[0].code == 1000);
    assert(got[0].reason == "bye");
    assert(is_closed(c));
    let echo = pending(c);
    let r = ws.decode(echo, 0, 1048576, false);
    guard let d = r else { panic("the close echo should decode"); }
    assert(d.frame.op == ws.Op.Close);
}

fn test_protocol_errors_are_reported_once() {
    let c = new_conn(default_ws());
    // a continuation with nothing to continue
    assert(refusal(c, client_frame(0, to_bytes("x"), true)) ==
           "a continuation frame with nothing to continue");

    let c2 = new_conn(default_ws());
    msgs(c2, client_frame(1, to_bytes("start"), false));
    assert(refusal(c2, client_frame(1, to_bytes("again"), true)) ==
           "a new message started before the last one finished");

    let c3 = new_conn(default_ws());
    let bad: bytes = b"..";
    bad[0] = 255;
    bad[1] = 254;
    assert(refusal(c3, client_frame(1, bad, true)) ==
           "a text message must be valid UTF-8");
}

fn test_message_size_limit() {
    let rules = default_ws();
    rules.max_message_bytes = 8;
    let c = new_conn(rules);
    msgs(c, client_frame(1, to_bytes("12345"), false));
    assert(refusal(c, client_frame(0, to_bytes("67890"), true)) ==
           "message exceeds the 8-byte limit");
}

fn test_close_because_is_sent_once() {
    let c = new_conn(default_ws());
    let out = close_because(c, "protocol error");
    assert(len(out) > 0);
    assert(is_closed(c));
    assert(len(close_because(c, "again")) == 0);
}

fn test_frames_we_send() {
    let t = text_frame("hi");
    assert(t[0] == 129);
    assert(t[1] == 2);
    let b = binary_frame(to_bytes("xy"));
    assert(b[0] == 130);
    let cl = close_frame(1001, "going");
    let r = ws.decode(cl, 0, 1048576, false);
    guard let d = r else { panic("close frame should decode"); }
    let cr = ws.decode_close(d.frame.payload);
    guard let body = cr else { panic("close body should decode"); }
    assert(body.code == 1001);
    assert(body.reason == "going");
}

// ---------------------------------------------------------------- //
// socket.io                                                          //
// ---------------------------------------------------------------- //

fn sio_of(c: Conn, m: Message) -> SioEvent {
    let r = sio_receive(c, m);
    guard let e = r else let why = err_of(r) {
        panic("expected a socket.io event: " + why);
    }
    return e;
}

fn only(c: Conn, chunk: bytes) -> Message {
    let got = msgs(c, chunk);
    assert(len(got) == 1);
    return got[0];
}

// The exchange a socket.io client actually performs.
fn test_socketio_session() {
    let c = new_conn(default_ws());

    // the server opens with the session id and the keepalive timings
    let open = sio_open(c, "sid-1", default_sio());
    let r = ws.decode(open, 0, 1048576, false);
    guard let d = r else { panic("the open frame should decode"); }
    assert(to_str(d.frame.payload) ==
        "0{\"sid\":\"sid-1\",\"upgrades\":[],\"pingInterval\":25000,\"pingTimeout\":20000,\"maxPayload\":1000000}");

    // the client connects to the default namespace
    let ev = sio_of(c, only(c, client_text("40")));
    assert(ev.kind == SioKind.Connect);
    assert(ev.namespace == "/");
    let reply = sio_connect_ok(c, "/");
    let r2 = ws.decode(reply, 0, 1048576, false);
    guard let d2 = r2 else { panic("connect_ok should decode"); }
    assert(to_str(d2.frame.payload) == "40{\"sid\":\"sid-1\"}");

    // an event
    let ev2 = sio_of(c, only(c, client_text("42[\"chat message\",\"hi\"]")));
    assert(ev2.kind == SioKind.Event);
    assert(ev2.name == "chat message");
    assert(ev2.args_json == "[\"hi\"]");
    assert(ev2.ack == -1);

    // the server emits one back
    let out = sio_emit("/", "chat message", "[\"hello yourself\"]");
    let r3 = ws.decode(out, 0, 1048576, false);
    guard let d3 = r3 else { panic("emit should decode"); }
    assert(to_str(d3.frame.payload) == "42[\"chat message\",\"hello yourself\"]");
}

fn test_socketio_keepalive_is_answered() {
    let c = new_conn(default_ws());
    let ev = sio_of(c, only(c, client_text("2")));
    assert(ev.kind == SioKind.Ping);
    let owed = pending(c);
    let r = ws.decode(owed, 0, 1048576, false);
    guard let d = r else { panic("the pong frame should decode"); }
    assert(to_str(d.frame.payload) == "3");
}

fn test_socketio_acks_and_namespaces() {
    let c = new_conn(default_ws());
    let ev = sio_of(c, only(c, client_text("42/admin,7[\"kick\",{\"id\":3}]")));
    assert(ev.kind == SioKind.Event);
    assert(ev.namespace == "/admin");
    assert(ev.name == "kick");
    assert(ev.args_json == "[{\"id\":3}]");
    assert(ev.ack == 7);

    let reply = sio_ack("/admin", 7, "[\"done\"]");
    let r = ws.decode(reply, 0, 1048576, false);
    guard let d = r else { panic("ack should decode"); }
    assert(to_str(d.frame.payload) == "43/admin,7[\"done\"]");

    let bye = sio_of(c, only(c, client_text("41/admin,")));
    assert(bye.kind == SioKind.Disconnect);
    assert(bye.namespace == "/admin");
}

fn test_socketio_rejects_a_binary_frame_as_a_packet() {
    let c = new_conn(default_ws());
    let m = only(c, client_frame(2, to_bytes("raw"), true));
    let r = sio_receive(c, m);
    guard let _e = r else let why = err_of(r) {
        assert(why == "a socket.io packet must arrive in a text frame");
        return;
    }
    panic("a binary frame was accepted as a socket.io packet");
}
