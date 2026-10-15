import "http";
import "net";
import "strings";
import "time";

// testdata/tls: a test CA, a server certificate it signed (localhost and
// 127.0.0.1), and a client certificate it signed, for mutual TLS.

fn tls_hi(c: Ctx[ServeState]) -> http.Response {
    return text(200, "hi over " + c.method_str());
}

fn tls_router() -> Router[ServeState] {
    let r = new_router(ServeState { hits: 0 });
    r.get("/hi", tls_hi);
    return r;
}

fn tls_config() -> ServerConfig {
    let sc = default_server_config();
    sc.logger = no_logger();
    sc.tls = tls_files("testdata/tls/cert.pem", "testdata/tls/key.pem");
    sc.tls.handshake_timeout = 300000000;
    return sc;
}

fn loaded(t: TlsSettings) -> rawptr {
    let lr = load_tls(t);
    guard let maybe = lr else let e = err_of(lr) { panic("load_tls: " + e); }
    guard let ctx = maybe else { panic("load_tls gave no context"); }
    return ctx;
}

fn trusting_client() -> rawptr {
    let r: result[rawptr, str] = net.tls_client_ctx("testdata/tls/ca.pem");
    guard let c = r else let e = err_of(r) { panic("client ctx: " + e); }
    return c;
}

// Everything the server sends until it closes, or 2 seconds pass.
fn read_all_tls(cc: rawptr) -> str {
    let got = b"";
    let deadline = until_of(time.mono() + 2000000000);
    while true {
        let rr: result[bytes, str] = net.tls_recv_until(cc, 4096, deadline);
        guard let chunk = rr else { break; }
        if len(chunk) == 0 { break; }
        got = got + chunk;
    }
    return to_str(got);
}

fn test_tls_is_off_by_default() {
    assert(!default_server_config().tls.on);
    let sc = server_config_from(cfg_of("SERVICE_NAME=api\n"));
    assert(!sc.tls.on);
    let lr = load_tls(sc.tls);
    guard let maybe = lr else { panic("load_tls with TLS off failed"); }
    if let _c = maybe { panic("TLS off made a context"); }
}

fn test_tls_from_config() {
    let c = cfg_of("TLS_CERT_FILE=/etc/certs/a.pem\nTLS_KEY_FILE=/etc/certs/a.key\nTLS_HANDSHAKE_TIMEOUT=3s\n");
    let sc = server_config_from(c);
    assert(sc.tls.on);
    assert(sc.tls.cert_file == "/etc/certs/a.pem");
    assert(sc.tls.key_file == "/etc/certs/a.key");
    assert(sc.tls.client_ca_file == "");
    assert(sc.tls.handshake_timeout == 3000000000);
    let ck = check(c);
    guard let _ok = ck else { panic("a complete TLS config was rejected"); }
}

// A certificate without its key, a key without its certificate, and a
// client CA with neither, each reported -- and TLS left off rather than
// half on.
fn test_tls_config_problems_are_reported() {
    let cases = [
        "TLS_CERT_FILE=a.pem\n",
        "TLS_KEY_FILE=a.key\n",
        "TLS_CLIENT_CA_FILE=ca.pem\n"
    ];
    let wants = ["TLS_KEY_FILE", "TLS_CERT_FILE", "TLS_CLIENT_CA_FILE"];
    let i = 0;
    while i < len(cases) {
        let c = cfg_of(cases[i]);
        let sc = server_config_from(c);
        assert(!sc.tls.on, cases[i] + " turned TLS on");
        let ck = check(c);
        if let _ok = ck {
            panic(cases[i] + " was accepted");
        } else let e = err_of(ck) {
            assert(strings.contains(e, wants[i]), "got: " + e);
        }
        i = i + 1;
    }
}

fn test_load_tls_names_the_setting_that_failed() {
    let lr = load_tls(tls_files("testdata/tls/missing.pem", "testdata/tls/key.pem"));
    if let _c = lr {
        panic("a missing certificate loaded");
    } else let e = err_of(lr) {
        assert(strings.has_prefix(e, "cannot load TLS_CERT_FILE/TLS_KEY_FILE: "), e);
    }
    let t = tls_files("testdata/tls/cert.pem", "testdata/tls/key.pem");
    t.client_ca_file = "testdata/tls/missing-ca.pem";
    let cr = load_tls(t);
    if let _c2 = cr {
        panic("a missing client CA loaded");
    } else let e2 = err_of(cr) {
        assert(strings.has_prefix(e2, "cannot load TLS_CLIENT_CA_FILE: "), e2);
    }
}

// A server whose certificate does not load does not start: it returns
// before binding, with the reason.
fn test_tls_listen_refuses_to_start_without_its_certificate() {
    let sc = tls_config();
    sc.tls.cert_file = "testdata/tls/missing.pem";
    let r = listen_and_serve_with(tls_router(), 0, sc);
    if let _n = r {
        panic("served with a missing certificate");
    } else let e = err_of(r) {
        assert(strings.contains(e, "TLS_CERT_FILE"), e);
    }
}

fn serve_then_report(ln: link, ctx: rawptr, sc: ServerConfig, done: chan[int]) {
    let mut_ln = ln;
    let ar = mut_ln.accept(until_of(time.mono() + 2000000000));
    guard let server = ar else { chan_send(done, -1); return; }
    serve_tls_conn(tls_router(), server, sc, ctx);
    chan_send(done, 1);
}

// Two requests on one HTTPS connection, through the real loop: the
// handshake, keep-alive, and the close the second one asks for.
fn test_tls_https_request_through_serve_tls_conn() {
    let ctx = loaded(tls_config().tls);
    let lr = link_listen(0);
    guard let ln = lr else { panic("listen"); }
    let port = ln.port();
    let done: chan[int] = make_chan(1);
    spawn serve_then_report(ln, ctx, tls_config(), done);
    let dr: result[rawptr, str] = net.tls_dial("localhost", port, trusting_client());
    guard let cc = dr else let e = err_of(dr) { panic("dial: " + e); }
    net.tls_send(cc, b"GET /hi HTTP/1.1\r\nHost: localhost\r\n\r\n");
    let first: result[bytes, str] = net.tls_recv_until(cc, 4096, until_of(time.mono() + 2000000000));
    guard let one = first else { panic("first response"); }
    let a = to_str(one);
    assert(strings.has_prefix(a, "HTTP/1.1 200"), a);
    assert(strings.contains(a, "hi over GET"), a);
    assert(strings.contains(strings.to_lower(a), "strict-transport-security"), a);
    net.tls_send(cc, b"GET /hi HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    let b = read_all_tls(cc);
    assert(strings.has_prefix(b, "HTTP/1.1 200"), b);
    assert(strings.contains(strings.to_lower(b), "connection: close"), b);
    net.tls_close(cc);
    assert((chan_recv(done) ?? 0) == 1, "serve_tls_conn did not return");
}

// A plaintext request to the HTTPS port gets no plaintext answer -- that
// would be an HTTP response on a TLS port -- and the connection ends.
fn test_tls_plaintext_client_is_closed_without_an_answer() {
    let ctx = loaded(tls_config().tls);
    let lr = link_listen(0);
    guard let ln = lr else { panic("listen"); }
    let port = ln.port();
    let done: chan[int] = make_chan(1);
    spawn serve_then_report(ln, ctx, tls_config(), done);
    let dr = link_dial("127.0.0.1", port, until_never());
    guard let client = dr else { panic("dial"); }
    let _s = client.send_bytes(b"GET /hi HTTP/1.1\r\nHost: t\r\n\r\n", until_never());
    let a = arena_new(1024);
    let w = a.wire(1024);
    let rr = client.recv(w, until_of(time.mono() + 2000000000));
    if let n = rr {
        // an OpenSSL alert is all that may come back, never HTTP
        if n >= 4 {
            assert(!(w[0] == 72 && w[1] == 84 && w[2] == 84 && w[3] == 80),
                   "a plaintext HTTP answer on the TLS port");
        }
    }
    assert((chan_recv(done) ?? 0) == 1, "serve_tls_conn did not return");
}

// A client that connects and never starts the handshake is closed at
// handshake_timeout (300ms here), not held for the idle timeout.
fn test_tls_silent_client_is_closed_at_handshake_timeout() {
    let ctx = loaded(tls_config().tls);
    let lr = link_listen(0);
    guard let ln = lr else { panic("listen"); }
    let port = ln.port();
    let done: chan[int] = make_chan(1);
    let t0 = time.mono();
    spawn serve_then_report(ln, ctx, tls_config(), done);
    let dr = link_dial("127.0.0.1", port, until_never());
    guard let _client = dr else { panic("dial"); }
    assert((chan_recv(done) ?? 0) == 1);
    let took = (time.mono() - t0) as int;
    assert(took >= 250000000 && took < 2000000000, "took " + to_str(took));
}

fn mtls_config() -> ServerConfig {
    let sc = tls_config();
    sc.tls.client_ca_file = "testdata/tls/ca.pem";
    return sc;
}

// With TLS_CLIENT_CA_FILE, a client without a certificate from that CA
// gets nothing; one with it is served.
fn test_tls_mutual_requires_a_client_certificate() {
    let ctx = loaded(mtls_config().tls);
    let lr = link_listen(0);
    guard let ln = lr else { panic("listen"); }
    let port = ln.port();
    let done: chan[int] = make_chan(1);
    spawn serve_then_report(ln, ctx, mtls_config(), done);
    let dr: result[rawptr, str] = net.tls_dial("localhost", port, trusting_client());
    if let cc = dr {
        // TLS 1.3: the rejection may only show on the first read
        net.tls_send(cc, b"GET /hi HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        let got = read_all_tls(cc);
        assert(!strings.contains(got, "hi over"), "served without a client certificate");
        net.tls_close(cc);
    }
    assert((chan_recv(done) ?? 0) == 1);

    let lr2 = link_listen(0);
    guard let ln2 = lr2 else { panic("listen"); }
    let port2 = ln2.port();
    spawn serve_then_report(ln2, ctx, mtls_config(), done);
    let cctx = trusting_client();
    let ur: result[bool, str] = net.tls_ctx_use_cert(cctx, "testdata/tls/client.pem",
                                                     "testdata/tls/client-key.pem");
    guard let _u = ur else let ue = err_of(ur) { panic("client cert: " + ue); }
    let dr2: result[rawptr, str] = net.tls_dial("localhost", port2, cctx);
    guard let cc2 = dr2 else let e = err_of(dr2) { panic("mtls dial: " + e); }
    net.tls_send(cc2, b"GET /hi HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    let ok_body = read_all_tls(cc2);
    assert(strings.contains(ok_body, "hi over GET"), ok_body);
    net.tls_close(cc2);
    assert((chan_recv(done) ?? 0) == 1);
}
