// Success responses.
//
// The mirror of errors.sl: handlers name a shape rather than building
// one, so every 200 in a service carries the same headers and every 201
// carries a Location. Bodies are already-encoded JSON strings -- zokor
// does not choose an encoder for you; `json.encode` from the standard
// library, or your own builder, produces the string.

import "http";

pub fn json_response(status: i32, body: str) -> http.Response {
    let h: map[str]str = {};
    h["content-type"] = "application/json; charset=utf-8";
    return http.Response {
        status: status,
        status_text: status_text(status),
        headers: h,
        body: to_bytes(body)
    };
}

// `ok` is a slang builtin (the result constructor), so the 200 helper
// is named for what it sends.
pub fn ok_json(body: str) -> http.Response {
    return json_response(200, body);
}

pub fn created(body: str, location: str) -> http.Response {
    let r = json_response(201, body);
    if len(location) > 0 {
        r.headers["location"] = location;
    }
    return r;
}

pub fn accepted(body: str) -> http.Response {
    return json_response(202, body);
}

pub fn no_content() -> http.Response {
    let h: map[str]str = {};
    h["content-length"] = "0";
    return http.Response {
        status: 204,
        status_text: "No Content",
        headers: h,
        body: to_bytes("")
    };
}

pub fn text(status: i32, body: str) -> http.Response {
    let h: map[str]str = {};
    h["content-type"] = "text/plain; charset=utf-8";
    return http.Response {
        status: status,
        status_text: status_text(status),
        headers: h,
        body: to_bytes(body)
    };
}

pub fn html(status: i32, body: str) -> http.Response {
    let h: map[str]str = {};
    h["content-type"] = "text/html; charset=utf-8";
    return http.Response {
        status: status,
        status_text: status_text(status),
        headers: h,
        body: to_bytes(body)
    };
}

pub fn bytes_of(status: i32, content_type: str, body: bytes) -> http.Response {
    let h: map[str]str = {};
    h["content-type"] = content_type;
    return http.Response {
        status: status,
        status_text: status_text(status),
        headers: h,
        body: body
    };
}

// 303 after a POST, 307/308 to preserve the method, 301/302 for the
// older shapes.
pub fn redirect(status: i32, location: str) -> http.Response {
    let h: map[str]str = {};
    h["location"] = location;
    h["content-length"] = "0";
    return http.Response {
        status: status,
        status_text: status_text(status),
        headers: h,
        body: to_bytes("")
    };
}

pub fn with_header(r: http.Response, name: str, value: str) -> http.Response {
    r.headers[lower_ascii(name)] = value;
    return r;
}

// Cache-Control in the two forms a service actually needs.
pub fn no_store(r: http.Response) -> http.Response {
    r.headers["cache-control"] = "no-store";
    return r;
}

pub fn cache_for(r: http.Response, seconds: int) -> http.Response {
    r.headers["cache-control"] = "public, max-age=" + to_str(seconds);
    return r;
}

fn lower_ascii(s: str) -> str {
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
