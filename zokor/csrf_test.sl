import "http";

fn cs_guard() -> CsrfGuard {
    let r = csrf_guard(["https://app.example.com"]);
    guard let g = r else let e = err_of(r) {
        panic(e);
    }
    return g;
}

fn test_csrf_safe_methods_always_pass() {
    assert(csrf_allows(cs_guard(), "GET", "cross-site", "https://evil.test", "api.example.com"));
    assert(csrf_allows(cs_guard(), "HEAD", "cross-site", "https://evil.test", "api.example.com"));
    assert(csrf_allows(cs_guard(), "OPTIONS", "cross-site", "https://evil.test", "api.example.com"));
}

fn test_csrf_refuses_a_cross_site_post() {
    assert(!csrf_allows(cs_guard(), "POST", "cross-site", "https://evil.test", "api.example.com"));
}

// A sibling subdomain can be someone else's, or compromised.
fn test_csrf_refuses_a_same_site_post() {
    assert(!csrf_allows(cs_guard(), "POST", "same-site", "https://blog.example.com", "api.example.com"));
}

fn test_csrf_refuses_every_unsafe_method() {
    for m in ["POST", "PUT", "PATCH", "DELETE"] {
        assert(!csrf_allows(cs_guard(), m, "cross-site", "https://evil.test", "api.example.com"));
    }
}

fn test_csrf_passes_same_origin_and_user_initiated() {
    assert(csrf_allows(cs_guard(), "POST", "same-origin", "", "api.example.com"));
    assert(csrf_allows(cs_guard(), "POST", "none", "", "api.example.com"));
}

fn test_csrf_trusted_origin_passes_from_another_site() {
    assert(csrf_allows(cs_guard(), "POST", "cross-site", "https://app.example.com", "api.example.com"));
    assert(csrf_allows(cs_guard(), "POST", "", "https://app.example.com", "api.example.com"));
}

fn test_csrf_trusted_origin_must_match_scheme_and_host_exactly() {
    assert(!csrf_allows(cs_guard(), "POST", "cross-site", "http://app.example.com", "api.example.com"));
    assert(!csrf_allows(cs_guard(), "POST", "cross-site", "https://app.example.com.evil.test", "api.example.com"));
}

fn test_csrf_old_browser_is_judged_by_origin_against_host() {
    assert(csrf_allows(cs_guard(), "POST", "", "https://api.example.com", "api.example.com"));
    assert(csrf_allows(cs_guard(), "POST", "", "https://API.example.com", "api.example.com"));
    assert(!csrf_allows(cs_guard(), "POST", "", "https://evil.test", "api.example.com"));
}

fn test_csrf_origin_must_match_the_host_and_port_whole() {
    assert(!csrf_allows(cs_guard(), "POST", "", "https://api.example.com:8443", "api.example.com"));
    assert(!csrf_allows(cs_guard(), "POST", "", "https://evil.test/api.example.com", "api.example.com"));
}

// A sandboxed iframe or a redirect sends Origin: null.
fn test_csrf_refuses_a_null_origin() {
    assert(!csrf_allows(cs_guard(), "POST", "", "null", "api.example.com"));
}

fn test_csrf_refuses_an_origin_when_the_request_has_no_host() {
    assert(!csrf_allows(cs_guard(), "POST", "", "https://evil.test", ""));
}

// curl and server-to-server clients have no cookie jar to abuse.
fn test_csrf_passes_a_client_with_neither_header() {
    assert(csrf_allows(cs_guard(), "POST", "", "", "api.example.com"));
}

fn test_csrf_guard_names_every_malformed_origin() {
    let r = csrf_guard(["app.example.com", "https://ok.example.com", "ftp://"]);
    guard let _g = r else let e = err_of(r) {
        assert(contains(e, "app.example.com"));
        assert(contains(e, "ftp://"));
        assert(!contains(e, "ok.example.com"));
        return;
    }
    panic("expected malformed origins to be refused");
}

gc struct CsApp {
    csrf: CsrfGuard,
}

fn cs_before(c: Ctx[CsApp]) -> opt[http.Response] {
    return csrf_check(c, c.state.csrf);
}

fn cs_ok(c: Ctx[CsApp]) -> http.Response {
    return ok_json("{}");
}

fn test_csrf_check_rejects_through_the_router_in_the_envelope() {
    let r = new_router(CsApp { csrf: cs_guard() });
    r.before(cs_before);
    r.post("/x", cs_ok);
    let bad = r.serve(request(Method.POST, "/x").header("sec-fetch-site", "cross-site")
                      .header("origin", "https://evil.test").header("host", "api.example.com").build());
    assert(resp_status(bad) == 403);
    assert(resp_error_code(bad) == "csrf_rejected");
    let good = r.serve(request(Method.POST, "/x").header("sec-fetch-site", "same-origin").build());
    assert(resp_status(good) == 200);
}

fn test_csrf_guard_from_config_reads_origins_and_reports_a_bad_one() {
    let good = csrf_guard_from(cfg_of("CSRF_TRUSTED_ORIGINS=https://a.example.com,https://b.example.com\n"));
    assert(csrf_allows(good, "POST", "cross-site", "https://b.example.com", "api.example.com"));
    let c = cfg_of("CSRF_TRUSTED_ORIGINS=nope\n");
    let bad = csrf_guard_from(c);
    assert(len(problems(c)) == 1);
    assert(!csrf_allows(bad, "POST", "cross-site", "https://evil.test", "api.example.com"));
}
