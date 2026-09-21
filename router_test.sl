import "http";

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

fn h_created(c: Ctx[TestState]) -> http.Response {
    return created("{\"id\":\"new\"}", "/things/new");
}

fn block_secret(c: Ctx[TestState]) -> opt[http.Response] {
    if c.route == "/secret" && c.bearer() != "letmein" {
        return some(respond(new_registry(), "unauthorized", c.request_id));
    }
    return none;
}

fn stamp(c: Ctx[TestState], r: http.Response) -> http.Response {
    r.headers["x-route"] = c.route;
    return r;
}

fn new_test_router() -> Router[TestState] {
    let st = TestState { hits: 0, name: "t" };
    return Router[TestState] {
        routes: [],
        befores: [],
        afters: [],
        state: st,
        errors: new_registry(),
        auto_options: true,
        auto_head: true
    };
}

fn req(method: str, p: str) -> http.Request {
    let h: map[str]str = {};
    return http.Request {
        method: method,
        path: p,
        version: "HTTP/1.1",
        headers: h,
        body: to_bytes("")
    };
}

fn req_auth(method: str, p: str, token: str) -> http.Request {
    let h: map[str]str = {};
    h["authorization"] = "Bearer " + token;
    return http.Request {
        method: method,
        path: p,
        version: "HTTP/1.1",
        headers: h,
        body: to_bytes("")
    };
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
    let methods = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE",
                   "OPTIONS", "TRACE", "CONNECT"];
    let i = 0;
    while i < len(methods) {
        let resp = r.serve(req(methods[i], "/m"));
        assert(resp.status == 200);
        i = i + 1;
    }
    assert(len(r.routes_list()) == 9);
}

fn test_any_registers_several() {
    let r = new_test_router();
    r.any(["GET", "POST"], "/multi", h_ok);
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

fn test_405_carries_allow_and_404_does_not() {
    let r = new_test_router();
    r.get("/thing", h_ok);
    r.post("/thing", h_ok);
    let resp = r.serve(req("DELETE", "/thing"));
    assert(resp.status == 405);
    assert(has(resp.headers, "allow"));
    let allow = resp.headers["allow"];
    assert(allow == "GET, POST, HEAD, OPTIONS");
    let nf = r.serve(req("GET", "/nothing"));
    assert(nf.status == 404);
    assert(!has(nf.headers, "allow"));
}

fn test_head_is_served_by_get_without_a_body() {
    let r = new_test_router();
    r.get("/page", h_ok);
    let resp = r.serve(req("HEAD", "/page"));
    assert(resp.status == 200);
    assert(len(resp.body) == 0);
    assert(has(resp.headers, "content-type"));
}

fn test_options_is_answered_automatically() {
    let r = new_test_router();
    r.get("/thing", h_ok);
    r.delete("/thing", h_ok);
    let resp = r.serve(req("OPTIONS", "/thing"));
    assert(resp.status == 204);
    assert(resp.headers["allow"] == "GET, DELETE, HEAD, OPTIONS");
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
    assert(blocked.headers["x-route"] == "/secret");
    let allowed = r.serve(req_auth("GET", "/secret", "letmein"));
    assert(allowed.status == 200);
    let open_r = r.serve(req("GET", "/open"));
    assert(open_r.status == 200);
    assert(open_r.headers["x-route"] == "/open");
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
    assert(resp.headers["x-request-id"] == "req-42");
    let missing = r.serve_id(req("GET", "/none"), "req-43");
    assert(missing.status == 404);
    assert(missing.headers["x-request-id"] == "req-43");
}

fn test_created_sets_location() {
    let r = new_test_router();
    r.post("/things", h_created);
    let resp = r.serve(req("POST", "/things"));
    assert(resp.status == 201);
    assert(resp.headers["location"] == "/things/new");
}

fn test_trailing_slashes_are_the_same_route() {
    let r = new_test_router();
    r.get("/a/b", h_ok);
    assert(r.serve(req("GET", "/a/b/")).status == 200);
    assert(r.serve(req("GET", "//a//b")).status == 200);
}
