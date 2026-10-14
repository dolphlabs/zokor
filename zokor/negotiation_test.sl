import "http";
import "strings";

fn test_vary_accept_is_distinct_from_accept_encoding() {
    let response = with_header(text(200, "ok"), "vary", "Accept-Encoding");
    let varied = add_vary(response, "Accept");
    assert(resp_header(varied, "vary") == "Accept-Encoding, Accept", resp_header(varied, "vary"));
}

gc struct NegotiationState { n: Negotiator }
fn negotiation_state(offers: [str]) -> NegotiationState {
    let made = new_negotiator(offers, accept_limits());
    guard let n = made else let e = err_of(made) { panic(e); }
    return NegotiationState { n: n };
}
fn negotiation_handler(c: Ctx[NegotiationState]) -> http.Response {
    let picked = negotiate(c, c.state.n);
    guard let media = picked else let bad = err_of(picked) { return bad; }
    return bytes_of(200, media, b"chosen");
}
fn negotiation_router() -> Router[NegotiationState] {
    let r = new_router(negotiation_state(["application/json", "text/html", "text/plain;title=\"a, b\""]));
    r.get("/pick", negotiation_handler);
    return r;
}
fn test_negotiation_routes_quality_specificity_absence_and_empty_headers() {
    let r = negotiation_router();
    let first = r.serve(get_request("/pick").build());
    assert(first.content_type == "application/json" && resp_header(first, "vary") == "Accept");
    let weighted = r.serve(get_request("/pick").header("accept", "text/*;q=1, text/html;q=0, application/json;q=0.5").build());
    assert(weighted.content_type == "text/plain;title=\"a, b\"");
    let refused = r.serve(get_request("/pick").header("accept", "*/*;q=0").build());
    assert(refused.status == 406 && resp_error_code(refused) == "not_acceptable");
    assert(resp_header(refused, "vary") == "Accept");
    let empty = r.serve(get_request("/pick").header("accept", "").build());
    assert(empty.status == 406);
    let bad = r.serve(get_request("/pick").header("accept", "text/html;q=.5").build());
    assert(bad.status == 400 && resp_error_code(bad) == "bad_request");
    assert(strings.contains(resp_text(bad), "\"field\":\"Accept\""));
}
fn test_negotiation_preserves_quoted_values_across_repeated_header_lines() {
    let r = negotiation_router();
    let req = get_request("/pick").build();
    req.raw_headers = b"Accept: application/json;q=0\r\nAccept: text/plain;title=\"a, b\"\r\n";
    let answer = r.serve(req);
    assert(answer.status == 200 && answer.content_type == "text/plain;title=\"a, b\"");
}
fn test_negotiator_collects_startup_errors_and_copies_offers_and_limits() {
    let cfg = accept_limits();
    cfg.max_bytes = 0; cfg.max_ranges = 0; cfg.max_params = -1; cfg.max_offer_bytes = 0;
    let bad = new_negotiator(["text/*", "invalid"], cfg);
    guard let _b = bad else let e = err_of(bad) {
        for name in ["max_bytes", "max_ranges", "max_params", "max_offer_bytes", "offers[0]", "offers[1]"] {
            assert(strings.contains(e, name), e);
        }
        let offers = ["application/json", "text/html"];
        let limits = accept_limits(); limits.max_bytes = 32;
        let made = new_negotiator(offers, limits);
        guard let n = made else { panic("valid offers rejected"); }
        offers[0] = "changed"; limits.max_bytes = 1;
        let chosen = n.choose(some("application/json"));
        guard let c = chosen else { panic("copied settings changed"); }
        assert((c ?? "none") == "application/json");
        let long = n.choose(some("application/json;too=long-to-fit-in-the-limit"));
        guard let _l = long else { return; } panic("header cap bypassed");
    }
    panic("invalid startup settings accepted");
}
fn test_vary_checks_all_lines_and_exact_tokens() {
    let response = with_header(with_header(text(200, "ok"), "vary", "Accept-Encoding"), "vary", "Origin, ACCEPT");
    let count = len(response.extra);
    let varied = add_vary(response, "Accept");
    assert(len(varied.extra) == count && varied.extra[0] == "vary: Accept-Encoding");
    let star = with_header(with_header(text(200, "ok"), "vary", "Origin"), "vary", "*");
    let checked = add_vary(star, "Accept");
    assert(checked.extra[0] == "vary: Origin");
}
fn test_checked_redirects_preserve_status_location_and_empty_body() {
    for code in [301, 302, 303, 307, 308] {
        let made = redirect_checked(code as i32, "/next?x=1#part", redirect_rules());
        guard let answer = made else let e = err_of(made) { panic(e); }
        assert(answer.status == code as i32 && answer.location == "/next?x=1#part" && len(answer.body) == 0);
        assert(answer.status_text == status_text(code as i32));
    }
    let default_ = redirect_to("../next");
    guard let answer = default_ else { panic("relative redirect rejected"); }
    assert(answer.status == 303 && answer.location == "../next");
    let rules = redirect_rules(); rules.allow_external = true;
    let external = redirect_checked(307, "https://example.com:8443/next", rules);
    guard let ext = external else { panic("explicit external redirect rejected"); }
    assert(ext.location == "https://example.com:8443/next");
}
fn test_checked_redirect_errors_collect_fields_without_echoing_secrets() {
    let bad = redirect_checked(200, "https://user:secret@host/", redirect_rules());
    guard let _b = bad else let e = err_of(bad) {
        assert(strings.contains(e, "status") && strings.contains(e, "location") && !strings.contains(e, "secret"));
        let rules = redirect_rules(); rules.allow_external = true;
        let port = redirect_checked(303, "http://host:secret/", rules);
        guard let _p = port else let pe = err_of(port) {
            assert(strings.contains(pe, "location") && !strings.contains(pe, "secret"));
            return;
        }
        panic("bad URL port accepted");
    }
    panic("invalid redirect accepted");
}
fn negotiation_large(c: Ctx[NegotiationState]) -> http.Response {
    let picked = negotiate(c, c.state.n);
    guard let media = picked else let bad = err_of(picked) { return bad; }
    return bytes_of(200, media, to_bytes(strings.repeat("a", 4096)));
}
fn test_negotiation_gzip_and_cors_keep_all_vary_fields() {
    let r = negotiation_router();
    r.get("/large", negotiation_large);
    r.compress(compression());
    r.cors(cors_policy(["https://app.example.com"]));
    let resp = r.serve(get_request("/large").header("accept", "application/json")
        .header("accept-encoding", "gzip").header("origin", "https://app.example.com").build());
    assert(resp.status == 200 && resp_header(resp, "content-encoding") == "gzip");
    let fields: [str] = [];
    for line in resp.extra {
        if strings.has_prefix(strings.to_lower(line), "vary:") {
            for part in strings.split(strings.slice(line, 5, len(line)), ",") { push(fields, strings.trim(part)); }
        }
    }
    assert(len(fields) == 3 && fields[0] == "Accept" && fields[1] == "Accept-Encoding" && fields[2] == "Origin");
}
