import "http";
import "time";

gc struct ServeState { hits: int }

fn ok_hi(c: Ctx[ServeState]) -> http.Response {
    return text(200, "hi");
}

fn test_default_server_config_is_safe() {
    let d = default_server_config();
    // Safe rather than infinite: every field is a real, positive
    // bound, not 0 (which would time out immediately) and not left
    // unset.
    assert(d.idle_timeout > 0);
    assert(d.header_timeout > 0);
    assert(d.body_timeout > 0);
    assert(d.write_timeout > 0);
    // The relative shape the doc comment claims: idle is the most
    // generous (a real client legitimately sits idle between
    // requests), header the tightest (nothing legitimate takes long
    // to send a request line and headers once it starts).
    assert(d.idle_timeout > d.body_timeout);
    assert(d.body_timeout > d.header_timeout);
}

fn test_server_config_from_defaults_when_unset() {
    let c = cfg_of("SERVICE_NAME=api\n");
    let sc = server_config_from(c);
    let d = default_server_config();
    assert(sc.idle_timeout == d.idle_timeout);
    assert(sc.header_timeout == d.header_timeout);
    assert(sc.body_timeout == d.body_timeout);
    assert(sc.write_timeout == d.write_timeout);
}

fn test_server_config_from_overrides() {
    let c = cfg_of("IDLE_TIMEOUT=1s\nREAD_HEADER_TIMEOUT=250ms\nREAD_BODY_TIMEOUT=2s\nWRITE_TIMEOUT=3s\n");
    let sc = server_config_from(c);
    assert(sc.idle_timeout == 1000000000);
    assert(sc.header_timeout == 250000000);
    assert(sc.body_timeout == 2000000000);
    assert(sc.write_timeout == 3000000000);
}

fn short_config() -> ServerConfig {
    return ServerConfig {
        idle_timeout: 200000000,
        header_timeout: 200000000,
        body_timeout: 200000000,
        write_timeout: 200000000
    };
}

fn serve_test_router() -> Router[ServeState] {
    let r = new_router(ServeState { hits: 0 });
    r.get("/hi", ok_hi);
    return r;
}

// A real request over a real socket pair, well within every deadline:
// wiring ServerConfig through serve_conn must not change ordinary
// behavior. Connected inline rather than through a shared helper
// returning both ends: `link` is move-only (spawn takes it, not a
// reference), and a struct field cannot be moved out of individually.
fn test_serve_conn_normal_request() {
    let lr = link_listen(0);
    guard let ln = lr else { panic("listen"); }
    let dr = link_dial("127.0.0.1", ln.port(), until_never());
    guard let client = dr else { panic("dial"); }
    let ar = ln.accept(until_never());
    guard let server = ar else { panic("accept"); }
    let r = serve_test_router();
    spawn serve_conn(r, server, default_server_config());
    let req = to_bytes("GET /hi HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    let a = arena_new(512);
    let out = a.wire(len(req));
    let i = 0;
    while i < len(req) {
        out[i] = req[i];
        i = i + 1;
    }
    let sr = client.send(out, until_never());
    guard let _n = sr else { panic("client send"); }
    let inb = a.wire(256);
    let rr = client.recv(inb, until_of(time.mono() + 2000000000));
    guard let n = rr else { panic("client recv"); }
    if n < 12 { panic("response too short"); }
    if inb[9] != 50 { panic("expected status 200"); }
    println("serve_conn_normal_request ok");
}

// Nothing sent at all: idle_timeout governs, and serve_conn actually
// closes the connection (rather than holding it, or the task, open
// forever) once it fires. Observed from the CLIENT side, which sees
// its peer close: a 0-byte read.
fn test_serve_conn_idle_closes_connection() {
    let lr = link_listen(0);
    guard let ln = lr else { panic("listen"); }
    let dr = link_dial("127.0.0.1", ln.port(), until_never());
    guard let client = dr else { panic("dial"); }
    let ar = ln.accept(until_never());
    guard let server = ar else { panic("accept"); }
    let r = serve_test_router();
    spawn serve_conn(r, server, short_config());
    let a = arena_new(256);
    let inb = a.wire(256);
    let t0 = time.mono();
    let rr = client.recv(inb, until_of(time.mono() + 2000000000));
    let dt = time.mono() - t0;
    guard let n = rr else {
        // A recv error (connection reset) is an acceptable way for
        // this to surface too, depending on how the OS reports a
        // half-closed peer -- either shape means the connection did
        // not hang.
        if dt > 2000000000 { panic("idle close took too long"); }
        println("serve_conn_idle_closes_connection: recv err");
        return;
    }
    if dt > 2000000000 { panic("idle close took too long"); }
    if n != 0 { panic("expected a 0-byte read (peer closed), got " + to_str(n)); }
    println("serve_conn_idle_closes_connection ok");
}

test_default_server_config_is_safe();
test_server_config_from_defaults_when_unset();
test_server_config_from_overrides();
test_serve_conn_normal_request();
test_serve_conn_idle_closes_connection();
