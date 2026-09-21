import "http";

fn body_of(r: http.Response) -> str {
    return to_str(r.body);
}

fn test_builtin_codes_cover_the_http_failures() {
    let reg = new_registry();
    assert(status_of(reg, "bad_request") == 400);
    assert(status_of(reg, "unauthorized") == 401);
    assert(status_of(reg, "payment_required") == 402);
    assert(status_of(reg, "forbidden") == 403);
    assert(status_of(reg, "not_found") == 404);
    assert(status_of(reg, "method_not_allowed") == 405);
    assert(status_of(reg, "conflict") == 409);
    assert(status_of(reg, "gone") == 410);
    assert(status_of(reg, "payload_too_large") == 413);
    assert(status_of(reg, "unsupported_media_type") == 415);
    assert(status_of(reg, "unprocessable") == 422);
    assert(status_of(reg, "validation_failed") == 422);
    assert(status_of(reg, "rate_limited") == 429);
    assert(status_of(reg, "internal") == 500);
    assert(status_of(reg, "not_implemented") == 501);
    assert(status_of(reg, "bad_gateway") == 502);
    assert(status_of(reg, "unavailable") == 503);
    assert(status_of(reg, "gateway_timeout") == 504);
    assert(len(code_names(reg)) > 35);
}

fn test_envelope_shape() {
    let reg = new_registry();
    let r = respond(reg, "not_found", "req-1");
    assert(r.status == 404);
    assert(r.status_text == "Not Found");
    assert(r.headers["content-type"] == "application/json; charset=utf-8");
    assert(r.headers["x-request-id"] == "req-1");
    assert(body_of(r) ==
        "{\"error\":{\"code\":\"not_found\",\"message\":\"no such resource\",\"status\":404,\"request_id\":\"req-1\"}}");
}

fn test_envelope_without_request_id() {
    let reg = new_registry();
    let r = respond(reg, "forbidden", "");
    assert(!has(r.headers, "x-request-id"));
    assert(body_of(r) ==
        "{\"error\":{\"code\":\"forbidden\",\"message\":\"not allowed\",\"status\":403}}");
}

fn test_application_codes_and_overrides() {
    let reg = new_registry();
    register(reg, "org.not_found", 404, "no such organisation");
    assert(status_of(reg, "org.not_found") == 404);
    let r = respond(reg, "org.not_found", "");
    assert(body_of(r) ==
        "{\"error\":{\"code\":\"org.not_found\",\"message\":\"no such organisation\",\"status\":404}}");
    register(reg, "not_found", 404, "nope");
    assert(message_of(reg, "not_found") == "nope");
}

fn test_detail_does_not_change_the_status() {
    let reg = new_registry();
    let r = respond_with(reg, "conflict", "project 'acme' already exists", "");
    assert(r.status == 409);
    assert(body_of(r) ==
        "{\"error\":{\"code\":\"conflict\",\"message\":\"project 'acme' already exists\",\"status\":409}}");
}

fn test_field_errors_ride_in_the_same_envelope() {
    let reg = new_registry();
    let fields = [field("email", "must be an email address"),
                  field("age", "must be a whole number")];
    let r = respond_fields(reg, "validation_failed", fields, "req-9");
    assert(r.status == 422);
    assert(body_of(r) ==
        "{\"error\":{\"code\":\"validation_failed\",\"message\":\"some fields are not valid\",\"status\":422,\"request_id\":\"req-9\",\"fields\":[{\"field\":\"email\",\"reason\":\"must be an email address\"},{\"field\":\"age\",\"reason\":\"must be a whole number\"}]}}");
}

fn test_unregistered_code_is_a_server_error_that_names_itself() {
    let reg = new_registry();
    let r = respond(reg, "typo.here", "");
    assert(r.status == 500);
    assert(body_of(r) ==
        "{\"error\":{\"code\":\"typo.here\",\"message\":\"unregistered error code 'typo.here'\",\"status\":500}}");
}

fn test_values_are_escaped() {
    let reg = new_registry();
    let r = respond_with(reg, "bad_request", "quote \" backslash \\ newline \n tab \t", "");
    assert(body_of(r) ==
        "{\"error\":{\"code\":\"bad_request\",\"message\":\"quote \\\" backslash \\\\ newline \\n tab \\t\",\"status\":400}}");
    let ctrl: bytes = b"a.b";
    ctrl[1] = 1;
    let f = [field(to_str(ctrl), "ctrl")];
    let r2 = respond_fields(reg, "validation_failed", f, "");
    assert(contains_bytes(body_of(r2), "\\u0001"));
}

fn contains_bytes(hay: str, needle: str) -> bool {
    let a = to_bytes(hay);
    let b = to_bytes(needle);
    let n = len(a);
    let m = len(b);
    if m == 0 || m > n {
        return false;
    }
    let i = 0;
    while i + m <= n {
        let j = 0;
        while j < m && a[i + j] == b[j] {
            j = j + 1;
        }
        if j == m {
            return true;
        }
        i = i + 1;
    }
    return false;
}
