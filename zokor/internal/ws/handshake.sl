// The opening handshake (RFC 6455 section 4).
//
// A client asks to upgrade with a GET carrying four things that matter:
// `Upgrade: websocket`, a `Connection` list containing `Upgrade`,
// `Sec-WebSocket-Version: 13`, and a `Sec-WebSocket-Key` of 16 random
// bytes in base64. The server proves it understood by answering 101
// with the SHA-1 of that key and a fixed GUID, base64-encoded.
//
// The GUID is not a secret and the hash is not security: it exists so
// that a cache or a proxy that does not understand WebSocket cannot
// accidentally produce a response that looks like a successful
// handshake.

import "crypto";
import "encoding";
import "http";

// The fixed GUID from RFC 6455 section 1.3. A function rather than a
// package-level `let`, so this file also compiles on its own.
pub fn guid() -> str {
    return "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
}

pub gc struct Request {
    key: str,
    protocols: [str],   // Sec-WebSocket-Protocol, in the client's order
    version: str,
}

// Reads the handshake out of an HTTP request, or says what is missing.
// The caller decides what to do about it; a failure here is a 400,
// except a wrong version which is a 426 with the version we speak.
pub fn read(req: http.Request) -> result[Request, str] {
    if req.method != "GET" {
        return err("a WebSocket handshake must be a GET");
    }
    let upgrade = lower(header(req, "upgrade"));
    if upgrade != "websocket" {
        return err("the Upgrade header must be 'websocket'");
    }
    if !token_present(lower(header(req, "connection")), "upgrade") {
        return err("the Connection header must include 'Upgrade'");
    }
    let version = trim(header(req, "sec-websocket-version"));
    if version != "13" {
        return err("unsupported WebSocket version '" + version + "'");
    }
    let key = trim(header(req, "sec-websocket-key"));
    if len(key) == 0 {
        return err("the Sec-WebSocket-Key header is required");
    }
    // 16 bytes, base64 -- 24 characters ending in "==". A key of any
    // other size is a client that will not understand the answer.
    if len(key) != 24 || !ends_with(key, "==") {
        return err("the Sec-WebSocket-Key header is not 16 base64 bytes");
    }
    return ok(Request {
        key: key,
        protocols: split_list(header(req, "sec-websocket-protocol")),
        version: version
    });
}

// base64(sha1(key + GUID)), the value that goes back as
// Sec-WebSocket-Accept.
pub fn accept_key(key: str) -> str {
    return encoding.base64_encode(crypto.sha1(to_bytes(key + guid())));
}

// The 101 that completes the handshake. `protocol` is the subprotocol
// the server picked, or "" to pick none -- it must be one the client
// offered, which `choose` checks.
pub fn response(key: str, protocol: str) -> http.Response {
    let r = http.text_response(101, "Switching Protocols", "", "");
    r = http.with_header(r, "upgrade", "websocket");
    r = http.with_header(r, "connection", "Upgrade");
    r = http.with_header(r, "sec-websocket-accept", accept_key(key));
    if len(protocol) > 0 {
        r = http.with_header(r, "sec-websocket-protocol", protocol);
    }
    return r;
}

// The first subprotocol the server supports, in the CLIENT's order of
// preference, or "" when there is no overlap. A server that answers
// with a protocol the client did not offer has failed the handshake.
pub fn choose(offered: [str], supported: [str]) -> str {
    let i = 0;
    while i < len(offered) {
        let j = 0;
        while j < len(supported) {
            if lower(offered[i]) == lower(supported[j]) {
                return supported[j];
            }
            j = j + 1;
        }
        i = i + 1;
    }
    return "";
}

fn header(req: http.Request, name: str) -> str {
    return http.header(req, name) ?? "";
}

// A comma-separated list, trimmed, empties dropped.
pub fn split_list(v: str) -> [str] {
    let out: [str] = [];
    let b = to_bytes(v);
    let n = len(b);
    let start = 0;
    let i = 0;
    while i <= n {
        if i == n || b[i] == 44 {
            let part = trim(to_str(b[start..i]));
            if len(part) > 0 {
                push(out, part);
            }
            start = i + 1;
        }
        i = i + 1;
    }
    return out;
}

// `Connection: keep-alive, Upgrade` -- the header is a list, and a
// client that sends more than one token is still asking to upgrade.
fn token_present(v: str, want: str) -> bool {
    let parts = split_list(v);
    let i = 0;
    while i < len(parts) {
        if parts[i] == want {
            return true;
        }
        i = i + 1;
    }
    return false;
}

fn lower(s: str) -> str {
    let b = to_bytes(s);
    let i = 0;
    while i < len(b) {
        if b[i] >= 65 && b[i] <= 90 {
            b[i] = b[i] + 32;
        }
        i = i + 1;
    }
    return to_str(b);
}

fn trim(s: str) -> str {
    let b = to_bytes(s);
    let n = len(b);
    let a = 0;
    while a < n && (b[a] == 32 || b[a] == 9) {
        a = a + 1;
    }
    let e = n;
    while e > a && (b[e - 1] == 32 || b[e - 1] == 9) {
        e = e - 1;
    }
    if a == 0 && e == n {
        return s;
    }
    return to_str(b[a..e]);
}

fn ends_with(s: str, p: str) -> bool {
    let a = to_bytes(s);
    let b = to_bytes(p);
    if len(b) > len(a) {
        return false;
    }
    let off = len(a) - len(b);
    let i = 0;
    while i < len(b) {
        if a[off + i] != b[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}
