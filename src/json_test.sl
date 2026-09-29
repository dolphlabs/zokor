import "http";
import "json";
import "strings";

fn jparsed(s: str) -> Json {
    let r = parse(s);
    guard let j = r else let e = err_of(r) {
        panic("expected JSON from '" + s + "': " + e);
    }
    return j;
}

fn jbad(s: str) -> str {
    let r = parse(s);
    guard let _j = r else let e = err_of(r) {
        return e;
    }
    return "";
}

fn test_scalars_and_round_trip() {
    assert(jparsed("null").is_null());
    assert(jparsed("true").bool_or(false));
    assert(!jparsed("false").bool_or(true));
    assert(jparsed("42").int_or(0) == 42);
    assert(jparsed("-7").int_or(0) == -7);
    assert(jparsed("1.5").float_or(0.0) == 1.5);
    assert(jparsed("\"hi\"").str_or("") == "hi");
    assert(jparsed("  [1, 2 ,3 ] ").size() == 3);
    assert(jparsed("{\"a\":1}").render() == "{\"a\":1}");
    assert(jparsed("[1,\"two\",null,true]").render() == "[1,\"two\",null,true]");
}

// A 64-bit id must survive being read and written again, which it does
// not if numbers become floats.
fn test_large_numbers_keep_their_text() {
    let j = jparsed("{\"id\":9007199254740993}");
    assert(j.get("id").render() == "9007199254740993");
    assert(j.get("id").int_or(0) == 9007199254740993);
    assert(jparsed("1e3").render() == "1e3");
}

fn test_nested_access() {
    let j = jparsed("{\"user\":{\"name\":\"ada\",\"address\":{\"city\":\"London\"}},\"tags\":[\"x\",\"y\"]}");
    assert(j.get("user").get("name").str_or("") == "ada");
    assert(j.path("user.address.city").str_or("") == "London");
    assert(j.path("tags.1").str_or("") == "y");
    // a missing path is Null, not an error, all the way down
    assert(j.path("user.address.postcode").str_or("none") == "none");
    assert(j.path("nothing.at.all").is_null());
    assert(j.get("user").at(0).is_null());
}

fn test_absent_is_not_null() {
    let j = jparsed("{\"a\":null}");
    assert(j.has_key("a"));
    assert(j.get("a").is_null());
    assert(!j.has_key("b"));
    assert(j.get("b").is_null());
}

fn test_building_chains() {
    let out = jobj()
        .set_str("id", "org_7")
        .set_int("members", 3)
        .set_bool("active", true)
        .set("tags", jarr().add_str("a").add_str("b"))
        .set("owner", jobj().set_str("name", "ada"));
    assert(out.render() ==
        "{\"id\":\"org_7\",\"members\":3,\"active\":true,\"tags\":[\"a\",\"b\"],\"owner\":{\"name\":\"ada\"}}");
    // setting a key twice replaces it and keeps its position
    assert(jobj().set_int("a", 1).set_int("b", 2).set_int("a", 9).render() ==
           "{\"a\":9,\"b\":2}");
}

fn test_optional_fields_are_simply_absent() {
    let missing: opt[str] = none;
    let out = jobj().set_str("a", "x").set_opt_str("b", missing)
                    .set_opt_str("c", some("y"));
    assert(out.render() == "{\"a\":\"x\",\"c\":\"y\"}");
}

fn test_escaping_both_ways() {
    let j = jparsed("{\"k\":\"quote \\\" slash \\\\ newline \\n tab \\t\"}");
    assert(j.get("k").str_or("") == "quote \" slash \\ newline \n tab \t");
    assert(j.render() == "{\"k\":\"quote \\\" slash \\\\ newline \\n tab \\t\"}");
    let uni = jparsed("\"\\u00e9\\u0041\"");
    assert(uni.str_or("") == "éA");
    let pair = jparsed("\"\\ud834\\udd1e\"");
    assert(pair.str_or("") == "𝄞");
}

fn test_parse_refusals() {
    assert(jbad("") == "unexpected end of JSON at byte 0");
    assert(jbad("{oops}") == "expected a key in double quotes at byte 1");
    assert(jbad("{\"a\":1,}") == "expected a key in double quotes at byte 7");
    assert(jbad("[1,2") == "unterminated array at byte 4");
    assert(jbad("\"unterminated") == "unterminated string at byte 13");
    assert(jbad("01") == "a number must not have a leading zero at byte 2");
    assert(jparsed("0").int_or(-1) == 0);
    assert(jparsed("-0.5").float_or(0.0) == -0.5);
    assert(jbad("{\"a\" 1}") == "expected ':' after a key at byte 5");
    assert(jbad("tru") == "truncated 'true' at byte 0");
    assert(jbad("1.") == "a fraction needs a digit at byte 2");
    assert(jbad("\"\\ud834\"") == "a lone high surrogate at byte 7");
    let ctrl = "\"a";
    let one: bytes = b".";
    one[0] = 1;
    assert(jbad(ctrl + to_str(one) + "\"") ==
           "a control character must be escaped in a string at byte 2");
}

fn test_deep_nesting_is_bounded() {
    let deep = "";
    let i = 0;
    while i < 100 {
        deep = deep + "[";
        i = i + 1;
    }
    let e = jbad(deep);
    assert(len(e) > 0);
}

// slang has no struct tags, so this is how a camelCase API reaches
// snake_case fields and back.
fn test_key_rewriting() {
    let camel = "{\"userName\":\"ada\",\"homeAddress\":{\"postCode\":\"E1\"},\"items\":[{\"unitPrice\":2}]}";
    let snake = snake_keys(camel);
    assert(snake ==
        "{\"user_name\":\"ada\",\"home_address\":{\"post_code\":\"E1\"},\"items\":[{\"unit_price\":2}]}");
    assert(camel_keys(snake) == camel);
    assert(to_snake_case("userName") == "user_name");
    assert(to_snake_case("already_snake") == "already_snake");
    assert(to_camel("user_name") == "userName");
    assert(to_camel("id") == "id");
    // not JSON: left alone for the decoder to complain about
    assert(snake_keys("not json") == "not json");
}

fn json_req(body: str, ct: str) -> http.Request {
    let h: map[str]str = {};
    if len(ct) > 0 {
        h["content-type"] = ct;
    }
    let rr = http.request("POST", "/x", "HTTP/1.1", h, to_bytes(body));
    guard let req = rr else {
        panic("json_req: bad test request");
    }
    return req;
}

fn test_parse_body_and_its_failures() {
    let r = parse_body("application/json", to_bytes("{\"a\":1}"));
    guard let j = r else {
        panic("expected a body");
    }
    assert(j.get("a").int_or(0) == 1);

    let vnd = parse_body("application/vnd.api+json; charset=utf-8",
                         to_bytes("{}"));
    guard let _v = vnd else {
        panic("a +json media type is JSON");
    }

    let wrong = parse_body("text/plain", to_bytes("{}"));
    guard let _w = wrong else let e = err_of(wrong) {
        assert(e.code == "unsupported_media_type");
        let empty = parse_body("application/json", b"");
        guard let _e2 = empty else let e2 = err_of(empty) {
            assert(e2.code == "bad_request");
            assert(e2.detail == "the request body is empty");
            let broken = parse_body("application/json", to_bytes("{"));
            guard let _e3 = broken else let e3 = err_of(broken) {
                assert(e3.code == "malformed_json");
                return;
            }
            panic("a broken body was accepted");
        }
        panic("an empty body was accepted");
    }
    panic("text/plain was accepted as JSON");
}

fn test_ctx_json_body() {
    let c = Ctx[int] {
        state: 1,
        req: json_req("{\"name\":\"ada\"}", "application/json"),
        params: none,
        param1_name: "",
        param1_value: "",
        route: "/x",
        request_id: "r1",
        locals: none,
        errors: new_registry()
    };
    let r = c.json_body();
    guard let j = r else {
        panic("expected a JSON body");
    }
    assert(j.get("name").str_or("") == "ada");
}

// slang's own decoder names the field; this puts that name in the same
// envelope everything else uses.
fn test_decode_failure_becomes_a_field_error() {
    let reg = new_registry();
    let resp = decode_failed(reg, "field 'addr': field 'city': expected a string, got a number", "r1");
    assert(resp.status == 422);
    assert(to_str(resp.body) ==
        "{\"error\":{\"code\":\"validation_failed\",\"message\":\"some fields are not valid\",\"status\":422,\"request_id\":\"r1\",\"fields\":[{\"field\":\"addr.city\",\"reason\":\"expected a string, got a number\"}]}}");

    let missing = decode_failed(reg, "missing required field 'age'", "");
    assert(to_str(missing.body) ==
        "{\"error\":{\"code\":\"validation_failed\",\"message\":\"some fields are not valid\",\"status\":422,\"fields\":[{\"field\":\"age\",\"reason\":\"is required\"}]}}");

    let syntax = decode_failed(reg, "expected string key in object (at byte 1)", "");
    assert(syntax.status == 400);
}

fn test_checker_collects_every_problem() {
    let body = jparsed("{\"name\":\"\",\"email\":\"nope\",\"age\":200,\"role\":\"wizard\",\"tags\":[1]}");
    let v = checker();
    v.req_str(body, "name", 1, 80);
    v.req_email(body, "email");
    v.req_int(body, "age", 0, 150);
    v.req_one_of(body, "role", ["admin", "member"]);
    v.req_strs(body, "tags", 10);
    v.req_str(body, "missing", 1, 10);
    assert(v.failed());
    assert(len(v.fields) == 6);
    assert(v.fields[0].field == "name");
    assert(v.fields[0].reason == "must not be empty");
    assert(v.fields[1].field == "email");
    assert(v.fields[2].reason == "must be between 0 and 150");
    assert(v.fields[3].reason == "must be one of: admin, member");
    assert(v.fields[4].field == "tags.0");
    assert(v.fields[5].reason == "is required");
}

fn test_checker_passes_good_input() {
    let body = jparsed("{\"name\":\"Ada\",\"email\":\"ada@example.com\",\"age\":36,\"role\":\"admin\",\"tags\":[\"x\"],\"site\":\"https://example.com\"}");
    let v = checker();
    assert(v.req_str(body, "name", 1, 80) == "Ada");
    assert(v.req_email(body, "email") == "ada@example.com");
    assert(v.req_int(body, "age", 0, 150) == 36);
    assert(v.req_one_of(body, "role", ["admin", "member"]) == "admin");
    assert(len(v.req_strs(body, "tags", 10)) == 1);
    assert(v.req_url(body, "site") == "https://example.com");
    assert(v.opt_str(body, "nickname", 20, "none") == "none");
    assert(v.opt_int(body, "score", 0, 10, 5) == 5);
    assert(!v.failed());
}

fn test_checker_types_and_nesting() {
    let body = jparsed("{\"name\":7,\"flags\":true,\"address\":{\"city\":\"\"}}");
    let v = checker();
    v.req_str(body, "name", 1, 10);
    v.req_strs(body, "flags", 5);
    let addr = v.req_obj(body, "address");
    let inner = checker();
    inner.req_str(addr, "city", 1, 40);
    v.under("address", inner);
    assert(len(v.fields) == 3);
    assert(v.fields[0].reason == "must be a string");
    assert(v.fields[1].reason == "must be an array");
    assert(v.fields[2].field == "address.city");
    assert(v.fields[2].reason == "must not be empty");
}

fn test_render_bytes_matches_render() {
    let j = jobj().set_str("id", "42").set_str("name", "user 42");
    assert(to_str(j.render_bytes()) == j.render());
    let n = jobj().set_int("a", 1).set_bool("b", true).set("c", jnull());
    assert(to_str(n.render_bytes()) == n.render());
    let q = jobj().set_str("msg", "quote \" backslash \\ newline \n tab \t");
    assert(to_str(q.render_bytes()) == q.render());
    let arr = jarr().add_str("x").add_int(7);
    assert(to_str(arr.render_bytes()) == arr.render());
}

fn test_ok_json_bytes_matches_ok_json() {
    let body = jobj().set_str("id", "42").render_bytes();
    let a = ok_json_bytes(body);
    let b = ok_json(to_str(body));
    assert(a.status == b.status);
    assert(a.content_type == b.content_type);
    assert(a.body == b.body);
    assert(http.serialize(a) == http.serialize(b));
}

fn test_fixed_shape_helpers_match_the_json_builder() {
    let id = "42";
    assert(to_str(user_json(id)) == jobj().set_str("id", id).set_str("name", "user " + id).render());
    assert(to_str(user_json_bytes(to_bytes(id))) == jobj().set_str("id", id).set_str("name", "user " + id).render());
    assert(to_str(message_json("hi")) == jobj().set_str("message", "hi").render());
    let tricky = "q\" b\\ n\n t\t";
    assert(to_str(user_json(tricky)) == jobj().set_str("id", tricky).set_str("name", "user " + tricky).render());
    assert(to_str(user_json_bytes(to_bytes(tricky))) == jobj().set_str("id", tricky).set_str("name", "user " + tricky).render());
    assert(to_str(message_json(tricky)) == jobj().set_str("message", tricky).render());
}

fn test_checker_renders_into_the_standard_envelope() {
    let reg = new_registry();
    let body = jparsed("{}");
    let v = checker();
    v.req_str(body, "name", 1, 10);
    let resp = respond_fields(reg, "validation_failed", v.fields, "r9");
    assert(resp.status == 422);
    assert(to_str(resp.body) ==
        "{\"error\":{\"code\":\"validation_failed\",\"message\":\"some fields are not valid\",\"status\":422,\"request_id\":\"r9\",\"fields\":[{\"field\":\"name\",\"reason\":\"is required\"}]}}");
}

// ---- dto's fast path: snake_keys_is_identity -------------------------

// Every document the fast path takes must be one snake_keys leaves alone.
fn identity_docs() -> [str] {
    return [
        "{\"message\":\"hi\"}",
        "  {\"a\" : {\"b\":[1, 2, {\"c\":null}]}, \"d\":true}  ",
        "{\"t\":\"line\\nbreak \\\"q\\\" \\\\ \\/ \\b\\f\\r\\t\"}",
        "{\"n\":-0.5e+3,\"m\":0,\"k\":12E-2,\"z\":-0}",
        "[1,\"x\",false,[],{}]",
        "\"just a string\"",
        "{}",
        "[]",
        "{\"a\":{\"a\":1},\"b\":{\"a\":2}}",
        "{\"été\":1}",
        "{\"snake_case_key\":[{\"x\":1},{\"x\":2}]}",
        "{\"id\":9007199254740993}"
    ];
}

// ...and every document it refuses must still go through snake_keys.
fn rewrite_docs() -> [str] {
    return [
        "{\"userId\":1}",
        "{\"a\\u0041\":1}",
        "{\"a\\\\\":1}",
        "{\"a\":\"\\u00e9\"}",
        "{\"a\":1,\"a\":2}",
        "{\"x\":{\"k\":1,\"k\":2}}",
        "[1,2,]",
        "{\"a\":1,}",
        "{a:1}",
        "{'a':1}",
        "01",
        "+1",
        ".5",
        "1.",
        "1e",
        "{} x",
        "1 2",
        "{\"a\":1",
        "[",
        "",
        "   ",
        "{\"a\":\"tab\there\"}",
        "{\"a\":tru}",
        "nul",
        "{\"a\"1}",
        "[1 2]"
    ];
}

fn nested(depth: int) -> str {
    let s = "";
    let i = 0;
    while i < depth {
        s = s + "[";
        i = i + 1;
    }
    i = 0;
    while i < depth {
        s = s + "]";
        i = i + 1;
    }
    return s;
}

fn test_identity_fast_path_accepts_only_no_op_documents() {
    for d in identity_docs() {
        if !snake_keys_is_identity(to_bytes(d)) {
            panic("fast path refused a no-op document: " + d);
        }
        // and snake_keys really is a no-op on it
        assert(jparsed(snake_keys(d)).render() == jparsed(d).render());
    }
    assert(snake_keys_is_identity(to_bytes(nested(max_depth()))));
}

fn test_identity_fast_path_refuses_anything_it_cannot_prove() {
    for d in rewrite_docs() {
        if snake_keys_is_identity(to_bytes(d)) {
            panic("fast path took a document it cannot prove: " + d);
        }
    }
    assert(!snake_keys_is_identity(to_bytes(nested(max_depth() + 1))));
    // a NUL byte: to_str would end the text there, so the bytes and the
    // text json.decode sees would differ
    assert(!snake_keys_is_identity(b"{\"a\":1}\x00"));
    assert(!snake_keys_is_identity(b"{\"a\":\"x\x00y\"}"));
}

gc struct DtoProbe {
    a: opt[int],
    message: opt[str],
    t: opt[str],
    k: opt[int],
    user_id: opt[int],
}

fn decode_outcome(text: str) -> str {
    let r: result[DtoProbe, str] = json.decode(text);
    guard let v = r else let e = err_of(r) {
        return "err: " + e;
    }
    return "ok: " + json.encode(v);
}

// The contract that matters: whichever way dto_text goes, json.decode
// sees a document that decodes the same -- values and errors alike.
fn test_dto_text_decodes_exactly_as_snake_keys_did() {
    let docs = identity_docs();
    for d in rewrite_docs() {
        push(docs, d);
    }
    push(docs, "{\"a\":\"not an int\"}");
    push(docs, "{\"a\":1,\"message\":\"m\",\"k\":2}");
    for d in docs {
        let fast = decode_outcome(dto_text(to_bytes(d)));
        let slow = decode_outcome(snake_keys(d));
        if fast != slow {
            panic("dto_text changed the result for " + d + ": " + fast +
                  " vs " + slow);
        }
    }
}

// ---- user_json / message_json: encoded == hand-built, byte for byte ---

fn one_byte_str(c: int) -> str {
    let b = strings.bytes_zero(1);
    b[0] = c;
    return to_str(b);
}

fn json_helper_inputs() -> [str] {
    let xs: [str] = ["42", "", "user", "a\"b", "back\\slash", "\\b", "\\f",
                     "tab\tnew\nline\rret", "été ✓ 日本", "/api/v1", "</script>"];
    let c = 1;
    while c < 128 {
        push(xs, one_byte_str(c));
        push(xs, "x" + one_byte_str(c) + "y");
        c = c + 1;
    }
    return xs;
}

fn test_user_json_is_byte_identical_to_the_hand_built_form() {
    for s in json_helper_inputs() {
        let want = user_json_built(to_bytes(s));
        if user_json(s) != want {
            panic("user_json differs for input of length " + to_str(len(s)) +
                  ": " + to_str(user_json(s)) + " vs " + to_str(want));
        }
        if user_json_bytes(to_bytes(s)) != want {
            panic("user_json_bytes differs for " + to_str(want));
        }
    }
}

fn test_message_json_is_byte_identical_to_the_hand_built_form() {
    for s in json_helper_inputs() {
        let want = message_json_built(s);
        if message_json(s) != want {
            panic("message_json differs: " + to_str(message_json(s)) + " vs " +
                  to_str(want));
        }
    }
}
