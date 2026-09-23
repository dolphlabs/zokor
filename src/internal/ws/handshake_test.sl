import "http";

fn hs_req(headers: map[str]str) -> http.Request {
    let rr = http.request("GET", "/ws", "HTTP/1.1", headers, b"");
    guard let r = rr else {
        panic("hs_req: bad test request");
    }
    return r;
}

fn good_headers() -> map[str]str {
    let h: map[str]str = {};
    h["upgrade"] = "websocket";
    h["connection"] = "Upgrade";
    h["sec-websocket-version"] = "13";
    h["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
    return h;
}

fn refusal(h: map[str]str) -> str {
    let r = read(hs_req(h));
    guard let _x = r else let e = err_of(r) {
        return e;
    }
    return "";
}

// RFC 6455 section 1.3: this exact key must produce this exact accept.
fn test_accept_key_rfc_example() {
    assert(accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
}

fn test_reads_a_good_handshake() {
    let r = read(hs_req(good_headers()));
    guard let got = r else let e = err_of(r) {
        panic("expected a handshake: " + e);
    }
    assert(got.key == "dGhlIHNhbXBsZSBub25jZQ==");
    assert(got.version == "13");
    assert(len(got.protocols) == 0);
}

fn test_connection_header_is_a_list() {
    let h = good_headers();
    h["connection"] = "keep-alive, Upgrade";
    let r = read(hs_req(h));
    guard let _got = r else {
        panic("a Connection list containing Upgrade is valid");
    }
    h["connection"] = "keep-alive";
    assert(refusal(h) == "the Connection header must include 'Upgrade'");
}

fn test_case_does_not_matter() {
    let h = good_headers();
    h["upgrade"] = "WebSocket";
    h["connection"] = "UPGRADE";
    let r = read(hs_req(h));
    guard let _got = r else {
        panic("header values are case-insensitive");
    }
}

fn test_refusals() {
    let h = good_headers();
    h["upgrade"] = "h2c";
    assert(refusal(h) == "the Upgrade header must be 'websocket'");

    let h2 = good_headers();
    h2["sec-websocket-version"] = "8";
    assert(refusal(h2) == "unsupported WebSocket version '8'");

    let h3 = good_headers();
    del(h3, "sec-websocket-key");
    assert(refusal(h3) == "the Sec-WebSocket-Key header is required");

    let h4 = good_headers();
    h4["sec-websocket-key"] = "tooshort==";
    assert(refusal(h4) == "the Sec-WebSocket-Key header is not 16 base64 bytes");

    let pr = http.request("POST", "/ws", "HTTP/1.1", good_headers(), b"");
    guard let preq = pr else {
        panic("post handshake test: bad test request");
    }
    let r = read(preq);
    guard let _x = r else let e = err_of(r) {
        assert(e == "a WebSocket handshake must be a GET");
        return;
    }
    panic("a POST handshake was accepted");
}

fn test_response_shape() {
    let resp = response("dGhlIHNhbXBsZSBub25jZQ==", "");
    assert(resp.status == 101);
    assert(resp.status_text == "Switching Protocols");
    assert(resp.headers["upgrade"] == "websocket");
    assert(resp.headers["connection"] == "Upgrade");
    assert(resp.headers["sec-websocket-accept"] == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
    assert(!has(resp.headers, "sec-websocket-protocol"));
    assert(len(resp.body) == 0);

    let with_proto = response("dGhlIHNhbXBsZSBub25jZQ==", "chat");
    assert(with_proto.headers["sec-websocket-protocol"] == "chat");
}

fn test_subprotocol_choice_follows_the_client() {
    let h = good_headers();
    h["sec-websocket-protocol"] = "superchat, chat";
    let r = read(hs_req(h));
    guard let got = r else {
        panic("expected a handshake");
    }
    assert(len(got.protocols) == 2);
    assert(got.protocols[0] == "superchat");
    // the client's order wins
    assert(choose(got.protocols, ["chat", "superchat"]) == "superchat");
    assert(choose(got.protocols, ["chat"]) == "chat");
    assert(choose(got.protocols, ["mqtt"]) == "");
    let none_offered: [str] = [];
    assert(choose(none_offered, ["chat"]) == "");
}
