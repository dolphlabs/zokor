import "http";

gc struct GState {
    trail: [str],
}

fn g_router() -> Router[GState] {
    let st = GState { trail: [] };
    return Router[GState] {
        routes: [],
        befores: [],
        afters: [],
        state: st,
        errors: new_registry(),
        auto_options: true,
        auto_head: true
    };
}

fn ok_route(c: Ctx[GState]) -> http.Response {
    return text(200, c.route);
}

fn whoami(c: Ctx[GState]) -> http.Response {
    return text(200, "user=" + c.local("user_id") +
                     " tenant=" + c.local("tenant"));
}

// a `before` that resolves something and hands it on
fn resolve_user(c: Ctx[GState]) -> opt[http.Response] {
    if c.bearer() != "good" {
        return some(respond(new_registry(), "unauthorized", c.request_id));
    }
    c.set_local("user_id", "u_1");
    return none;
}

fn resolve_tenant(c: Ctx[GState]) -> opt[http.Response] {
    c.set_local("tenant", "acme");
    return none;
}

fn require_admin(c: Ctx[GState]) -> opt[http.Response] {
    if c.local("user_id") != "u_1" {
        return some(respond(new_registry(), "forbidden", c.request_id));
    }
    return none;
}

fn mark_global(c: Ctx[GState], r: http.Response) -> http.Response {
    push(c.state.trail, "global-after");
    return r;
}

fn mark_route(c: Ctx[GState], r: http.Response) -> http.Response {
    push(c.state.trail, "route-after");
    return with_header(r, "x-route-after", "yes");
}

fn test_group_prefixes_join() {
    let r = g_router();
    let api = r.group("/api/v1");
    api.get("/orgs", ok_route);
    let admin = api.group("/admin");
    admin.get("/orgs/:id", ok_route);
    let list = r.routes_list();
    assert(list[0] == "GET /api/v1/orgs");
    assert(list[1] == "GET /api/v1/admin/orgs/:id");
    assert(resp_status(r.serve(get_request("/api/v1/orgs").build())) == 200);
    assert(resp_status(r.serve(get_request("/api/v1/admin/orgs/7").build())) == 200);
    assert(resp_status(r.serve(get_request("/orgs").build())) == 404);
}

fn test_prefix_slashes_are_tidied() {
    let r = g_router();
    let a = r.group("/api/");
    a.get("orgs", ok_route);
    let b = r.group("");
    b.get("/plain", ok_route);
    let list = r.routes_list();
    assert(list[0] == "GET /api/orgs");
    assert(list[1] == "GET /plain");
}

// The point of groups: middleware attaches to a prefix instead of
// every handler checking its own path.
fn test_group_middleware_guards_only_its_routes() {
    let r = g_router();
    r.get("/health", ok_route);            // outside the group
    let api = r.group("/api");
    api.before(resolve_user);
    api.get("/me", whoami);

    assert(resp_status(r.serve(get_request("/health").build())) == 200);
    assert(resp_status(r.serve(get_request("/api/me").build())) == 401);
    let good = r.serve(get_request("/api/me").bearer("good").build());
    assert(resp_status(good) == 200);
    assert(resp_text(good) == "user=u_1 tenant=");
}

fn test_nested_groups_accumulate_middleware() {
    let r = g_router();
    let api = r.group("/api");
    api.before(resolve_user);
    api.before(resolve_tenant);
    let admin = api.group("/admin");
    admin.before(require_admin);
    admin.get("/me", whoami);
    api.get("/me", whoami);

    let both = r.serve(get_request("/api/admin/me").bearer("good").build());
    assert(resp_status(both) == 200);
    assert(resp_text(both) == "user=u_1 tenant=acme");
    // the admin hook is not on the parent's route
    let parent = r.serve(get_request("/api/me").bearer("good").build());
    assert(resp_status(parent) == 200);
    // and the parent's auth still guards the child
    assert(resp_status(r.serve(get_request("/api/admin/me").build())) == 401);
}

// Middleware added after a route was registered must not change it:
// the route took a copy.
fn test_registration_order_is_what_counts() {
    let r = g_router();
    let api = r.group("/api");
    api.get("/open", ok_route);
    api.before(resolve_user);
    api.get("/closed", ok_route);
    assert(resp_status(r.serve(get_request("/api/open").build())) == 200);
    assert(resp_status(r.serve(get_request("/api/closed").build())) == 401);
}

fn test_one_route_can_be_guarded_on_its_own() {
    let r = g_router();
    r.get("/public", ok_route);
    r.guarded(Method.DELETE, "/orgs/:id", ok_route, [resolve_user]);
    assert(resp_status(r.serve(get_request("/public").build())) == 200);
    let req = request(Method.DELETE, "/orgs/7");
    assert(resp_status(r.serve(req.build())) == 401);
    assert(resp_status(r.serve(request(Method.DELETE, "/orgs/7").bearer("good").build())) == 200);
}

fn test_after_hooks_run_innermost_first() {
    let r = g_router();
    r.after(mark_global);
    let api = r.group("/api");
    api.after(mark_route);
    api.get("/x", ok_route);
    let resp = r.serve(get_request("/api/x").build());
    assert(resp_header(resp, "x-route-after") == "yes");
    assert(len(r.state.trail) == 2);
    assert(r.state.trail[0] == "route-after");
    assert(r.state.trail[1] == "global-after");
}

fn test_after_hooks_run_even_when_a_before_stops_the_request() {
    let r = g_router();
    r.after(mark_global);
    let api = r.group("/api");
    api.before(resolve_user);
    api.after(mark_route);
    api.get("/me", whoami);
    let resp = r.serve(get_request("/api/me").build());
    assert(resp_status(resp) == 401);
    assert(resp_header(resp, "x-route-after") == "yes");
    assert(len(r.state.trail) == 2);
}

fn test_locals_default_to_empty_and_do_not_leak() {
    let r = g_router();
    let api = r.group("/api");
    api.before(resolve_tenant);
    api.get("/me", whoami);
    r.get("/bare", whoami);
    assert(resp_text(r.serve(get_request("/api/me").build())) ==
           "user= tenant=acme");
    // a second request starts clean
    assert(resp_text(r.serve(get_request("/api/me").build())) ==
           "user= tenant=acme");
    assert(resp_text(r.serve(get_request("/bare").build())) ==
           "user= tenant=");
}

// ---------------------------------------------------------------- //
// the test client itself                                            //
// ---------------------------------------------------------------- //

fn echo_body(c: Ctx[GState]) -> http.Response {
    return ok_json(c.body_str());
}

fn echo_headers(c: Ctx[GState]) -> http.Response {
    return text(200, c.header("x-custom") + "|" + c.bearer() + "|" +
                     c.content_type());
}

fn test_request_builder() {
    let r = g_router();
    r.post("/echo", echo_body);
    r.get("/headers", echo_headers);

    let resp = r.serve(request(Method.POST, "/echo")
        .json_body("{\"a\":1}")
        .build());
    assert(resp_status(resp) == 200);
    assert(resp_json(resp).get("a").int_or(0) == 1);

    let built = r.serve(request(Method.POST, "/echo")
        .json(jobj().set_str("name", "acme"))
        .build());
    assert(resp_json(built).get("name").str_or("") == "acme");

    let h = r.serve(get_request("/headers")
        .header("X-Custom", "v")
        .bearer("tok")
        .content_type("text/plain")
        .build());
    assert(resp_text(h) == "v|tok|text/plain");
}

fn test_response_readers() {
    let r = g_router();
    let api = r.group("/api");
    api.before(resolve_user);
    api.get("/me", whoami);
    let denied = r.serve(get_request("/api/me").build());
    assert(resp_status(denied) == 401);
    assert(resp_error_code(denied) == "unauthorized");
    assert(len(resp_error_fields(denied)) == 0);

    let reg = new_registry();
    let fields = [field("name", "is required"), field("age", "must be a number")];
    let invalid = respond_fields(reg, "validation_failed", fields, "");
    assert(resp_error_code(invalid) == "validation_failed");
    let names = resp_error_fields(invalid);
    assert(len(names) == 2);
    assert(names[0] == "name");
    assert(names[1] == "age");
    assert(resp_json(text(200, "not json")).is_null());
}

fn test_multipart_builder_round_trips() {
    let files = [upload_part("avatar", "../../etc/passwd.png", "image/png",
                             "PNGDATA")];
    let fields: map[str]str = {};
    fields["title"] = "My avatar";
    let req = request(Method.POST, "/avatars")
        .multipart("B", fields, files)
        .build();
    let form = parse_form(http.header(req, "content-type") ?? "", req.body,
                          uploads_allowing(["image/png"]));
    guard let f = form else let e = err_of(form) {
        panic("expected the form to parse: " + e.detail);
    }
    assert(value(f, "title") == "My avatar");
    guard let up = file(f, "avatar") else {
        panic("expected the avatar");
    }
    assert(up.filename == "passwd.png");
    assert(to_str(up.data) == "PNGDATA");
}

fn test_request_ids_are_unique_and_labelled() {
    let a = new_request_id();
    let b = new_request_id();
    assert(a != b);
    assert(len(a) == 36);
    assert(to_str(to_bytes(a)[0..4]) == "req_");
    let s = new_session_id();
    assert(len(s) > 0);
    assert(s != new_session_id());
}
