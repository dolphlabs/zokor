// Success responses.
//
// The mirror of errors.sl: handlers name a shape rather than building
// one, so every 200 in a service carries the same headers and every 201
// carries a Location. Bodies are already-encoded JSON strings -- zokor
// does not choose an encoder for you; `json.encode` from the standard
// library, or your own builder, produces the string.
//
// Every constructor below delegates to http's own shaped constructors,
// so a response arrives at http.write already shaped: no map, no
// per-header insert, and the fast emit path never touches `extra`.

import "http";

pub fn json_response(status: i32, body: str) -> http.Response {
    return http.text_response(status, status_text(status), "application/json; charset=utf-8", body);
}

// `ok` is a slang builtin (the result constructor), so the 200 helper
// is named for what it sends.
pub fn ok_json(body: str) -> http.Response {
    return json_response(200, body);
}

pub fn created(body: str, location: str) -> http.Response {
    let r = json_response(201, body);
    if len(location) > 0 {
        r.location = location;
    }
    return r;
}

pub fn accepted(body: str) -> http.Response {
    return json_response(202, body);
}

pub fn no_content() -> http.Response {
    return http.text_response(204, "No Content", "", "");
}

pub fn text(status: i32, body: str) -> http.Response {
    return http.text_response(status, status_text(status), "text/plain; charset=utf-8", body);
}

pub fn html(status: i32, body: str) -> http.Response {
    return http.text_response(status, status_text(status), "text/html; charset=utf-8", body);
}

pub fn bytes_of(status: i32, content_type: str, body: bytes) -> http.Response {
    let r = http.text_response(status, status_text(status), content_type, "");
    r.body = body;
    return r;
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
