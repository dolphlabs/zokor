import "http";
import "strings";
import "time";

// Socket.IO over a served WebSocket, against a client that speaks what
// socket.io-client 4 sends with transports: ["websocket"].

gc struct Room {
    hub: Hub,
    events: chan[str],
}

fn room_open(c: Ctx[Room]) -> http.Response {
    let s = c.socket();
    s.set_local("name", c.query("name"));
    c.state.hub.join_room(s, "all");
    return c.accept_ws();
}

fn room_connect(app: Room, s: Socket, ns: str, auth: str) -> result[bool, str] {
    if ns == "/admin" {
        return err("not allowed");
    }
    chan_send(app.events, s.local("name") + " connected " + ns + " auth=" + auth);
    return ok(true);
}

fn room_event(app: Room, s: Socket, e: SioEvent) {
    if e.kind == SioKind.Ack {
        chan_send(app.events, s.local("name") + " acked " + to_str(e.ack) + " " + e.args_json);
        return;
    }
    if e.name == "boom" {
        panic("event handler exploded");
    }
    if e.name == "ask" {
        s.emit_with_ack(e.namespace, "question", "\"ready?\"", 7);
        return;
    }
    if e.name == "chat message" {
        app.hub.emit_to_room("all", e.namespace, "chat message", e.args_json, s.id);
    }
    if e.ack >= 0 {
        s.ack(e.namespace, e.ack, "[\"delivered\"]");
    }
}

fn room_left(app: Room, s: Socket, ns: str, why: str) {
    chan_send(app.events, s.local("name") + " left " + ns + ": " + why);
}

fn room_router(st: SioSettings) -> Router[Room] {
    let ev: chan[str] = make_chan(64);
    let r = new_router(Room { hub: new_hub(), events: ev });
    let route = sio_route(room_event).on_connect(room_connect).on_disconnect(room_left);
    route.settings = st;
    r.socketio("/socket.io/", room_open, route);
    return r;
}

fn room_start(r: Router[Room]) -> int {
    let lr = link_listen(0);
    guard let ln = lr else { panic("listen"); }
    let port = ln.port();
    spawn room_serve(ln, r);
    return port;
}

fn room_serve(ln: link, r: Router[Room]) {
    let mut_ln = ln;
    while true {
        let ar = mut_ln.accept(until_never());
        guard let c = ar else { return; }
        spawn serve_conn(r, c, ws_quiet());
    }
}

fn room_event_next(r: Router[Room]) -> str {
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

fn eio_path(name: str) -> str {
    return "/socket.io/?EIO=4&transport=websocket&name=" + name;
}

// The texts of the next `n` frames, without the "text:" prefix.
fn texts(c: &mut link, pending: bytes, n: int) -> [str] {
    let out: [str] = [];
    for f in frames(c, pending, n) {
        if strings.has_prefix(f, "text:") {
            push(out, strings.slice(f, 5, len(f)));
        } else {
            push(out, f);
        }
    }
    return out;
}

fn test_sio_session_connect_emit_ack_and_broadcast() {
    let r = room_router(default_sio());
    let port = room_start(r);
    let a = ws_connect(port, "");
    let ha = handshake(&mut a, eio_path("ada"));
    assert(ha.status == "HTTP/1.1 101 Switching Protocols", ha.status);
    let open = texts(&mut a, ha.rest, 1);
    assert(strings.has_prefix(open[0], "0{\"sid\":\""), open[0]);
    assert(strings.contains(open[0], "\"upgrades\":[],\"pingInterval\":25000,\"pingTimeout\":20000"), open[0]);
    let _c = a.send_bytes(masked(1, to_bytes("40{\"token\":\"t1\"}")), ws_soon(1000));
    let ok_a = texts(&mut a, b"", 1);
    assert(strings.has_prefix(ok_a[0], "40{\"sid\":\""), ok_a[0]);
    assert(room_event_next(r) == "ada connected / auth={\"token\":\"t1\"}");

    let b = ws_connect(port, "");
    let hb = handshake(&mut b, eio_path("bo"));
    let _o = texts(&mut b, hb.rest, 1);
    let _c2 = b.send_bytes(masked(1, to_bytes("40")), ws_soon(1000));
    let _ok_b = texts(&mut b, b"", 1);
    assert(room_event_next(r) == "bo connected / auth=");

    // an event with an ack id: bo hears it, ada gets the ack
    let _e = a.send_bytes(masked(1, to_bytes("423[\"chat message\",\"hi\"]")), ws_soon(1000));
    let at_b = texts(&mut b, b"", 1);
    assert(at_b[0] == "42[\"chat message\",\"hi\"]", at_b[0]);
    let ack = texts(&mut a, b"", 1);
    assert(ack[0] == "433[\"delivered\"]", ack[0]);

    // the server asks, the client answers
    let _q = b.send_bytes(masked(1, to_bytes("42[\"ask\"]")), ws_soon(1000));
    let question = texts(&mut b, b"", 1);
    assert(question[0] == "427[\"question\",\"ready?\"]", question[0]);
    let _ans = b.send_bytes(masked(1, to_bytes("437[\"yes\"]")), ws_soon(1000));
    assert(room_event_next(r) == "bo acked 7 [\"yes\"]");

    // a namespace on_connect refuses, and an event for it is dropped
    let _ad = a.send_bytes(masked(1, to_bytes("40/admin,")), ws_soon(1000));
    let refused = texts(&mut a, b"", 1);
    assert(refused[0] == "44/admin,{\"message\":\"not allowed\"}", refused[0]);
    let _drop = a.send_bytes(masked(1, to_bytes("42/admin,[\"chat message\",\"secret\"]")), ws_soon(1000));

    // leaving "/": on_disconnect says why; the session itself stays
    let _l = b.send_bytes(masked(1, to_bytes("41")), ws_soon(1000));
    assert(room_event_next(r) == "bo left /: client namespace disconnect");
    // ada closes the transport: on_disconnect for "/" with that reason
    let _x = a.send_bytes(masked(8, close_payload(1000, "")), ws_soon(1000));
    assert(room_event_next(r) == "ada left /: transport close");
}

// The heartbeat: a ping every pingInterval even while the client is
// talking (socket.io-client counts the time between pings), and a client
// that stops answering is gone after pingTimeout.
fn test_sio_heartbeat_and_ping_timeout() {
    let st = default_sio();
    st.ping_interval_ms = 120;
    st.ping_timeout_ms = 150;
    let r = room_router(st);
    let port = room_start(r);
    let a = ws_connect(port, "");
    let ha = handshake(&mut a, eio_path("chatty"));
    let open = texts(&mut a, ha.rest, 1);
    assert(strings.contains(open[0], "\"pingInterval\":120,\"pingTimeout\":150"), open[0]);
    let _c = a.send_bytes(masked(1, to_bytes("40")), ws_soon(1000));
    let _ok = texts(&mut a, b"", 1);
    assert(room_event_next(r) == "chatty connected / auth=");
    // talking every 30ms must not delay the ping
    let t0 = time.mono();
    let saw_ping = false;
    let i = 0;
    while i < 12 && !saw_ping {
        let _t = a.send_bytes(masked(1, to_bytes("42[\"noise\"]")), ws_soon(1000));
        let ar = arena_new(256);
        let w = ar.wire(256);
        let rr = a.recv(w, ws_soon(30));
        if let n = rr {
            if n >= 3 && w[0] == 129 && w[1] == 1 && w[2] == 50 {
                saw_ping = true;
            }
        }
        i = i + 1;
    }
    assert(saw_ping, "no ping while the client talked");
    let took = (time.mono() - t0) as int;
    assert(took < 400000000, "the ping waited for silence: " + to_str(took));
    let _p = a.send_bytes(masked(1, to_bytes("3")), ws_soon(1000));
    // now silence: the next ping goes unanswered, and the session ends
    assert(room_event_next(r) == "chatty left /: ping timeout");
}

fn test_sio_handshake_checks_the_query() {
    let r = room_router(default_sio());
    let port = room_start(r);
    let a = ws_connect(port, "");
    let ha = handshake(&mut a, "/socket.io/?EIO=3&transport=websocket");
    assert(strings.has_prefix(ha.status, "HTTP/1.1 400"), ha.status);
    let b = ws_connect(port, "");
    let hb = handshake(&mut b, "/socket.io/?EIO=4&transport=carrier-pigeon");
    assert(strings.has_prefix(hb.status, "HTTP/1.1 400"), hb.status);
}

// A panicking event handler ends that session (1011) and tells
// on_disconnect; the server carries on.
fn test_sio_event_handler_panic() {
    let r = room_router(default_sio());
    let port = room_start(r);
    let a = ws_connect(port, "");
    let ha = handshake(&mut a, eio_path("oops"));
    let _o = texts(&mut a, ha.rest, 1);
    let _c = a.send_bytes(masked(1, to_bytes("40")), ws_soon(1000));
    let _ok = texts(&mut a, b"", 1);
    assert(room_event_next(r) == "oops connected / auth=");
    let _b = a.send_bytes(masked(1, to_bytes("42[\"boom\"]")), ws_soon(1000));
    let got = texts(&mut a, b"", 1);
    assert(got[0] == "close:1011 internal error", got[0]);
    let _e = a.send_bytes(masked(8, close_payload(1011, "")), ws_soon(1000));
    assert(room_event_next(r) == "oops left /: server error");
}
