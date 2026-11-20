import "encoding";
import "strings";

fn refused_tokens(body: str) -> str {
    let r = parse_tokens(body);
    guard let _t = r else let e = err_of(r) { return e; }
    panic("accepted token reply: " + body);
}

// RFC 7636 Appendix B.
fn test_pkce_matches_rfc_7636() {
    let v = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    assert(pkce_challenge(v) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    let raw = to_bytes(strings.repeat("a", 32));
    let got = pkce_verifier(raw) ?? "";
    assert(len(got) == 43 && !strings.contains(got, "="), got);
    assert((pkce_verifier(to_bytes("short")) ?? "") == "");
}

fn test_authorize_url_carries_every_parameter() {
    let r = authorize_url("https://id.example.com/authorize", "app 1", "https://app.example.com/cb",
                          ["openid", "email"], "st", "ch", "nn", [Param { name: "prompt", value: "consent" }]);
    guard let u = r else let e = err_of(r) { panic(e); }
    assert(u == "https://id.example.com/authorize?response_type=code&client_id=app+1" +
           "&redirect_uri=https%3A%2F%2Fapp.example.com%2Fcb&state=st&code_challenge=ch" +
           "&code_challenge_method=S256&scope=openid+email&nonce=nn&prompt=consent", u);
    // An endpoint with a query keeps it; no nonce sends none.
    let r2 = authorize_url("https://id.example.com/auth?tenant=x", "c", "https://a/cb", [], "s", "c", "", []);
    let u2 = r2 ?? "";
    assert(strings.has_prefix(u2, "https://id.example.com/auth?tenant=x&response_type=code") &&
           !strings.contains(u2, "nonce") && !strings.contains(u2, "scope"), u2);
    // extra cannot override the flow's own parameters.
    let bad = authorize_url("https://id.example.com/a", "c", "https://a/cb", [], "s", "c", "",
                            [Param { name: "state", value: "evil" }]);
    guard let _b = bad else let e = err_of(bad) { assert(strings.contains(e, "state"), e); return; }
    panic("extra replaced state");
}

fn test_token_bodies_and_client_auth() {
    assert(code_body("c/1", "https://a/cb", "ver", "id", "sec", false) ==
           "grant_type=authorization_code&code=c%2F1&redirect_uri=https%3A%2F%2Fa%2Fcb&code_verifier=ver");
    assert(code_body("c", "https://a/cb", "v", "id", "sec", true) ==
           "grant_type=authorization_code&code=c&redirect_uri=https%3A%2F%2Fa%2Fcb&code_verifier=v" +
           "&client_id=id&client_secret=sec");
    // A public client (no secret) names itself in the body.
    assert(strings.has_suffix(code_body("c", "https://a/cb", "v", "id", "", false), "&client_id=id"));
    assert(refresh_body("rt", ["a", "b"], "id", "s", false) == "grant_type=refresh_token&refresh_token=rt&scope=a+b");
    assert(basic_auth("my id", "p:w") == "Basic " + encoding.base64_encode(to_bytes("my+id:p%3Aw")));
}

fn test_token_replies() {
    let t = parse_tokens("{\"access_token\":\"at\",\"token_type\":\"bearer\",\"expires_in\":3600," +
                         "\"refresh_token\":\"rt\",\"id_token\":\"a.b.c\",\"scope\":\"openid\"}");
    guard let ok_t = t else let e = err_of(t) { panic(e); }
    assert(ok_t.access_token == "at" && ok_t.expires_in == 3600 && ok_t.refresh_token == "rt" &&
           ok_t.id_token == "a.b.c" && ok_t.scope == "openid");
    let s = parse_tokens("{\"access_token\":\"at\",\"token_type\":\"Bearer\",\"expires_in\":\"60\"}");
    assert((s ?? ok_t).expires_in == 60);
    let bare = parse_tokens("{\"access_token\":\"at\",\"token_type\":\"Bearer\"}");
    assert((bare ?? ok_t).expires_in == 0 && (bare ?? ok_t).refresh_token == "");
    assert(strings.contains(refused_tokens("{\"access_token\":\"at\",\"token_type\":\"mac\"}"), "not Bearer"));
    assert(strings.contains(refused_tokens("{\"access_token\":\"\",\"token_type\":\"Bearer\"}"), "no access_token"));
    assert(strings.contains(refused_tokens("{\"access_token\":\"a\",\"token_type\":\"Bearer\",\"expires_in\":\"x\"}"),
                            "expires_in"));
    assert(strings.contains(refused_tokens("{\"access_token\":\"a\",\"token_type\":\"Bearer\",\"expires_in\":-5}"),
                            "negative"));
    refused_tokens("not json");
}

fn test_error_replies() {
    let e = parse_error("{\"error\":\"invalid_grant\",\"error_description\":\"code expired\"}");
    guard let er = e else { panic("no error parsed"); }
    assert(er.code == "invalid_grant" && er.description == "code expired");
    let bare = parse_error("{\"error\":\"access_denied\"}");
    assert((bare ?? er).description == "");
    let none_1 = parse_error("{\"access_token\":\"x\"}");
    guard let _x = none_1 else { return; }
    panic("a token reply read as an error");
}

fn discovery_doc(issuer: str, extra: str) -> str {
    return "{\"issuer\":\"" + issuer + "\",\"authorization_endpoint\":\"https://id.example.com/authorize\"," +
        "\"token_endpoint\":\"https://id.example.com/token\",\"jwks_uri\":\"https://id.example.com/jwks\"" + extra + "}";
}

fn test_discovery_checks_issuer_and_endpoints() {
    assert(discovery_url("https://id.example.com/") == "https://id.example.com/.well-known/openid-configuration");
    assert(discovery_url("https://id.example.com/realms/x") ==
           "https://id.example.com/realms/x/.well-known/openid-configuration");
    let r = parse_discovery(discovery_doc("https://id.example.com",
        ",\"userinfo_endpoint\":\"https://id.example.com/me\",\"code_challenge_methods_supported\":[\"plain\",\"S256\"]," +
        "\"token_endpoint_auth_methods_supported\":[\"client_secret_post\"]"), "https://id.example.com", false);
    guard let d = r else let e = err_of(r) { panic(e); }
    assert(d.token_endpoint == "https://id.example.com/token" && d.userinfo_endpoint == "https://id.example.com/me" &&
           d.secret_in_body);
    // Every problem at once: wrong issuer, no S256.
    let bad = parse_discovery(discovery_doc("https://evil.example.com",
        ",\"code_challenge_methods_supported\":[\"plain\"]"), "https://id.example.com", false);
    guard let _b = bad else let e = err_of(bad) {
        assert(strings.contains(e, "issuer is \"https://evil.example.com\"") && strings.contains(e, "S256"), e);
        return;
    }
    panic("accepted a mismatched issuer");
}

fn test_urls_must_be_https() {
    assert(url_problem("https://id.example.com/token", false) == "");
    assert(url_problem("http://localhost:8080/token", true) == "");
    assert(url_problem("http://[::1]:8080/token", true) == "");
    assert(url_problem("http://127.0.0.1/token", true) == "");
    assert(url_problem("http://localhost:8080/token", false) != "");
    assert(url_problem("http://localhost.evil.com/token", true) != "");
    assert(url_problem("http://127.0.0.1.evil.com/", true) != "");
    for u in ["", "ftp://x/y", "https://", "https://a b/", "https://id.example.com/#x",
              "https://user@id.example.com/", "//id.example.com"] {
        assert(url_problem(u, true) != "", u);
    }
}

fn test_return_paths_stay_on_site() {
    assert(safe_return("/account?tab=1") == "/account?tab=1");
    for p in ["", "https://evil.example", "//evil.example", "/\\evil.example", "account", "/a\nb", "/a\\b"] {
        assert(safe_return(p) == "/", p);
    }
}
