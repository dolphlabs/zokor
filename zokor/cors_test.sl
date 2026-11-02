import "http";
import "strings";

gc struct CoState {
    n: int,
}

fn co_ok(c: Ctx[CoState]) -> http.Response {
    return text(200, "ok");
}

fn co_refuse(c: Ctx[CoState]) -> opt[http.Response] {
    return some(respond(c.errors, "unauthorized", c.request_id));
}

fn co_router(p: CorsPolicy) -> Router[CoState] {
    let r = new_router(CoState { n: 0 });
    r.get("/orgs/:id", co_ok);
    r.post("/orgs", co_ok);
    assert(r.cors(p) > 0, cors_problem(p));
    return r;
}

fn co_get(r: Router[CoState], p: str, origin: str) -> http.Response {
    let rq = get_request(p);
    if len(origin) > 0 {
        rq = rq.header("Origin", origin);
    }
    return r.serve(rq.build());
}

fn co_preflight(r: Router[CoState], p: str, origin: str) -> http.Response {
    return r.serve(request(Method.OPTIONS, p)
        .header("Origin", origin)
        .header("Access-Control-Request-Method", "POST")
        .header("Access-Control-Request-Headers", "content-type")
        .build());
}

fn test_cors_policy_problems_name_the_fix() {
    assert(cors_problem(cors_policy(["https://app.example.com", "http://localhost:5173"])) == "");
    assert(strings.contains(cors_problem(cors_policy(["https://app.example.com/"])), "trailing slash"));
    assert(strings.contains(cors_problem(cors_policy(["app.example.com"])), "scheme://host"));
    assert(strings.contains(cors_problem(cors_policy(["ftp://x.com"])), "https://"));
    assert(strings.contains(cors_problem(cors_policy(["https://App.example.com"])), "lower case"));
    assert(strings.contains(cors_problem(cors_policy(["https://a.*.example.com"])), "wildcard"));
    assert(cors_problem(cors_policy(["https://*.example.com"])) == "");
    let p = cors_policy(["*"]);
    p.credentials = true;
    assert(strings.contains(cors_problem(p), "credentials cannot be allowed for every origin"));
    assert(strings.contains(cors_problem(cors_policy(["*", "https://a.com"])), "'*' alone"));
    let q = cors_policy(["https://a.com"]);
    q.methods = ["GET", "BAD METHOD"];
    q.max_age = 999999;
    let why = cors_problem(q);
    assert(strings.contains(why, "BAD METHOD") && strings.contains(why, "max age"), why);
}

fn test_origin_matching_is_exact_or_a_true_subdomain() {
    let c = cors_compile(cors_policy(["https://app.example.com", "https://*.example.org"]));
    assert(c.allows("https://app.example.com"));
    assert(!c.allows("https://app.example.com.evil.net"));
    assert(!c.allows("http://app.example.com"), "scheme matters");
    assert(c.allows("https://api.example.org"));
    assert(c.allows("https://a.b.example.org"));
    assert(!c.allows("https://example.org"), "the bare domain is not a subdomain");
    assert(!c.allows("https://evilexample.org"));
    assert(!c.allows("http://api.example.org"));
    assert(!c.allows("https://api.example.org:8443"), "port matters");
    assert(!c.allows(""));
    assert(!cors_off().allows("https://app.example.com"));
}

fn test_allowed_origin_gets_its_own_origin_back() {
    let r = co_router(cors_policy(["https://app.example.com"]));
    let resp = co_get(r, "/orgs/7", "https://app.example.com");
    assert(resp_status(resp) == 200);
    assert(resp_header(resp, "access-control-allow-origin") == "https://app.example.com");
    assert(resp_header(resp, "vary") == "Origin");
    assert(resp_header(resp, "access-control-expose-headers") == "X-Request-Id");
    assert(resp_header(resp, "access-control-allow-credentials") == "");
}

fn test_other_origins_get_no_cors_headers_but_still_vary() {
    let r = co_router(cors_policy(["https://app.example.com"]));
    let resp = co_get(r, "/orgs/7", "https://evil.example.net");
    assert(resp_status(resp) == 200, "the response is sent; the browser withholds it");
    assert(resp_header(resp, "access-control-allow-origin") == "");
    assert(resp_header(resp, "vary") == "Origin", "a cache must not reuse it for another origin");
    let none_sent = co_get(r, "/orgs/7", "");
    assert(resp_header(none_sent, "access-control-allow-origin") == "");
    assert(resp_header(none_sent, "vary") == "Origin");
}

fn test_any_origin_without_credentials_is_a_star() {
    let r = co_router(cors_policy(["*"]));
    let resp = co_get(r, "/orgs/7", "https://anyone.example");
    assert(resp_header(resp, "access-control-allow-origin") == "*");
    assert(resp_header(resp, "vary") == "", "a star does not depend on the origin");
}

fn test_credentials_are_allowed_only_for_listed_origins() {
    let p = cors_policy(["https://app.example.com"]);
    p.credentials = true;
    let r = co_router(p);
    let resp = co_get(r, "/orgs/7", "https://app.example.com");
    assert(resp_header(resp, "access-control-allow-credentials") == "true");
    assert(resp_header(resp, "access-control-allow-origin") == "https://app.example.com");
}

fn test_error_responses_carry_cors_headers_too() {
    let r = co_router(cors_policy(["https://app.example.com"]));
    let nf = co_get(r, "/nope", "https://app.example.com");
    assert(resp_status(nf) == 404);
    assert(resp_header(nf, "access-control-allow-origin") == "https://app.example.com");
    r.before(co_refuse);
    let denied = co_get(r, "/orgs/7", "https://app.example.com");
    assert(resp_status(denied) == 401);
    assert(resp_header(denied, "access-control-allow-origin") == "https://app.example.com",
           "the page must be able to read the 401");
}

fn test_preflight_is_answered_before_routing() {
    let r = co_router(cors_policy(["https://app.example.com"]));
    r.before(co_refuse);
    let pf = co_preflight(r, "/orgs", "https://app.example.com");
    assert(resp_status(pf) == 204, to_str(resp_status(pf)));
    assert(resp_header(pf, "access-control-allow-origin") == "https://app.example.com");
    assert(resp_header(pf, "access-control-allow-methods") == "GET, HEAD, POST, PUT, PATCH, DELETE");
    assert(resp_header(pf, "access-control-allow-headers") == "Content-Type, Authorization, X-Request-Id");
    assert(resp_header(pf, "access-control-max-age") == "600");
    assert(strings.has_prefix(resp_header(pf, "vary"), "Origin, Access-Control-Request-Method"));
    assert(len(pf.body) == 0);
}

fn test_preflight_from_another_origin_gets_no_permission() {
    let r = co_router(cors_policy(["https://app.example.com"]));
    let pf = co_preflight(r, "/orgs", "https://evil.example.net");
    assert(resp_status(pf) == 204);
    assert(resp_header(pf, "access-control-allow-origin") == "");
    assert(resp_header(pf, "access-control-allow-methods") == "");
}

fn test_preflight_to_a_missing_path_is_404() {
    let r = co_router(cors_policy(["https://app.example.com"]));
    assert(resp_status(co_preflight(r, "/nope", "https://app.example.com")) == 404);
}

fn test_plain_options_still_gets_allow() {
    let r = co_router(cors_policy(["https://app.example.com"]));
    let o = r.serve(request(Method.OPTIONS, "/orgs").build());
    assert(resp_status(o) == 204);
    assert(strings.contains(resp_header(o, "allow"), "POST"), resp_header(o, "allow"));
}

fn test_cors_is_off_until_turned_on_and_refuses_a_bad_policy() {
    let r = new_router(CoState { n: 0 });
    r.get("/orgs/:id", co_ok);
    let resp = co_get(r, "/orgs/7", "https://app.example.com");
    assert(resp_header(resp, "access-control-allow-origin") == "");
    assert(resp_header(resp, "vary") == "");
    let bad = cors_policy(["*"]);
    bad.credentials = true;
    assert(r.cors(bad) == -1);
    assert(!r.cors.on);
}

fn test_cors_from_config() {
    let c = cfg_of("CORS_ORIGINS=https://app.example.com, https://*.example.org\n" +
                   "CORS_METHODS=get,post\nCORS_CREDENTIALS=true\nCORS_MAX_AGE=120\n");
    let p = cors_from(c);
    assert(len(p.origins) == 2 && p.origins[1] == "https://*.example.org");
    assert(strings.join(p.methods, ",") == "GET,POST");
    assert(p.credentials && p.max_age == 120);
    guard let _ok = check(c) else {
        panic("valid CORS settings reported as a problem");
    }
    assert(len(cors_from(cfg_of("")).origins) == 0, "off when unset");
}

fn test_cors_from_config_reports_problems_and_stays_off() {
    let c = cfg_of("CORS_ORIGINS=*\nCORS_CREDENTIALS=true\nCORS_MAX_AGE=soon\n");
    let p = cors_from(c);
    assert(len(p.origins) == 0, "a policy with problems comes back off");
    let r = check(c);
    guard let _ok = r else let e = err_of(r) {
        assert(strings.contains(e, "CORS_ORIGINS") && strings.contains(e, "CORS_MAX_AGE"), e);
        return;
    }
    panic("bad CORS settings were not reported");
}
