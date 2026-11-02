fn masked_frame(op: int, payload: str, key: [int]) -> bytes {
    let p = to_bytes(payload);
    let n = len(p);
    let out: bytes = b"";
    let one: bytes = b".";
    one[0] = 128 | op;
    out = out + one;
    one[0] = 128 | n;
    out = out + one;
    let i = 0;
    while i < 4 {
        one[0] = key[i];
        out = out + one;
        i = i + 1;
    }
    i = 0;
    while i < n {
        one[0] = p[i] ^ key[i % 4];
        out = out + one;
        i = i + 1;
    }
    return out;
}

fn decoded(buf: bytes) -> Frame {
    let r = decode(buf, 0, 1048576, true);
    guard let d = r else let e = err_of(r) {
        panic("expected a frame, got: " + e);
    }
    if d.kind != Decoded.Frame {
        panic("expected a complete frame");
    }
    return d.frame;
}

fn why(buf: bytes) -> str {
    let r = decode(buf, 0, 1048576, true);
    guard let _d = r else let e = err_of(r) {
        return e;
    }
    return "";
}

fn test_decode_masked_text() {
    let f = decoded(masked_frame(1, "hello", [1, 2, 3, 4]));
    assert(f.fin);
    assert(f.op == Op.Text);
    assert(to_str(f.payload) == "hello");
    assert(f.size == 11);
}

// RFC 6455 section 5.7's own example: a masked "Hello".
fn test_rfc_example_frame() {
    let raw: bytes = b"...........";
    raw[0] = 129;
    raw[1] = 133;
    raw[2] = 55;
    raw[3] = 250;
    raw[4] = 33;
    raw[5] = 61;
    raw[6] = 127;
    raw[7] = 159;
    raw[8] = 77;
    raw[9] = 81;
    raw[10] = 88;
    let f = decoded(raw);
    assert(f.op == Op.Text);
    assert(to_str(f.payload) == "Hello");
}

fn test_unmasked_client_frame_is_refused() {
    let raw: bytes = b".......";
    raw[0] = 129;
    raw[1] = 5;
    raw[2] = 72;
    raw[3] = 101;
    raw[4] = 108;
    raw[5] = 108;
    raw[6] = 111;
    assert(why(raw) == "a client frame must be masked");
}

fn test_incomplete_frames_wait() {
    let full = masked_frame(1, "hello", [9, 8, 7, 6]);
    let r1 = decode(full[0..1], 0, 1048576, true);
    guard let d1 = r1 else { panic("one byte should not be an error"); }
    assert(d1.kind == Decoded.Incomplete);
    let r2 = decode(full[0..6], 0, 1048576, true);
    guard let d2 = r2 else { panic("a partial payload should not be an error"); }
    assert(d2.kind == Decoded.Incomplete);
    let r3 = decode(full, 0, 1048576, true);
    guard let d3 = r3 else { panic("the whole frame should decode"); }
    assert(d3.kind == Decoded.Frame);
}

fn test_two_frames_in_one_buffer() {
    let a = masked_frame(1, "one", [1, 1, 1, 1]);
    let b = masked_frame(1, "two", [2, 2, 2, 2]);
    let buf = a + b;
    let f1 = decoded(buf);
    assert(to_str(f1.payload) == "one");
    let r = decode(buf, f1.size, 1048576, true);
    guard let d = r else { panic("the second frame should decode"); }
    assert(to_str(d.frame.payload) == "two");
    assert(f1.size + d.frame.size == len(buf));
}

fn test_reserved_bits_and_opcodes() {
    let raw = masked_frame(1, "x", [0, 0, 0, 0]);
    raw[0] = 129 | 64;
    assert(why(raw) == "reserved bits set with no extension negotiated");
    let raw2 = masked_frame(3, "x", [0, 0, 0, 0]);
    assert(why(raw2) == "reserved opcode 3");
    let raw3 = masked_frame(11, "x", [0, 0, 0, 0]);
    assert(why(raw3) == "reserved opcode 11");
}

fn test_control_frame_rules() {
    let long = "";
    let i = 0;
    while i < 126 {
        long = long + "a";
        i = i + 1;
    }
    let big_ping = masked_frame(9, long, [1, 2, 3, 4]);
    assert(why(big_ping) == "a control frame must not exceed 125 bytes");
    let frag = masked_frame(9, "x", [1, 2, 3, 4]);
    frag[0] = 9;    // FIN clear
    assert(why(frag) == "a control frame must not be fragmented");
}

fn test_payload_limit() {
    let f = masked_frame(1, "hello", [1, 2, 3, 4]);
    let r = decode(f, 0, 4, true);
    guard let _d = r else let e = err_of(r) {
        assert(e == "frame of 5 bytes exceeds the 4-byte limit");
        return;
    }
    panic("the limit was not enforced");
}

fn test_non_minimal_lengths_are_refused() {
    // a 5-byte payload announced with the 16-bit form
    let raw: bytes = b"............." ;
    raw[0] = 129;
    raw[1] = 128 | 126;
    raw[2] = 0;
    raw[3] = 5;
    let i = 4;
    while i < 13 {
        raw[i] = 0;
        i = i + 1;
    }
    assert(why(raw) == "payload length is not minimally encoded");
}

fn test_encode_round_trip() {
    let out = encode(Op.Text, to_bytes("hi"), true);
    assert(len(out) == 4);
    assert(out[0] == 129);
    assert(out[1] == 2);
    let r = decode(out, 0, 1048576, false);
    guard let d = r else { panic("a server frame should decode"); }
    assert(to_str(d.frame.payload) == "hi");
    assert(d.frame.op == Op.Text);
}

fn test_encode_medium_and_large_lengths() {
    let mid = "";
    let i = 0;
    while i < 300 {
        mid = mid + "x";
        i = i + 1;
    }
    let out = encode(Op.Binary, to_bytes(mid), true);
    assert(out[0] == 130);
    assert(out[1] == 126);
    assert(((out[2] << 8) | out[3]) == 300);
    let r = decode(out, 0, 1048576, false);
    guard let d = r else { panic("should decode"); }
    assert(len(d.frame.payload) == 300);
    assert(d.frame.size == 304);
}

fn test_close_bodies() {
    let out = encode_close(1000, "bye");
    let r = decode(out, 0, 1048576, false);
    guard let d = r else { panic("close should decode"); }
    assert(d.frame.op == Op.Close);
    let cr = decode_close(d.frame.payload);
    guard let body = cr else { panic("close body should decode"); }
    assert(body.code == 1000);
    assert(body.reason == "bye");

    let empty = decode_close(b"");
    guard let e2 = empty else { panic("an empty close body is allowed"); }
    assert(e2.code == 1000);
    assert(e2.reason == "");
}

fn test_close_code_rules() {
    assert(valid_close_code(1000));
    assert(valid_close_code(1011));
    assert(valid_close_code(3000));
    assert(valid_close_code(4999));
    assert(!valid_close_code(1005));
    assert(!valid_close_code(1006));
    assert(!valid_close_code(1015));
    assert(!valid_close_code(999));
    assert(!valid_close_code(5000));
    let one: bytes = b".";
    let r = decode_close(one);
    guard let _b = r else let e = err_of(r) {
        assert(e == "a close frame with a body needs a two-byte code");
        return;
    }
    panic("a one-byte close body was accepted");
}

fn test_utf8_validation() {
    assert(valid_utf8(b""));
    assert(valid_utf8(to_bytes("hello")));
    assert(valid_utf8(to_bytes("résumé")));
    assert(valid_utf8(to_bytes("日本語")));
    assert(valid_utf8(to_bytes("𝄞")));
    let bad: bytes = b"..";
    bad[0] = 255;
    bad[1] = 254;
    assert(!valid_utf8(bad));
    let lone: bytes = b".";
    lone[0] = 128;
    assert(!valid_utf8(lone));
    let truncated: bytes = b"..";
    truncated[0] = 226;
    truncated[1] = 130;
    assert(!valid_utf8(truncated));
    let overlong: bytes = b"..";
    overlong[0] = 192;
    overlong[1] = 175;
    assert(!valid_utf8(overlong));
    let surrogate: bytes = b"...";
    surrogate[0] = 237;
    surrogate[1] = 160;
    surrogate[2] = 128;
    assert(!valid_utf8(surrogate));
}
