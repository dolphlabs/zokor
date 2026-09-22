// Identifiers.
//
// A request id is the thread a failure is followed by: it goes in the
// log line, in the error envelope, and in the response header, so a
// customer quoting one number gets you to the exact request. The serve
// loop gives every request one; until it exists, a service calls this
// itself.

import "crypto";
import "encoding";

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
