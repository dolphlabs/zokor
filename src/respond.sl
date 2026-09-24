// Success responses.
//
// The mirror of errors.sl: handlers name a shape rather than building
// one, so every 200 in a service carries the same headers and every 201
// carries a Location. Bodies are bytes on the wire: every constructor
// below takes the already-encoded payload as bytes and hands it to
// http's shaped bytes constructors, so a response arrives at http.write
// already shaped: no map, no per-header insert, no str->bytes copy,
// and the fast emit path never touches `extra`.

import "http";

pub fn json_response(status: i32, body: str) -> http.Response {
    return json_response_bytes(status, to_bytes(body));
}

// `json_response` with a BYTES body: same shape, no `to_bytes` copy.
// The hot path (a freshly rendered object) already holds bytes; this
// keeps them as bytes into `text_response_bytes`.
pub fn json_response_bytes(status: i32, body: bytes) -> http.Response {
    return http.text_response_bytes(status, status_text(status), "application/json; charset=utf-8", body);
}

// `ok` is a slang builtin (the result constructor), so the 200 helper
// is named for what it sends.
pub fn ok_json(body: str) -> http.Response {
    return json_response(200, body);
}

// `ok_json` with a BYTES body: the `render_bytes` path -- no str, no
// `to_bytes`, no copy between the renderer and the socket.
pub fn ok_json_bytes(body: bytes) -> http.Response {
    return json_response_bytes(200, body);
}

pub fn created(body: str, location: str) -> http.Response {
    let rc = json_response(201, body);
    if len(location) > 0 {
        rc.location = location;
    }
    return rc;
}

pub fn created_bytes(body: bytes, location: str) -> http.Response {
    let rb = json_response_bytes(201, body);
    if len(location) > 0 {
        rb.location = location;
    }
    return rb;
}

pub fn accepted(body: str) -> http.Response {
    return json_response(202, body);
}

// `accepted` with a BYTES body: same shape, no `to_bytes` copy.
pub fn accepted_bytes(body: bytes) -> http.Response {
    return json_response_bytes(202, body);
}

pub fn no_content() -> http.Response {
    return http.text_response(204, "No Content", "", "");
}

pub fn text(status: i32, body: str) -> http.Response {
    return text_bytes(status, to_bytes(body));
}

// `text` with a BYTES body: same shape, no `to_bytes` copy.
pub fn text_bytes(status: i32, body: bytes) -> http.Response {
    return http.text_response_bytes(status, status_text(status), "text/plain; charset=utf-8", body);
}

pub fn html(status: i32, body: str) -> http.Response {
    return html_bytes(status, to_bytes(body));
}

// `html` with a BYTES body: same shape, no `to_bytes` copy.
pub fn html_bytes(status: i32, body: bytes) -> http.Response {
    return http.text_response_bytes(status, status_text(status), "text/html; charset=utf-8", body);
}

pub fn bytes_of(status: i32, content_type: str, body: bytes) -> http.Response {
    return http.text_response_bytes(status, status_text(status), content_type, body);
}

// 303 after a POST, 307/308 to preserve the method, 301/302 for the
// older shapes.
pub fn redirect(status: i32, location: str) -> http.Response {
    let no_extra: [str] = [];
    return http.Response {
        status: status,
        status_text: status_text(status),
        content_type: "",
        location: location,
        extra: no_extra,
        body: to_bytes("")
    };
}

pub fn with_header(r: http.Response, name: str, value: str) -> http.Response {
    return http.with_header(r, name, value);
}

// Cache-Control in the two forms a service actually needs.
pub fn no_store(r: http.Response) -> http.Response {
    return http.with_header(r, "cache-control", "no-store");
}

pub fn cache_for(r: http.Response, seconds: int) -> http.Response {
    return http.with_header(r, "cache-control", "public, max-age=" + to_str(seconds));
}
