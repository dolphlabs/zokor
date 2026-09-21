// Failure, as one shape.
//
// An application that writes its own JSON per handler ends up with a
// `{"error": "..."}` here, a `{"message": "..."}` there, a 400 in one
// place and a 500 in another for the same cause -- and a client that
// has to special-case each. So: every failure names a CODE, every code
// is registered once with its status and its wording, and every
// response is rendered by the same function.
//
//     {"error":{"code":"org.not_found","message":"no such organisation",
//               "status":404,"request_id":"01H..."}}
//
// A validation failure carries the offending fields in the same
// envelope, because "which field" is the first thing a client asks:
//
//     {"error":{"code":"validation_failed","message":"...","status":422,
//               "fields":[{"field":"email","reason":"must be an email"}]}}

import "http";

pub gc struct Code {
    name: str,
    status: i32,
    message: str,
}

pub gc struct FieldError {
    field: str,
    reason: str,
}

pub gc struct Registry {
    codes: map[str]Code,
}

// Every HTTP failure status, under the name a handler will reach for.
// An application registers its own domain codes on top
// ("org.not_found", "billing.card_declined"); registering a name that
// exists replaces it, so the wording of a built-in can be changed
// without a second registry.
pub fn new_registry() -> Registry {
    let m: map[str]Code = {};
    let r = Registry { codes: m };

    // 4xx -- the caller can do something about it
    register(r, "bad_request", 400, "the request could not be understood");
    register(r, "malformed_json", 400, "the request body is not valid JSON");
    register(r, "unauthorized", 401, "authentication is required");
    register(r, "invalid_credentials", 401, "those credentials are not valid");
    register(r, "token_expired", 401, "that token has expired");
    register(r, "payment_required", 402, "payment is required to continue");
    register(r, "forbidden", 403, "not allowed");
    register(r, "not_found", 404, "no such resource");
    register(r, "method_not_allowed", 405, "that method is not allowed here");
    register(r, "not_acceptable", 406, "no representation matches the Accept header");
    register(r, "proxy_auth_required", 407, "proxy authentication is required");
    register(r, "request_timeout", 408, "the request took too long to arrive");
    register(r, "conflict", 409, "the resource is in a conflicting state");
    register(r, "already_exists", 409, "that resource already exists");
    register(r, "gone", 410, "that resource is no longer available");
    register(r, "length_required", 411, "a Content-Length header is required");
    register(r, "precondition_failed", 412, "a precondition in the request failed");
    register(r, "payload_too_large", 413, "the request body is too large");
    register(r, "uri_too_long", 414, "the request target is too long");
    register(r, "unsupported_media_type", 415, "that content type is not supported");
    register(r, "range_not_satisfiable", 416, "the requested range is not available");
    register(r, "expectation_failed", 417, "the Expect header cannot be met");
    register(r, "misdirected_request", 421, "this server cannot answer for that authority");
    register(r, "unprocessable", 422, "the request was well-formed but invalid");
    register(r, "validation_failed", 422, "some fields are not valid");
    register(r, "locked", 423, "the resource is locked");
    register(r, "failed_dependency", 424, "a previous step in the request failed");
    register(r, "too_early", 425, "replay of an early request is refused");
    register(r, "upgrade_required", 426, "the protocol must be upgraded");
    register(r, "precondition_required", 428, "this request must be conditional");
    register(r, "rate_limited", 429, "too many requests");
    register(r, "headers_too_large", 431, "the request headers are too large");
    register(r, "unavailable_for_legal_reasons", 451, "unavailable for legal reasons");

    // 5xx -- the caller cannot
    register(r, "internal", 500, "something went wrong on our side");
    register(r, "not_implemented", 501, "that is not implemented");
    register(r, "bad_gateway", 502, "an upstream service answered badly");
    register(r, "unavailable", 503, "the service is temporarily unavailable");
    register(r, "gateway_timeout", 504, "an upstream service took too long");
    register(r, "http_version_not_supported", 505, "that HTTP version is not supported");
    register(r, "insufficient_storage", 507, "there is no room to store the result");
    register(r, "loop_detected", 508, "the request loops");
    register(r, "network_auth_required", 511, "network authentication is required");
    return r;
}

pub fn register(r: Registry, name: str, status: i32, message: str) -> int {
    r.codes[name] = Code { name: name, status: status, message: message };
    return len(r.codes);
}

pub fn lookup(r: Registry, name: str) -> opt[Code] {
    if has(r.codes, name) {
        return some(r.codes[name]);
    }
    return none;
}

// A code nobody registered is a bug in the service, not a client
// error: it answers 500 and says which name was missing, so the
// mistake shows up in the logs instead of hiding behind a generic
// message.
pub fn status_of(r: Registry, name: str) -> i32 {
    guard let c = lookup(r, name) else {
        return 500;
    }
    return c.status;
}

pub fn message_of(r: Registry, name: str) -> str {
    guard let c = lookup(r, name) else {
        return "unregistered error code '" + name + "'";
    }
    return c.message;
}

pub fn code_names(r: Registry) -> [str] {
    let out: [str] = [];
    for k, c in r.codes {
        let _d = c;
        push(out, k);
    }
    return out;
}

// ---------------------------------------------------------------- //
// Rendering                                                          //
// ---------------------------------------------------------------- //

// The registered wording.
pub fn respond(r: Registry, code: str, request_id: str) -> http.Response {
    let fields: [FieldError] = [];
    return render(r, code, message_of(r, code), request_id, fields);
}

// The registered code, with wording for this one occurrence
// ("no such organisation 'acme'"). The code still decides the status,
// so a detail cannot quietly change what a client sees.
pub fn respond_with(r: Registry, code: str, detail: str,
                    request_id: str) -> http.Response {
    let fields: [FieldError] = [];
    return render(r, code, detail, request_id, fields);
}

pub fn respond_fields(r: Registry, code: str, fields: [FieldError],
                      request_id: str) -> http.Response {
    return render(r, code, message_of(r, code), request_id, fields);
}

pub fn field(name: str, reason: str) -> FieldError {
    return FieldError { field: name, reason: reason };
}

fn render(r: Registry, code: str, message: str, request_id: str,
          fields: [FieldError]) -> http.Response {
    let status = status_of(r, code);
    let body = "{\"error\":{\"code\":" + quote(code) +
               ",\"message\":" + quote(message) +
               ",\"status\":" + to_str(status);
    if len(request_id) > 0 {
        body = body + ",\"request_id\":" + quote(request_id);
    }
    if len(fields) > 0 {
        body = body + ",\"fields\":[";
        let i = 0;
        while i < len(fields) {
            if i > 0 {
                body = body + ",";
            }
            body = body + "{\"field\":" + quote(fields[i].field) +
                   ",\"reason\":" + quote(fields[i].reason) + "}";
            i = i + 1;
        }
        body = body + "]";
    }
    body = body + "}}";

    let headers: map[str]str = {};
    headers["content-type"] = "application/json; charset=utf-8";
    if len(request_id) > 0 {
        headers["x-request-id"] = request_id;
    }
    return http.Response {
        status: status,
        status_text: status_text(status),
        headers: headers,
        body: to_bytes(body)
    };
}

// A JSON string, escaped. Everything that reaches here can contain a
// value someone else chose -- a path, a header, a field name -- so it
// is escaped rather than trusted.
pub fn quote(s: str) -> str {
    let b = to_bytes(s);
    let out = "\"";
    let i = 0;
    while i < len(b) {
        let c = b[i];
        if c == 34 {
            out = out + "\\\"";
        } else if c == 92 {
            out = out + "\\\\";
        } else if c == 10 {
            out = out + "\\n";
        } else if c == 13 {
            out = out + "\\r";
        } else if c == 9 {
            out = out + "\\t";
        } else if c < 32 {
            out = out + "\\u00" + hex2(c);
        } else {
            out = out + to_str(b[i..i + 1]);
        }
        i = i + 1;
    }
    return out + "\"";
}

fn hex2(c: int) -> str {
    let digits = "0123456789abcdef";
    let d = to_bytes(digits);
    let hi = d[(c / 16) % 16];
    let lo = d[c % 16];
    let out: bytes = b"..";
    out[0] = hi;
    out[1] = lo;
    return to_str(out);
}

pub fn status_text(status: i32) -> str {
    if status == 200 { return "OK"; }
    if status == 201 { return "Created"; }
    if status == 202 { return "Accepted"; }
    if status == 204 { return "No Content"; }
    if status == 301 { return "Moved Permanently"; }
    if status == 302 { return "Found"; }
    if status == 303 { return "See Other"; }
    if status == 304 { return "Not Modified"; }
    if status == 307 { return "Temporary Redirect"; }
    if status == 308 { return "Permanent Redirect"; }
    if status == 400 { return "Bad Request"; }
    if status == 401 { return "Unauthorized"; }
    if status == 402 { return "Payment Required"; }
    if status == 403 { return "Forbidden"; }
    if status == 404 { return "Not Found"; }
    if status == 405 { return "Method Not Allowed"; }
    if status == 406 { return "Not Acceptable"; }
    if status == 407 { return "Proxy Authentication Required"; }
    if status == 408 { return "Request Timeout"; }
    if status == 409 { return "Conflict"; }
    if status == 410 { return "Gone"; }
    if status == 411 { return "Length Required"; }
    if status == 412 { return "Precondition Failed"; }
    if status == 413 { return "Content Too Large"; }
    if status == 414 { return "URI Too Long"; }
    if status == 415 { return "Unsupported Media Type"; }
    if status == 416 { return "Range Not Satisfiable"; }
    if status == 417 { return "Expectation Failed"; }
    if status == 421 { return "Misdirected Request"; }
    if status == 422 { return "Unprocessable Content"; }
    if status == 423 { return "Locked"; }
    if status == 424 { return "Failed Dependency"; }
    if status == 425 { return "Too Early"; }
    if status == 426 { return "Upgrade Required"; }
    if status == 428 { return "Precondition Required"; }
    if status == 429 { return "Too Many Requests"; }
    if status == 431 { return "Request Header Fields Too Large"; }
    if status == 451 { return "Unavailable For Legal Reasons"; }
    if status == 500 { return "Internal Server Error"; }
    if status == 501 { return "Not Implemented"; }
    if status == 502 { return "Bad Gateway"; }
    if status == 503 { return "Service Unavailable"; }
    if status == 504 { return "Gateway Timeout"; }
    if status == 505 { return "HTTP Version Not Supported"; }
    if status == 507 { return "Insufficient Storage"; }
    if status == 508 { return "Loop Detected"; }
    if status == 511 { return "Network Authentication Required"; }
    if status >= 500 { return "Server Error"; }
    if status >= 400 { return "Client Error"; }
    if status >= 300 { return "Redirect"; }
    return "OK";
}
