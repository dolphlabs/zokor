import "http";
import "strings";

gc struct TestState {
    hits: int,
    name: str,
}

fn h_ok(c: Ctx[TestState]) -> http.Response {
    return ok_json("{\"route\":\"" + c.route + "\"}");
}

fn h_param(c: Ctx[TestState]) -> http.Response {
    return ok_json("{\"id\":\"" + c.param("id") + "\"}");
}

fn h_two(c: Ctx[TestState]) -> http.Response {
    return ok_json("{\"id\":\"" + c.param("id") + "\",\"key\":\"" +
                   c.param("key") + "\"}");
}

fn h_rest(c: Ctx[TestState]) -> http.Response {
    return ok_json("{\"rest\":\"" + c.param("rest") + "\"}");
}

fn h_query(c: Ctx[TestState]) -> http.Response {
    return text(200, c.query("q") + "|" + to_str(c.query_int("page", 1)));
}

fn h_state(c: Ctx[TestState]) -> http.Response {
    c.state.hits = c.state.hits + 1;
    return text(200, c.state.name + ":" + to_str(c.state.hits));
}

fn h_method(c: Ctx[TestState]) -> http.Response {
    return text(200, to_str(c.method()) + "|" + c.method_str());
}

fn h_created(c: Ctx[TestState]) -> http.Response {
    return created("{\"id\":\"new\"}", "/things/new");
}

gc struct Greeting {
    message: str,
}

fn h_dto(c: Ctx[TestState]) -> http.Response {
    let r: result[Greeting, http.Response] = dto(c);
    guard let body = r else let resp = err_of(r) {
        return resp;
    }
    return text(200, "got:" + body.message);
}

gc struct Search {
    q: str,
    page: i32,
    active: bool,
}

fn h_query_as(c: Ctx[TestState]) -> http.Response {
    let r: result[Search, http.Response] = query_as(c);
    guard let s = r else let resp = err_of(r) {
        return resp;
    }
    return text(200, s.q + "|" + to_str(s.page) + "|" + to_str(s.active));
}

fn block_secret(c: Ctx[TestState]) -> opt[http.Response] {
    if c.route == "/secret" && c.bearer() != "letmein" {
        return some(respond(new_registry(), "unauthorized", c.request_id));
    }
    return none;
}

fn stamp(c: Ctx[TestState], r: http.Response) -> http.Response {
    return with_header(r, "x-route", c.route);
}

fn new_test_router() -> Router[TestState] {
    return new_router(TestState { hits: 0, name: "t" });
}

fn req(method: str, p: str) -> http.Request {
    let h: map[str]str = {};
    let rr = http.request(method, p, "HTTP/1.1", h, to_bytes(""));
    guard let r = rr else {
        panic("req: bad test request");
    }
    return r;
}

fn req_auth(method: str, p: str, token: str) -> http.Request {
    let h: map[str]str = {};
    h["authorization"] = "Bearer " + token;
    let rr = http.request(method, p, "HTTP/1.1", h, to_bytes(""));
    guard let r = rr else {
        panic("req_auth: bad test request");
    }
    return r;
}

fn test_every_http_method_routes() {
    let r = new_test_router();
    r.get("/m", h_ok);
    r.head("/m", h_ok);
    r.post("/m", h_ok);
    r.put("/m", h_ok);
    r.patch("/m", h_ok);
    r.delete("/m", h_ok);
    r.options("/m", h_ok);
    r.trace("/m", h_ok);
    r.connect("/m", h_ok);
    let methods = [Method.GET, Method.HEAD, Method.POST, Method.PUT,
                   Method.PATCH, Method.DELETE, Method.OPTIONS,
                   Method.TRACE, Method.CONNECT];
    let i = 0;
    while i < len(methods) {
        let resp = r.serve(req(to_str(methods[i]), "/m"));
        assert(resp.status == 200);
        i = i + 1;
    }
    assert(len(r.routes_list()) == 9);
}

fn test_any_registers_several() {
    let r = new_test_router();
    r.any([Method.GET, Method.POST], "/multi", h_ok);
    assert(r.serve(req("GET", "/multi")).status == 200);
    assert(r.serve(req("POST", "/multi")).status == 200);
    assert(r.serve(req("DELETE", "/multi")).status == 405);
}

fn test_params_and_wildcard() {
    let r = new_test_router();
    r.get("/orgs/:id", h_param);
    r.get("/orgs/:id/keys/:key", h_two);
    r.get("/files/*rest", h_rest);
    assert(to_str(r.serve(req("GET", "/orgs/7")).body) == "{\"id\":\"7\"}");
    assert(to_str(r.serve(req("GET", "/orgs/7/keys/k1")).body) ==
           "{\"id\":\"7\",\"key\":\"k1\"}");
    assert(to_str(r.serve(req("GET", "/files/a/b/c.txt")).body) ==
           "{\"rest\":\"a/b/c.txt\"}");
    assert(r.serve(req("GET", "/orgs")).status == 404);
}

fn test_query_is_not_part_of_the_route() {
    let r = new_test_router();
    r.get("/s", h_query);
    let resp = r.serve(req("GET", "/s?q=slang&page=3"));
    assert(to_str(resp.body) == "slang|3");
    assert(to_str(r.serve(req("GET", "/s")).body) == "|1");
}

fn test_unknown_verb_is_not_implemented() {
    let r = new_test_router();
    r.get("/thing", h_ok);
    let resp = r.serve(req("BREW", "/thing"));
    assert(resp.status == 501);
}

fn test_method_reaches_the_handler_as_a_value() {
    let r = new_test_router();
    r.post("/echo", h_method);
    assert(to_str(r.serve(req("POST", "/echo")).body) == "POST|POST");
}

fn test_405_carries_allow_and_404_does_not() {
    let r = new_test_router();
    r.get("/thing", h_ok);
    r.post("/thing", h_ok);
    let resp = r.serve(req("DELETE", "/thing"));
    assert(resp.status == 405);
    assert(resp_header(resp, "allow") == "GET, POST, HEAD, OPTIONS");
    let nf = r.serve(req("GET", "/nothing"));
    assert(nf.status == 404);
    assert(resp_header(nf, "allow") == "");
}

fn test_head_is_served_by_get_without_a_body() {
    let r = new_test_router();
    r.get("/page", h_ok);
    let resp = r.serve(req("HEAD", "/page"));
    assert(resp.status == 200);
    assert(len(resp.body) == 0);
    assert(resp_header(resp, "content-type") == "application/json; charset=utf-8");
}

fn test_options_is_answered_automatically() {
    let r = new_test_router();
    r.get("/thing", h_ok);
    r.delete("/thing", h_ok);
    let resp = r.serve(req("OPTIONS", "/thing"));
    assert(resp.status == 204);
    assert(resp_header(resp, "allow") == "GET, DELETE, HEAD, OPTIONS");
}

fn test_explicit_options_route_wins() {
    let r = new_test_router();
    r.get("/thing", h_ok);
    r.options("/thing", h_ok);
    let resp = r.serve(req("OPTIONS", "/thing"));
    assert(resp.status == 200);
}

fn test_before_can_stop_and_after_always_runs() {
    let r = new_test_router();
    r.get("/secret", h_ok);
    r.get("/open", h_ok);
    r.before(block_secret);
    r.after(stamp);
    let blocked = r.serve(req("GET", "/secret"));
    assert(blocked.status == 401);
    assert(resp_header(blocked, "x-route") == "/secret");
    let allowed = r.serve(req_auth("GET", "/secret", "letmein"));
    assert(allowed.status == 200);
    let open_r = r.serve(req("GET", "/open"));
    assert(open_r.status == 200);
    assert(resp_header(open_r, "x-route") == "/open");
}

fn test_state_reaches_handlers_and_persists() {
    let r = new_test_router();
    r.get("/hit", h_state);
    assert(to_str(r.serve(req("GET", "/hit")).body) == "t:1");
    assert(to_str(r.serve(req("GET", "/hit")).body) == "t:2");
    assert(r.state.hits == 2);
}

fn test_request_id_is_echoed() {
    let r = new_test_router();
    r.get("/x", h_ok);
    let resp = r.serve_id(req("GET", "/x"), "req-42");
    assert(resp_header(resp, "x-request-id") == "req-42");
    let missing = r.serve_id(req("GET", "/none"), "req-43");
    assert(missing.status == 404);
    assert(resp_header(missing, "x-request-id") == "req-43");
}

fn test_created_sets_location() {
    let r = new_test_router();
    r.post("/things", h_created);
    let resp = r.serve(req("POST", "/things"));
    assert(resp.status == 201);
    assert(resp_header(resp, "location") == "/things/new");
}

fn test_trailing_slashes_are_the_same_route() {
    let r = new_test_router();
    r.get("/a/b", h_ok);
    assert(r.serve(req("GET", "/a/b/")).status == 200);
    assert(r.serve(req("GET", "//a//b")).status == 200);
}

fn test_new_router_defaults() {
    let r = new_router(TestState { hits: 0, name: "fresh" });
    assert(len(r.routes) == 0);
    assert(r.state.name == "fresh");
    // the defaults a correct server should have: OPTIONS and HEAD
    // answered automatically until told otherwise
    r.get("/x", h_ok);
    assert(r.serve(req("HEAD", "/x")).status == 200);
    assert(r.serve(req("OPTIONS", "/x")).status == 204);
}

fn test_new_group_matches_the_method() {
    let r = new_test_router();
    let g = new_group(r, "/api");
    g.get("/things", h_ok);
    let resp = r.serve(req("GET", "/api/things"));
    assert(resp.status == 200);
    assert(resp.body == to_bytes("{\"route\":\"/api/things\"}"));
}

fn json_post(p: str, body: str) -> http.Request {
    let h: map[str]str = {};
    h["content-type"] = "application/json";
    let rr = http.request("POST", p, "HTTP/1.1", h, to_bytes(body));
    guard let r = rr else {
        panic("json_post: bad test request");
    }
    return r;
}

fn test_dto_decodes_or_answers_decode_failed() {
    let r = new_test_router();
    r.post("/greet", h_dto);
    let good = r.serve(json_post("/greet", "{\"message\":\"hi\"}"));
    assert(good.status == 200);
    assert(to_str(good.body) == "got:hi");

    // a missing required field goes through decode_failed, naming it
    let bad = r.serve(json_post("/greet", "{}"));
    assert(bad.status == 422);
    assert(strings.contains(to_str(bad.body), "\"field\":\"message\""));
}

fn test_query_as_binds_typed_fields_or_answers_decode_failed() {
    let r = new_test_router();
    r.get("/search", h_query_as);
    let good = r.serve(req("GET", "/search?q=slang&page=2&active=true"));
    assert(good.status == 200);
    assert(to_str(good.body) == "slang|2|true");

    // page is not a number here, so it fails exactly like a bad body
    let bad = r.serve(req("GET", "/search?q=slang&page=nope&active=true"));
    assert(bad.status == 422);
    assert(strings.contains(to_str(bad.body), "\"field\":\"page\""));
}

fn frame_req(method: str, target: str) -> http.WireFrame {
    let raw = to_bytes(method + " " + target + " HTTP/1.1\r\nHost: t\r\n\r\n");
    let fr = http.parse_frame(raw);
    guard let f = fr else {
        panic("frame_req: bad test frame");
    }
    return http.WireFrame {
        line_end: f.line_end,
        head_end: f.head_end,
        body_start: f.body_start,
        body_end: f.body_end,
        end: len(raw),
        version: f.version,
        close: false,
        filled: 0,
        head: raw,
        chunked_body: b"",
        is_chunked: false
    };
}

fn test_frame_exact_matches_without_segs() {
    let r = new_test_router();
    r.get("/", h_ok);
    r.get("/users/:id", h_param);
    r.get("/orgs/:id/keys/:key", h_two);
    r.get("/files/*rest", h_rest);
    let root = frame_req("GET", "/");
    assert(to_str(r.serve_frame(root.head, root, "").body) ==
           "{\"route\":\"/\"}");
    let one = frame_req("GET", "/users/42");
    assert(to_str(r.serve_frame(one.head, one, "").body) == "{\"id\":\"42\"}");
    // query strings never reach the route: same frame shape, same answer
    let q = frame_req("GET", "/users/42?verbose=true");
    assert(to_str(r.serve_frame(q.head, q, "").body) == "{\"id\":\"42\"}");
    // multi-param and wildcard shapes fall back to serve_id: same body
    let two = frame_req("GET", "/orgs/7/keys/k1");
    assert(to_str(r.serve_frame(two.head, two, "").body) ==
           "{\"id\":\"7\",\"key\":\"k1\"}");
    let wild = frame_req("GET", "/files/a/b/c.txt");
    assert(to_str(r.serve_frame(wild.head, wild, "").body) ==
           "{\"rest\":\"a/b/c.txt\"}");
    // method mismatch on an exact path is a 405 with Allow, not a 404
    let bad = frame_req("DELETE", "/");
    let denied = r.serve_frame(bad.head, bad, "");
    assert(denied.status == 405);
    assert(resp_header(denied, "allow") == "GET, HEAD, OPTIONS");
    // unknown path is a 404 through the same error shape
    let nf = frame_req("GET", "/nothing");
    assert(r.serve_frame(nf.head, nf, "").status == 404);
    // unknown verb is a 501, same as serve_id
    let brew = frame_req("BREW", "/");
    assert(r.serve_frame(brew.head, brew, "").status == 501);
}
