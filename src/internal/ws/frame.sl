// RFC 6455 framing.
//
// A frame is a header of 2 to 14 bytes and a payload. The header says
// whether this is the last frame of a message, what kind it is, and how
// long it is; a client's frames are additionally masked with a 4-byte
// key that must be XORed off. None of that is negotiable, and a server
// that is lax about it is a server that can be desynchronised by a
// hostile client -- which is why everything below refuses rather than
// guesses.
//
// Nothing here touches a socket: `decode` is handed the bytes received
// so far and says either "here is a frame and it used N bytes" or "not
// yet". That makes every rule testable without a network, and lets the
// caller decide how to read.

pub enum Op {
    Continuation,
    Text,
    Binary,
    Close,
    Ping,
    Pong,
}

pub gc struct Frame {
    fin: bool,
    op: Op,
    payload: bytes,
    // How many bytes of the input this frame occupied, so the caller
    // knows where the next one starts.
    size: int,
}

// What a decode attempt found.
pub enum Decoded {
    Frame,      // a whole frame: `frame` is set
    Incomplete, // nothing wrong, just not all here yet
}

pub gc struct DecodeResult {
    kind: Decoded,
    frame: Frame,
}

fn op_of(code: int) -> result[Op, str] {
    if code == 0 { return ok(Op.Continuation); }
    if code == 1 { return ok(Op.Text); }
    if code == 2 { return ok(Op.Binary); }
    if code == 8 { return ok(Op.Close); }
    if code == 9 { return ok(Op.Ping); }
    if code == 10 { return ok(Op.Pong); }
    return err("reserved opcode " + to_str(code));
}

pub fn code_of(op: Op) -> int {
    if op == Op.Continuation { return 0; }
    if op == Op.Text { return 1; }
    if op == Op.Binary { return 2; }
    if op == Op.Close { return 8; }
    if op == Op.Ping { return 9; }
    return 10;
}

pub fn is_control(op: Op) -> bool {
    return op == Op.Close || op == Op.Ping || op == Op.Pong;
}

// Decodes one frame from `buf` starting at `from`.
//
// `max_payload` bounds a single frame: a client can otherwise announce
// a 2^63-byte payload and make the server wait for it forever, or
// allocate for it.
//
// `expect_mask` is true for a server reading a client: RFC 6455 says a
// client MUST mask and a server MUST close the connection if it does
// not, because an unmasked client frame is how proxies get poisoned.
pub fn decode(buf: bytes, from: int, max_payload: int,
              expect_mask: bool) -> result[DecodeResult, str] {
    let n = len(buf);
    let avail = n - from;
    if avail < 2 {
        return ok(incomplete());
    }
    let b0 = buf[from];
    let b1 = buf[from + 1];
    let fin = (b0 & 128) != 0;
    // RSV1..3 are for extensions, and none were negotiated: a frame
    // that sets one is a frame this server cannot interpret.
    if (b0 & 112) != 0 {
        return err("reserved bits set with no extension negotiated");
    }
    let opr = op_of(b0 & 15);
    guard let op = opr else let e = err_of(opr) {
        return err(e);
    }
    let masked = (b1 & 128) != 0;
    if expect_mask && !masked {
        return err("a client frame must be masked");
    }
    if !expect_mask && masked {
        return err("a server frame must not be masked");
    }
    let short_len = b1 & 127;
    let hdr = 2;
    let plen = short_len;
    if short_len == 126 {
        if avail < 4 {
            return ok(incomplete());
        }
        plen = (buf[from + 2] << 8) | buf[from + 3];
        hdr = 4;
        // RFC 6455: the length must use the shortest form that fits
        if plen < 126 {
            return err("payload length is not minimally encoded");
        }
    } else if short_len == 127 {
        if avail < 10 {
            return ok(incomplete());
        }
        if (buf[from + 2] & 128) != 0 {
            return err("payload length has its high bit set");
        }
        plen = 0;
        let i = 0;
        while i < 8 {
            plen = (plen << 8) | buf[from + 2 + i];
            i = i + 1;
        }
        hdr = 10;
        if plen < 65536 {
            return err("payload length is not minimally encoded");
        }
    }
    // A control frame carries its meaning in a header, so it may not be
    // fragmented and may not be long.
    if is_control(op) {
        if !fin {
            return err("a control frame must not be fragmented");
        }
        if plen > 125 {
            return err("a control frame must not exceed 125 bytes");
        }
    }
    if plen > max_payload {
        return err("frame of " + to_str(plen) + " bytes exceeds the " +
                   to_str(max_payload) + "-byte limit");
    }
    let mask_len = 0;
    if masked {
        mask_len = 4;
    }
    let total = hdr + mask_len + plen;
    if avail < total {
        return ok(incomplete());
    }
    let data_at = from + hdr + mask_len;
    let payload: bytes = b"";
    if plen > 0 {
        payload = buf[data_at..data_at + plen];
        if masked {
            let k0 = buf[from + hdr];
            let k1 = buf[from + hdr + 1];
            let k2 = buf[from + hdr + 2];
            let k3 = buf[from + hdr + 3];
            let i = 0;
            while i < plen {
                let m = k0;
                let phase = i % 4;
                if phase == 1 { m = k1; }
                if phase == 2 { m = k2; }
                if phase == 3 { m = k3; }
                payload[i] = payload[i] ^ m;
                i = i + 1;
            }
        }
    }
    return ok(DecodeResult {
        kind: Decoded.Frame,
        frame: Frame { fin: fin, op: op, payload: payload, size: total }
    });
}

fn incomplete() -> DecodeResult {
    return DecodeResult {
        kind: Decoded.Incomplete,
        frame: Frame { fin: false, op: Op.Text, payload: b"", size: 0 }
    };
}

// A server frame: never masked, shortest length form.
pub fn encode(op: Op, payload: bytes, fin: bool) -> bytes {
    let plen = len(payload);
    let out: bytes = b"";
    let b0: bytes = b".";
    let code = code_of(op);
    if fin {
        code = code | 128;
    }
    b0[0] = code;
    out = out + b0;
    let one: bytes = b".";
    if plen < 126 {
        one[0] = plen;
        out = out + one;
    } else if plen < 65536 {
        one[0] = 126;
        out = out + one;
        one[0] = (plen >> 8) & 255;
        out = out + one;
        one[0] = plen & 255;
        out = out + one;
    } else {
        one[0] = 127;
        out = out + one;
        let i = 7;
        while i >= 0 {
            one[0] = (plen >> (i * 8)) & 255;
            out = out + one;
            i = i - 1;
        }
    }
    return out + payload;
}

// A close frame's body: a 2-byte code, then an optional UTF-8 reason.
pub fn encode_close(code: int, reason: str) -> bytes {
    let body: bytes = b"..";
    body[0] = (code >> 8) & 255;
    body[1] = code & 255;
    return encode(Op.Close, body + to_bytes(reason), true);
}

pub gc struct CloseBody {
    code: int,
    reason: str,
}

// The close codes a peer may legitimately send. 1005 and 1006 are
// "no code" and "abnormal" -- they describe a local situation and must
// never appear on the wire; 1015 is TLS failure, likewise.
pub fn valid_close_code(code: int) -> bool {
    if code >= 3000 && code <= 4999 {
        return true;   // registered and private use
    }
    if code == 1000 || code == 1001 || code == 1002 || code == 1003 ||
       code == 1007 || code == 1008 || code == 1009 || code == 1010 ||
       code == 1011 {
        return true;
    }
    return false;
}

// An empty body is allowed and means 1000 with no reason.
pub fn decode_close(payload: bytes) -> result[CloseBody, str] {
    let n = len(payload);
    if n == 0 {
        return ok(CloseBody { code: 1000, reason: "" });
    }
    if n == 1 {
        return err("a close frame with a body needs a two-byte code");
    }
    let code = (payload[0] << 8) | payload[1];
    if !valid_close_code(code) {
        return err("close code " + to_str(code) + " is not allowed on the wire");
    }
    let reason: bytes = b"";
    if n > 2 {
        reason = payload[2..n];
        if !valid_utf8(reason) {
            return err("a close reason must be valid UTF-8");
        }
    }
    return ok(CloseBody { code: code, reason: to_str(reason) });
}

// A text message must be valid UTF-8, and a server that forwards
// invalid bytes as text is a server that corrupts every client that
// trusts it. Checked here, once, on the assembled message.
pub fn valid_utf8(b: bytes) -> bool {
    let n = len(b);
    let i = 0;
    while i < n {
        let c = b[i];
        if c < 128 {
            i = i + 1;
            continue;
        }
        let need = 0;
        let lo = 0;
        let hi = 0;
        if c >= 194 && c <= 223 {
            need = 1;
            lo = 128;
            hi = 191;
        } else if c >= 224 && c <= 239 {
            need = 2;
            lo = 128;
            hi = 191;
            if c == 224 { lo = 160; }
            if c == 237 { hi = 159; }   // no surrogates
        } else if c >= 240 && c <= 244 {
            need = 3;
            lo = 128;
            hi = 191;
            if c == 240 { lo = 144; }
            if c == 244 { hi = 143; }   // no more than U+10FFFF
        } else {
            return false;               // continuation byte or C0/C1
        }
        if i + need >= n + 0 && i + need > n - 1 {
            return false;
        }
        let j = 1;
        while j <= need {
            let cc = b[i + j];
            let min = 128;
            let max = 191;
            if j == 1 {
                min = lo;
                max = hi;
            }
            if cc < min || cc > max {
                return false;
            }
            j = j + 1;
        }
        i = i + need + 1;
    }
    return true;
}
