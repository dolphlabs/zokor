import "encoding";
import "http";
import "strings";
import "time";

// Engine.IO long-polling against the served route: plain HTTP requests,
// as socket.io-client's polling transport sends them.

fn upload_event(app: Room, s: Socket, e: SioEvent) {
    if e.name == "upload" {
        let total = 0;
        for a in e.attachments {
            total = total + len(a);
        }
        chan_send(app.events, "upload " + to_str(len(e.attachments)) + " " + to_str(total));
        s.emit_binary(e.namespace, "back", "\"copy\"", e.attachments);
        return;
    }
    room_event(app, s, e);
}

fn poll_router(st: SioSettings) -> Router[Room] {
    let ev: chan[str] = make_chan(64);
    let r = new_router(Room { hub: new_hub(), events: ev });
    let route = sio_route(upload_event).on_connect(room_connect).on_disconnect(room_left);
    route.settings = st;
    r.socketio("/socket.io/", room_open, route);
    return r;
}

gc struct Reply {
    status: int,
    body: str,
}

// One request on its own connection; the whole response.
fn http_do(port: int, method: str, target: str, body: bytes) -> Reply {
    let c = ws_connect(port, "");
    let head = method + " " + target + " HTTP/1.1\r\nHost: t\r\nConnection: close\r\n";
    if method == "POST" {
        head = head + "Content-Type: text/plain;charset=UTF-8\r\nContent-Length: " +
               to_str(len(body)) + "\r\n";
    }
    let _s = c.send_bytes(to_bytes(head + "\r\n") + body, ws_soon(2000));
    let a = arena_new(65536);
    let w = a.wire(65536);
    let got = b"";
    while true {
        let rr = c.recv(w, ws_soon(5000));
        guard let n = rr else { break; }
        if n == 0 { break; }
        got = got + to_bytes(w[0..n]);
    }
    let t = to_str(got);
    let at = strings.find(t, "\r\n\r\n");
    if at < 0 || len(t) < 12 {
        return Reply { status: 0, body: t };
    }
    let status = to_int(strings.slice(t, 9, 12)) ?? 0;
    return Reply { status: status, body: strings.slice(t, at + 4, len(t)) };
}

fn poll_url(sid: str) -> str {
    return "/socket.io/?EIO=4&transport=polling&name=pat&sid=" + sid;
}

// The handshake's session id.
fn poll_open(port: int) -> str {
    let r = http_do(port, "GET", "/socket.io/?EIO=4&transport=polling&name=pat", b"");
    assert(r.status == 200, "handshake " + to_str(r.status) + " " + r.body);
    assert(strings.has_prefix(r.body, "0{\"sid\":\""), r.body);
    assert(strings.contains(r.body, "\"upgrades\":[\"websocket\"]"), r.body);
    let rest = strings.slice(r.body, 9, len(r.body));
    return strings.slice(rest, 0, strings.find(rest, "\""));
}

fn packets(body: str) -> [str] {
    return strings.split(body, to_str(b"\x1e"));
}

fn test_sio_polling_session() {
    let r = poll_router(default_sio());
    let port = room_start(r);
    let sid = poll_open(port);
    let p = http_do(port, "POST", poll_url(sid), b"40{\"token\":\"p\"}");
    assert(p.status == 200 && p.body == "ok", to_str(p.status) + " " + p.body);
    assert(room_event_next(r) == "pat connected / auth={\"token\":\"p\"}");
    let g = http_do(port, "GET", poll_url(sid), b"");
    assert(g.status == 200 && g.body == "40{\"sid\":\"" + sid + "\"}", g.body);
    // two events in one POST; the ack comes back on the next GET
    let two = to_bytes("421[\"chat message\",\"one\"]") + b"\x1e" +
              to_bytes("42[\"chat message\",\"two\"]");
    let p2 = http_do(port, "POST", poll_url(sid), two);
    assert(p2.body == "ok", p2.body);
    let g2 = http_do(port, "GET", poll_url(sid), b"");
    let got = packets(g2.body);
    assert(len(got) == 1 && got[0] == "431[\"delivered\"]", g2.body);
    // leaving: Engine.IO close
    let bye = http_do(port, "POST", poll_url(sid), b"1");
    assert(bye.body == "ok", bye.body);
    assert(room_event_next(r) == "pat left /: client namespace disconnect");
}

// Attachments both ways: base64 "b" packets after the event that
// announced them.
fn test_sio_polling_binary_attachments() {
    let r = poll_router(default_sio());
    let port = room_start(r);
    let sid = poll_open(port);
    let _c = http_do(port, "POST", poll_url(sid), b"40");
    let _e = room_event_next(r);
    let _g = http_do(port, "GET", poll_url(sid), b"");
    let payload = to_bytes("452-[\"upload\",{\"_placeholder\":true,\"num\":0},{\"_placeholder\":true,\"num\":1}]") +
                  b"\x1e" + to_bytes("b" + encoding.base64_encode(b"hello")) +
                  b"\x1e" + to_bytes("b" + encoding.base64_encode(b"\x00\x01\x02"));
    let p = http_do(port, "POST", poll_url(sid), payload);
    assert(p.body == "ok", p.body);
    assert(room_event_next(r) == "upload 2 8");
    let g = http_do(port, "GET", poll_url(sid), b"");
    let got = packets(g.body);
    assert(len(got) == 3, g.body);
    assert(got[0] == "452-[\"back\",\"copy\",{\"_placeholder\":true,\"num\":0},{\"_placeholder\":true,\"num\":1}]", got[0]);
    assert(got[1] == "b" + encoding.base64_encode(b"hello"), got[1]);
    assert(got[2] == "b" + encoding.base64_encode(b"\x00\x01\x02"), got[2]);
    // an attachment nobody announced is not Socket.IO
    let stray = http_do(port, "POST", poll_url(sid), to_bytes("b" + encoding.base64_encode(b"x")));
    assert(stray.body == "ok");
    assert(room_event_next(r) == "pat left /: parse error");
}

fn test_sio_polling_refusals() {
    let st = default_sio();
    st.max_polling_sessions = 1;
    let r = poll_router(st);
    let port = room_start(r);
    let unknown = http_do(port, "GET", poll_url("nope"), b"");
    assert(unknown.status == 400 && strings.contains(unknown.body, "Session ID unknown"), unknown.body);
    let post_first = http_do(port, "POST", "/socket.io/?EIO=4&transport=polling", b"40");
    assert(post_first.status == 400, post_first.body);
    let _sid = poll_open(port);
    let full = http_do(port, "GET", "/socket.io/?EIO=4&transport=polling&name=x", b"");
    assert(full.status == 503, to_str(full.status) + " " + full.body);
}

fn waiting_get(port: int, sid: str, out: chan[str]) {
    let g = http_do(port, "GET", poll_url(sid), b"");
    chan_send(out, to_str(g.status) + " " + g.body);
}

// The heartbeat over polling: a GET returns the ping within pingInterval;
// unanswered, the session ends at pingTimeout, and its id is forgotten.
fn test_sio_polling_ping_timeout() {
    let st = default_sio();
    st.ping_interval_ms = 100;
    st.ping_timeout_ms = 150;
    let r = poll_router(st);
    let port = room_start(r);
    let sid = poll_open(port);
    let _c = http_do(port, "POST", poll_url(sid), b"40");
    let _e = room_event_next(r);
    let _g = http_do(port, "GET", poll_url(sid), b"");
    let t0 = time.mono();
    let g = http_do(port, "GET", poll_url(sid), b"");
    assert(g.body == "2", g.body);
    let took = (time.mono() - t0) as int;
    assert(took < 1000000000, "the ping took " + to_str(took));
    // answered: the session lives through the next interval
    let _p = http_do(port, "POST", poll_url(sid), b"3");
    let g2 = http_do(port, "GET", poll_url(sid), b"");
    assert(g2.body == "2", g2.body);
    // not answered this time
    assert(room_event_next(r) == "pat left /: ping timeout");
    let gone = http_do(port, "GET", poll_url(sid), b"");
    assert(gone.status == 400, to_str(gone.status) + " " + gone.body);
}

// Two GETs at once is a broken client: the second is refused and the
// session ends, which also releases the first.
fn test_sio_polling_overlapping_gets_end_the_session() {
    let r = poll_router(default_sio());
    let port = room_start(r);
    let sid = poll_open(port);
    let _c = http_do(port, "POST", poll_url(sid), b"40");
    let _e = room_event_next(r);
    let _g = http_do(port, "GET", poll_url(sid), b"");
    let first: chan[str] = make_chan(1);
    spawn waiting_get(port, sid, first);
    time.sleep(50000000);
    let second = http_do(port, "GET", poll_url(sid), b"");
    assert(second.status == 400, second.body);
    assert(room_event_next(r) == "pat left /: transport error");
    let f = chan_recv(first) ?? "";
    assert(f == "200 1", f);
}

// The upgrade, as socket.io-client does it: probe over the new
// WebSocket, the waiting GET released with a noop, "5", and the session
// carries on over WebSocket with its namespaces intact.
fn test_sio_polling_upgrades_to_websocket() {
    let r = poll_router(default_sio());
    let port = room_start(r);
    let sid = poll_open(port);
    let _c = http_do(port, "POST", poll_url(sid), b"40");
    let _e = room_event_next(r);
    let _g = http_do(port, "GET", poll_url(sid), b"");
    let held: chan[str] = make_chan(1);
    spawn waiting_get(port, sid, held);
    time.sleep(30000000);
    let w = ws_connect(port, "");
    let hw = handshake(&mut w, "/socket.io/?EIO=4&transport=websocket&name=pat&sid=" + sid);
    assert(hw.status == "HTTP/1.1 101 Switching Protocols", hw.status);
    let _p = w.send_bytes(masked(1, to_bytes("2probe")), ws_soon(1000));
    let pong = texts(&mut w, hw.rest, 1);
    assert(pong[0] == "3probe", pong[0]);
    let released = chan_recv(held) ?? "";
    assert(released == "200 6", released);
    let _u = w.send_bytes(masked(1, to_bytes("5")), ws_soon(1000));
    // still connected to "/": an event with an ack works over WebSocket
    let _ev = w.send_bytes(masked(1, to_bytes("429[\"chat message\",\"ws now\"]")), ws_soon(1000));
    let ack = texts(&mut w, b"", 1);
    assert(ack[0] == "439[\"delivered\"]", ack[0]);
    // polling is over for this session
    let late = http_do(port, "GET", poll_url(sid), b"");
    assert(late.status == 400, to_str(late.status) + " " + late.body);
    let _x = w.send_bytes(masked(8, close_payload(1000, "")), ws_soon(1000));
    assert(room_event_next(r) == "pat left /: transport close");
}

// Over WebSocket an attachment is a binary frame of its own, after the
// event's text frame, in both directions.
fn test_sio_websocket_binary_attachments() {
    let r = poll_router(default_sio());
    let port = room_start(r);
    let a = ws_connect(port, "");
    let ha = handshake(&mut a, eio_path("bin"));
    let _o = texts(&mut a, ha.rest, 1);
    let _c = a.send_bytes(masked(1, to_bytes("40")), ws_soon(1000));
    let _ok = texts(&mut a, b"", 1);
    let _e = room_event_next(r);
    let _t = a.send_bytes(masked(1, to_bytes("451-[\"upload\",{\"_placeholder\":true,\"num\":0}]")),
                          ws_soon(1000));
    let _b = a.send_bytes(masked(2, b"\x07\x07\x07\x07"), ws_soon(1000));
    assert(room_event_next(r) == "upload 1 4");
    let back = frames(&mut a, b"", 2);
    assert(back[0] == "text:451-[\"back\",\"copy\",{\"_placeholder\":true,\"num\":0}]", back[0]);
    assert(back[1] == "binary:4", back[1]);
    // a text packet where an attachment is owed: not Socket.IO
    let _t2 = a.send_bytes(masked(1, to_bytes("451-[\"upload\",{\"_placeholder\":true,\"num\":0}]")),
                           ws_soon(1000));
    let _t3 = a.send_bytes(masked(1, to_bytes("42[\"chat message\",\"x\"]")), ws_soon(1000));
    let closed = frames(&mut a, b"", 1);
    assert(strings.has_prefix(closed[0], "close:1003 "), closed[0]);
}
