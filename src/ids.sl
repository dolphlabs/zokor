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
    let at = strings.find_field(headers, "x-request-id");
    if at < 0 {
        return new_request_id();
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
        return new_request_id();
    }
    let i = lo;
    while i < hi {
        let c = headers[i];
        let ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) ||
                 (c >= 97 && c <= 122) || c == 45 || c == 46 || c == 95;
        if !ok {
            return new_request_id();
        }
        i = i + 1;
    }
    return strings.from_bytes(headers, lo, hi);
}
