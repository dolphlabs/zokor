import "http";
import "strings";

gc struct SzState {
    hits: int,
}

fn sz_echo(c: Ctx[SzState]) -> http.Response {
    c.state.hits = c.state.hits + 1;
    return text(200, c.body_str() + "|" + c.query("q") + "|" + c.query("$where"));
}

fn sz_refuse(c: Ctx[SzState]) -> opt[http.Response] {
    // A `before` that would read the body: the guard runs first.
    return none;
}

fn sz_router(mode: SanitizeMode) -> Router[SzState] {
    let r = new_router(SzState { hits: 0 });
    r.before(sz_refuse);
    r.post("/login", sz_echo);
    r.get("/find", sz_echo);
    r.mongo_sanitize(mode);
    return r;
}

fn sz_post(r: Router[SzState], body: str) -> http.Response {
    return r.serve(request(Method.POST, "/login").json_body(body).build());
}

fn sz_parsed(text: str) -> Json {
    let r = parse(text);
    guard let j = r else let e = err_of(r) { panic(e); }
    return j;
}

fn test_operator_keys_are_found_at_any_depth() {
    assert(find_operator_key(sz_parsed("{\"user\":\"ada\",\"password\":{\"$ne\":\"\"}}")) == "password.$ne");
    assert(find_operator_key(sz_parsed("{\"a\":[1,{\"b.c\":2}]}")) == "a[1].b.c");
    assert(find_operator_key(sz_parsed("[{\"$where\":\"1\"}]")) == "[0].$where");
    assert(find_operator_key(sz_parsed("{\"price\":\"$5 off\",\"note\":\"a.b\"}")) == "",
           "values are never touched");
}

fn test_strip_removes_only_operator_keys() {
    let j = sz_parsed("{\"user\":\"ada\",\"password\":{\"$ne\":\"\"},\"x.y\":1,\"keep\":[{\"$gt\":1,\"n\":2}]}");
    assert(strip_operator_keys(j) == 3);
    assert(j.render() == "{\"user\":\"ada\",\"password\":{},\"keep\":[{\"n\":2}]}", j.render());
}

fn test_reject_mode_answers_400_before_any_handler() {
    let r = sz_router(SanitizeMode.REJECT);
    let resp = sz_post(r, "{\"user\":\"ada\",\"password\":{\"$ne\":\"\"}}");
    assert(resp_status(resp) == 400);
    assert(resp_error_code(resp) == "bad_request");
    assert(strings.contains(resp_text(resp), "password.$ne"), resp_text(resp));
    assert(r.state.hits == 0, "the handler must not run");
    let fine = sz_post(r, "{\"user\":\"ada\",\"password\":\"hunter2\"}");
    assert(resp_status(fine) == 200 && r.state.hits == 1);
}

fn test_reject_mode_checks_query_names_decoded() {
    let r = sz_router(SanitizeMode.REJECT);
    assert(resp_status(r.serve(get_request("/find?q=1&%24where=1").build())) == 400,
           "an encoded $ is still a $");
    assert(resp_status(r.serve(get_request("/find?user.name=x").build())) == 400);
    assert(resp_status(r.serve(get_request("/find?q=$5").build())) == 200, "values are fine");
}

fn test_strip_mode_carries_on_without_the_keys() {
    let r = sz_router(SanitizeMode.STRIP);
    let resp = sz_post(r, "{\"user\":\"ada\",\"password\":{\"$ne\":\"\"}}");
    assert(resp_status(resp) == 200);
    assert(resp_text(resp) == "{\"user\":\"ada\",\"password\":{}}||", resp_text(resp));
    let q = r.serve(get_request("/find?q=1&%24where=sleep(1)").build());
    assert(resp_text(q) == "|1|", resp_text(q));
    let only = r.serve(get_request("/find?$where=1").build());
    assert(resp_text(only) == "||", resp_text(only));
}

fn test_off_by_default_and_non_json_bodies_are_left_alone() {
    let r = new_router(SzState { hits: 0 });
    r.post("/login", sz_echo);
    assert(resp_status(sz_post(r, "{\"password\":{\"$ne\":\"\"}}")) == 200, "off unless asked");
    let g = sz_router(SanitizeMode.REJECT);
    let form = g.serve(request(Method.POST, "/login").content_type("text/plain")
        .body_str("{\"$ne\":1}").build());
    assert(resp_status(form) == 200, "not JSON: not this guard's to judge");
    let broken = sz_post(g, "{not json");
    assert(resp_status(broken) == 200, "malformed JSON is the handler's to refuse");
}

fn test_sanitize_from_config() {
    assert(sanitize_from(cfg_of("")) == SanitizeMode.OFF);
    assert(sanitize_from(cfg_of("MONGO_SANITIZE=reject\n")) == SanitizeMode.REJECT);
    assert(sanitize_from(cfg_of("MONGO_SANITIZE=Strip\n")) == SanitizeMode.STRIP);
    let c = cfg_of("MONGO_SANITIZE=sometimes\n");
    assert(sanitize_from(c) == SanitizeMode.OFF);
    guard let _ok = check(c) else { return; }
    panic("a bad MONGO_SANITIZE was not reported");
}
