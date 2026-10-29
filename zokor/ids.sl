// Identifiers.
//
// A request id is the thread a failure is followed by: it goes in the
// log line, in the error envelope, and in the response header, so a
// customer quoting one number gets you to the exact request. The serve
// loop gives every dynamic request one (request_id_for, below; see
// ServerConfig.request_ids).

import "crypto";
import "encoding";
import "strings";

// 128 bits of randomness, hex, prefixed so it is recognisable in a log
// that carries other people's ids too. Random rather than sequential:
// an id that counts tells a stranger how many requests you serve.
pub fn new_request_id() -> str {
    let r = crypto.rand(16);
    guard let b = r else {
        // the OS refusing randomness is fatal for a session id; for a
        // log correlation id it is better to carry on unlabelled
        return "req_unavailable";
    }
    return "req_" + encoding.hex_encode(b);
}

// A longer one, for a session or a socket.io sid, where a collision
// matters more than the length does.
pub fn new_session_id() -> str {
    let r = crypto.rand(24);
    guard let b = r else {
        return "";
    }
    return encoding.base64url_encode(b);
}

// The longest client-supplied request id that is reused as it is.
fn max_request_id_len() -> int {
    return 64;
}

// The id a request is answered and logged under: the client's own
// X-Request-Id when it is 1-64 characters of [A-Za-z0-9._-], so a
// proxy's or caller's id threads through your logs, and a fresh one
// otherwise. The value goes into a response header and into logs, so
// anything else -- a space, a control byte, CR or LF, a 10 KB value --
// is replaced, never cleaned up and kept. `headers` is a request's raw
// header block (http.WireFrame.headers); like http.header, a repeated
// field is read from its last line.
pub fn request_id_for(headers: bytes) -> str {
    let given = incoming_request_id(headers);
    if len(given) > 0 {
        return given;
    }
    return new_request_id();
}

// request_id_for, drawing a new id from `ids`: what the serve loop
// calls, once per dynamic request on a connection.
pub fn request_id_with(headers: bytes, ids: RequestIds) -> str {
    let given = incoming_request_id(headers);
    if len(given) > 0 {
        return given;
    }
    return ids.next();
}

// The client's own X-Request-Id when it is one zokor keeps, else "".
fn incoming_request_id(headers: bytes) -> str {
    let at = strings.find_field(headers, "x-request-id");
    if at < 0 {
        return "";
    }
    let n = len(headers);
    let hi = at;
    while hi < n && headers[hi] != 13 {
        hi = hi + 1;
    }
    let lo = at;
    while lo < hi && (headers[lo] == 32 || headers[lo] == 9) {
        lo = lo + 1;
    }
    while hi > lo && (headers[hi - 1] == 32 || headers[hi - 1] == 9) {
        hi = hi - 1;
    }
    if hi - lo < 1 || hi - lo > max_request_id_len() {
        return "";
    }
    let i = lo;
    while i < hi {
        let c = headers[i];
        let ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) ||
                 (c >= 97 && c <= 122) || c == 45 || c == 46 || c == 95;
        if !ok {
            return "";
        }
        i = i + 1;
    }
    return strings.from_bytes(headers, lo, hi);
}

// One connection's source of request ids: the same 128 random bits and
// `req_` + hex as new_request_id, but drawn 32 ids at a time. A
// crypto.rand call per request was a system call per request; an id
// rendered through hex_encode and `+` was three allocations where this
// is one. Not shared between connections, so it needs no lock.
pub gc struct RequestIds {
    pool: bytes,
    at: int,
    out: bytes,
}

pub fn request_ids() -> RequestIds {
    return RequestIds { pool: b"", at: 0, out: strings.bytes_zero(36) };
}

fn request_id_batch() -> int {
    return 32;
}

impl RequestIds {
    pub fn next(self: RequestIds) -> str {
        if self.at + 16 > len(self.pool) {
            let r = crypto.rand(16 * request_id_batch());
            guard let b = r else {
                return "req_unavailable";
            }
            self.pool = b;
            self.at = 0;
        }
        let hex = b"0123456789abcdef";
        let o = self.out;
        o[0] = 114;
        o[1] = 101;
        o[2] = 113;
        o[3] = 95;
        let i = 0;
        while i < 16 {
            let v = self.pool[self.at + i];
            o[4 + 2 * i] = hex[v >> 4];
            o[5 + 2 * i] = hex[v & 15];
            i = i + 1;
        }
        self.at = self.at + 16;
        return strings.from_bytes(o, 0, 36);
    }
}
