import "http";
import "strings";

gc struct SeState {
    n: int,
}

fn se_ok(c: Ctx[SeState]) -> http.Response {
    return text(200, "ok");
}

fn se_own_frame(c: Ctx[SeState]) -> http.Response {
    return with_header(text(200, "embeddable"), "X-Frame-Options", "SAMEORIGIN");
}

fn se_static(c: Ctx[SeState]) -> http.Response {
    return text(200, "fixed");
}

fn se_router() -> Router[SeState] {
    let r = new_router(SeState { n: 0 });
    r.get("/ok", se_ok);
    r.get("/framed", se_own_frame);
    return r;
}

fn se_get(r: Router[SeState], p: str) -> http.Response {
    return r.serve(get_request(p).build());
}

fn test_every_response_carries_the_defaults() {
    let r = se_router();
    for p in ["/ok", "/nope"] {
        let resp = se_get(r, p);
        assert(resp_header(resp, "content-security-policy") == "default-src 'none'; frame-ancestors 'none'");
        assert(resp_header(resp, "strict-transport-security") == "max-age=31536000; includeSubDomains");
        assert(resp_header(resp, "x-content-type-options") == "nosniff");
        assert(resp_header(resp, "x-frame-options") == "DENY");
        assert(resp_header(resp, "referrer-policy") == "no-referrer");
        assert(resp_header(resp, "cross-origin-resource-policy") == "", "CORP is opt-in");
    }
}

fn test_a_handlers_own_value_wins() {
    let resp = se_get(se_router(), "/framed");
    assert(resp_header(resp, "x-frame-options") == "SAMEORIGIN");
    let n = 0;
    for line in resp.extra {
        if strings.has_prefix(strings.to_lower(line), "x-frame-options") {
            n = n + 1;
        }
    }
    assert(n == 1, "one X-Frame-Options, not two");
}

fn test_no_security_headers_turns_them_off() {
    let r = se_router();
    assert(r.security_headers(no_security_headers()) == 0);
    let resp = se_get(r, "/ok");
    assert(resp_header(resp, "x-content-type-options") == "");
    assert(len(resp.extra) == 0 || resp_header(resp, "content-security-policy") == "");
}

fn test_static_routes_are_rendered_with_them_both_ways() {
    let r = se_router();
    r.static_bytes("/s", 200, "text/plain; charset=utf-8", b"fixed", se_static);
    let rt = r.routes[len(r.routes) - 1];
    guard let ka = rt.static_hit else { panic("no static"); }
    guard let cl = rt.static_close_hit else { panic("no close variant"); }
    let k = to_str(ka.keep_alive);
    let c = to_str(cl.keep_alive);
    assert(strings.contains(k, "x-content-type-options: nosniff\r\n") &&
           strings.contains(k, "Connection: keep-alive\r\n\r\nfixed"), k);
    assert(strings.contains(c, "x-content-type-options: nosniff\r\n") &&
           strings.contains(c, "Connection: close\r\n\r\nfixed"), c);
    // turning them off afterwards re-renders what is already registered
    r.security_headers(no_security_headers());
    guard let ka2 = r.routes[len(r.routes) - 1].static_hit else { panic("no static"); }
    assert(!strings.contains(to_str(ka2.keep_alive), "nosniff"));
}

fn test_bad_settings_are_refused_with_the_fix() {
    let h = default_security_headers();
    h.frame_options = "ALLOW-FROM https://x.com";
    h.referrer_policy = "sometimes";
    h.hsts_preload = true;
    h.hsts_max_age = 600;
    let why = security_problem(h);
    assert(strings.contains(why, "DENY or SAMEORIGIN"), why);
    assert(strings.contains(why, "referrer policy must be one of"), why);
    assert(strings.contains(why, "preload needs max-age"), why);
    let r = se_router();
    assert(r.security_headers(h) == -1);
    assert(resp_header(se_get(r, "/ok"), "x-frame-options") == "DENY", "a refused set changes nothing");
    let crlf = default_security_headers();
    crlf.csp = "default-src 'none'\r\nSet-Cookie: x=1";
    assert(strings.contains(security_problem(crlf), "one line"), "no header injection through config");
}

fn test_security_from_config() {
    let c = cfg_of("CONTENT_SECURITY_POLICY=off\nHSTS_MAX_AGE=0\nFRAME_OPTIONS=sameorigin\n" +
                   "REFERRER_POLICY=strict-origin-when-cross-origin\n" +
                   "CROSS_ORIGIN_RESOURCE_POLICY=same-site\n");
    let lines = security_lines(security_from(c));
    let all = strings.join(lines, "|");
    assert(all == "x-content-type-options: nosniff|x-frame-options: SAMEORIGIN|" +
                  "referrer-policy: strict-origin-when-cross-origin|" +
                  "cross-origin-resource-policy: same-site", all);
    guard let _ok = check(c) else {
        panic("valid security settings reported as a problem");
    }
    assert(len(security_lines(security_from(cfg_of("SECURITY_HEADERS=false\n")))) == 0);
    assert(len(security_lines(security_from(cfg_of("")))) == 5);
}

fn test_security_from_config_reports_problems() {
    let c = cfg_of("FRAME_OPTIONS=ALLOWALL\nHSTS_MAX_AGE=forever\n");
    let lines = security_lines(security_from(c));
    assert(len(lines) == 5, "problems fall back to the defaults, not to nothing");
    let r = check(c);
    guard let _ok = r else let e = err_of(r) {
        assert(strings.contains(e, "HSTS_MAX_AGE") && strings.contains(e, "DENY or SAMEORIGIN"), e);
        return;
    }
    panic("bad security settings were not reported");
}
