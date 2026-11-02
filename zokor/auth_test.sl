import "encoding";
import "http";
import "strings";
import "time";

struct AuClaims {
    sub: str,
    role: str,
    exp: int,
}

struct AuFull {
    sub: str,
    exp: int,
    nbf: int,
    aud: str,
    iss: str,
}

gc struct AuState {
    jwt: JwtAuth,
    keys: ApiKeys,
}

fn au_secret_a() -> str { return "secret-a-0123456789abcdef0123456789"; }
fn au_secret_b() -> str { return "secret-b-0123456789abcdef0123456789"; }

fn au_jwt(secrets: [str]) -> JwtAuth {
    let r = jwt_auth(secrets);
    guard let a = r else let e = err_of(r) { panic(e); }
    return a;
}

fn au_now() -> int {
    return (time.wall() as int) / 1000000000;
}

fn au_token(claims: AuClaims, a: JwtAuth) -> str {
    let r = sign_token(claims, a);
    guard let t = r else let e = err_of(r) { panic(e); }
    return t;
}

fn au_me(c: Ctx[AuState]) -> http.Response {
    let r: result[AuClaims, http.Response] = bearer_claims(c, c.state.jwt);
    guard let claims = r else let deny = err_of(r) {
        return deny;
    }
    return text(200, claims.sub + ":" + claims.role);
}

fn au_basic(c: Ctx[AuState]) -> http.Response {
    guard let creds = basic_credentials(c) else {
        return basic_denied(c, "admin \"area\"");
    }
    if !basic_matches(creds, "ops", "pa:ss word") {
        return basic_denied(c, "admin");
    }
    return text(200, "welcome " + creds.user);
}

fn au_api(c: Ctx[AuState]) -> http.Response {
    guard let client = api_key_client(c, c.state.keys) else {
        return respond(c.errors, "unauthorized", c.request_id);
    }
    return text(200, "client " + client);
}

fn au_router(a: JwtAuth) -> Router[AuState] {
    let kr = api_keys(["billing:bbbbbbbbbbbbbbbbbbbbbbbbbbbb", "search:ssssssssssssssssssssssssssss"]);
    guard let keys = kr else let e = err_of(kr) { panic(e); }
    let r = new_router(AuState { jwt: a, keys: keys });
    r.get("/me", au_me);
    r.get("/admin", au_basic);
    r.get("/api", au_api);
    return r;
}

fn au_get(r: Router[AuState], p: str, name: str, value: str) -> http.Response {
    let rq = get_request(p);
    if len(name) > 0 {
        rq = rq.header(name, value);
    }
    return r.serve(rq.build());
}

fn test_a_valid_token_yields_the_callers_claims() {
    let a = au_jwt([au_secret_a()]);
    let t = au_token(AuClaims { sub: "u_1", role: "admin", exp: au_now() + 60 }, a);
    let resp = au_get(au_router(a), "/me", "Authorization", "Bearer " + t);
    assert(resp_status(resp) == 200);
    assert(resp_text(resp) == "u_1:admin", resp_text(resp));
}

fn test_every_bad_token_is_the_same_401() {
    let a = au_jwt([au_secret_a()]);
    let r = au_router(a);
    let other = au_jwt([au_secret_b()]);
    let forged = au_token(AuClaims { sub: "u_1", role: "admin", exp: au_now() + 60 }, other);
    let expired = au_token(AuClaims { sub: "u_1", role: "admin", exp: au_now() - 120 }, a);
    for h in ["", "Bearer ", "Bearer not.a.token", "Bearer " + forged, "Bearer " + expired,
              "Basic dXNlcjpwYXNz"] {
        let resp = au_get(r, "/me", "Authorization", h);
        assert(resp_status(resp) == 401, h);
        assert(resp_header(resp, "www-authenticate") == "Bearer error=\"invalid_token\"", h);
        assert(!strings.contains(resp_text(resp), "expired"), "the reason stays on the server");
    }
}

fn test_token_problem_names_the_reason_for_logs() {
    let a = au_jwt([au_secret_a()]);
    let now = au_now();
    assert(token_problem("", a, now) == "no bearer token");
    let exp = au_token(AuClaims { sub: "u", role: "r", exp: now - 100 }, a);
    assert(token_problem(exp, a, now) == "expired");
    // within the leeway: still accepted
    let edge = au_token(AuClaims { sub: "u", role: "r", exp: now - 10 }, a);
    assert(token_problem(edge, a, now) == "");
    a.leeway = 0;
    assert(token_problem(edge, a, now) == "expired");
}

fn au_full_token(f: AuFull, a: JwtAuth) -> str {
    let r = sign_token(f, a);
    guard let t = r else let e = err_of(r) { panic(e); }
    return t;
}

fn test_nbf_audience_and_issuer_are_checked() {
    let a = au_jwt([au_secret_a()]);
    a.audience = "orders-api";
    a.issuer = "https://auth.example.com";
    let now = au_now();
    let good = AuFull { sub: "u", exp: now + 60, nbf: now - 1, aud: "orders-api",
                        iss: "https://auth.example.com" };
    assert(token_problem(au_full_token(good, a), a, now) == "");
    let early = AuFull { sub: "u", exp: now + 600, nbf: now + 300, aud: "orders-api",
                         iss: "https://auth.example.com" };
    assert(token_problem(au_full_token(early, a), a, now) == "not valid yet");
    let other_aud = AuFull { sub: "u", exp: now + 60, nbf: now, aud: "billing-api",
                             iss: "https://auth.example.com" };
    assert(token_problem(au_full_token(other_aud, a), a, now) == "wrong audience");
    let other_iss = AuFull { sub: "u", exp: now + 60, nbf: now, aud: "orders-api",
                             iss: "https://evil.example.com" };
    assert(token_problem(au_full_token(other_iss, a), a, now) == "wrong issuer");
}

fn test_secret_rotation() {
    let old = au_jwt([au_secret_a()]);
    let t = au_token(AuClaims { sub: "u", role: "r", exp: au_now() + 60 }, old);
    let rotated = au_jwt([au_secret_b(), au_secret_a()]);
    assert(token_problem(t, rotated, au_now()) == "", "an old token survives rotation");
    let retired = au_jwt([au_secret_b()]);
    assert(token_problem(t, retired, au_now()) != "", "a retired secret verifies nothing");
}

fn test_jwt_secrets_must_be_long_and_present() {
    let r = jwt_auth(["short"]);
    guard let _a = r else let e = err_of(r) {
        assert(strings.contains(e, "32 or more"), e);
        let c = cfg_of("JWT_SECRETS=\nJWT_LEEWAY=forever\n");
        let a = jwt_auth_from(c);
        assert(len(a.keys) == 0);
        assert(token_problem("x.y.z", a, 0) == "no JWT secret configured");
        let ck = check(c);
        guard let _ok = ck else let e2 = err_of(ck) {
            assert(strings.contains(e2, "JWT_SECRETS"), e2);
            return;
        }
        panic("a missing JWT_SECRETS was not reported");
    }
    panic("a 5-byte secret was accepted");
}

fn test_jwt_auth_from_config() {
    let c = cfg_of("JWT_SECRETS=" + au_secret_b() + "," + au_secret_a() +
                   "\nJWT_AUDIENCE=orders-api\nJWT_ISSUER=me\nJWT_LEEWAY=5\n");
    let a = jwt_auth_from(c);
    assert(len(a.keys) == 2 && a.audience == "orders-api" && a.issuer == "me" && a.leeway == 5);
    guard let _ok = check(c) else { panic("valid JWT settings reported as a problem"); }
}

fn au_basic_header(user_pass: str) -> str {
    return "Basic " + encoding.base64_encode(to_bytes(user_pass));
}

fn test_basic_auth() {
    let r = au_router(au_jwt([au_secret_a()]));
    let ok_resp = au_get(r, "/admin", "Authorization", au_basic_header("ops:pa:ss word"));
    assert(resp_text(ok_resp) == "welcome ops", "a colon in the password is kept");
    let wrong = au_get(r, "/admin", "Authorization", au_basic_header("ops:nope"));
    assert(resp_status(wrong) == 401);
    assert(resp_header(wrong, "www-authenticate") == "Basic realm=\"admin\", charset=\"UTF-8\"");
    let none_sent = au_get(r, "/admin", "", "");
    assert(resp_header(none_sent, "www-authenticate") == "Basic realm=\"admin 'area'\", charset=\"UTF-8\"",
           "a quote cannot break out of the realm");
    assert(resp_status(au_get(r, "/admin", "Authorization", "Basic !!!not-base64")) == 401);
    assert(resp_status(au_get(r, "/admin", "Authorization", au_basic_header("nocolon"))) == 401);
}

fn test_api_keys_name_the_client() {
    let r = au_router(au_jwt([au_secret_a()]));
    assert(resp_text(au_get(r, "/api", "X-Api-Key", "ssssssssssssssssssssssssssss")) == "client search");
    assert(resp_text(au_get(r, "/api", "X-Api-Key", "bbbbbbbbbbbbbbbbbbbbbbbbbbbb")) == "client billing");
    assert(resp_status(au_get(r, "/api", "X-Api-Key", "bbbbbbbbbbbbbbbbbbbbbbbbbbbX")) == 401);
    assert(resp_status(au_get(r, "/api", "", "")) == 401);
}

fn test_api_key_entries_are_checked() {
    let short = api_keys(["a:short"]);
    guard let _k = short else let e = err_of(short) {
        assert(strings.contains(e, "24 or more"), e);
        let nameless = api_keys(["0123456789abcdef0123456789"]);
        guard let _n = nameless else let e2 = err_of(nameless) {
            assert(strings.contains(e2, "name:key"), e2);
            return;
        }
        panic("an unnamed key was accepted");
    }
    panic("a short key was accepted");
}
