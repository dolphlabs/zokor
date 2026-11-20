import "crypto";
import "encoding";
import "http";
import "internal/path";
import "jwt";
import "strings";
import "time";

// A provider's token endpoint on a loopback port: it records each request
// (head and body) and answers every one with the same status and body.
gc struct FakeProvider {
    port: int,
    status: int,
    body: str,
    requests: [str],
    done: chan[bool],
}

fn ofdl() -> until { return until_of(time.mono() + 5000000000); }

fn provider_reply(status: int, body: str, conns: int) -> FakeProvider {
    let reqs: [str] = [];
    let p = FakeProvider { port: 0, status: status, body: body, requests: reqs, done: make_chan(conns) };
    let lr = link_listen(0);
    guard let ln = lr else let e = err_of(lr) { panic("listen: " + to_str(e)); }
    p.port = ln.port();
    spawn serve_provider(p, ln, conns);
    return p;
}

fn op_send(c: &mut link, s: str) {
    let data = to_bytes(s);
    let a = arena_new(len(data) + 64);
    let out = a.wire(len(data));
    for i in 0..len(data) {
        out[i] = data[i];
    }
    let _w = c.send(out, ofdl());
}

// One whole request: the head up to the blank line and Content-Length
// bytes of body.
fn op_request(c: &mut link) -> str {
    let got: bytes = b"";
    while true {
        let text = to_str(got);
        let end = strings.find(text, "\r\n\r\n");
        if end >= 0 {
            let want = 0;
            for line in strings.split(strings.slice(text, 0, end), "\r\n") {
                if strings.has_prefix(strings.to_lower(line), "content-length:") {
                    want = parse_int_or(strings.trim(strings.slice(line, 15, len(line))), 0);
                }
            }
            if len(got) >= end + 4 + want {
                return text;
            }
        }
        let a = arena_new(16384);
        let buf = a.wire(8192);
        let rr = c.recv(buf, ofdl());
        guard let n = rr else { return to_str(got); }
        if n == 0 {
            return to_str(got);
        }
        got = got + to_bytes(buf[0..n]);
    }
    return "";
}

fn parse_int_or(s: str, fallback: int) -> int {
    let n = 0;
    if len(s) == 0 {
        return fallback;
    }
    for c in to_bytes(s) {
        if c < 48 || c > 57 {
            return fallback;
        }
        n = n * 10 + (c as int) - 48;
    }
    return n;
}

fn serve_provider(p: FakeProvider, ln: link, conns: int) {
    let l = ln;
    for _i in 0..conns {
        let ar = l.accept(ofdl());
        guard let c = ar else { chan_send(p.done, false); return; }
        push(p.requests, op_request(&mut c));
        op_send(&mut c, "HTTP/1.1 " + to_str(p.status) + " X\r\nContent-Type: application/json\r\n" +
                "Content-Length: " + to_str(len(p.body)) + "\r\nConnection: close\r\n\r\n" + p.body);
        chan_send(p.done, true);
    }
}

gc struct OAState { o: OAuth }

fn oa_keys(list: [str]) -> CookieKeys {
    let r = cookie_keys(list);
    guard let k = r else let e = err_of(r) { panic(e); }
    return k;
}

fn oa_key_a() -> str { return "kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk"; }
fn oa_key_b() -> str { return "llllllllllllllllllllllllllllllllllllllll"; }

fn oa_provider(token_port: int) -> OAuth {
    let r = oauth_provider("test", "app-1", "s3cret", "https://id.example.com/authorize",
                           "http://127.0.0.1:" + to_str(token_port) + "/token",
                           "https://app.example.com/cb", ["read"], oa_keys([oa_key_a()]));
    guard let o = r else let e = err_of(r) { panic(e); }
    return o;
}

fn oa_login(c: Ctx[OAState]) -> http.Response {
    let r = oauth_start(c, c.state.o, c.query("next"));
    guard let resp = r else let e = err_of(r) { return text(500, e); }
    return resp;
}

fn oa_callback(c: Ctx[OAState]) -> http.Response {
    let r = oauth_finish(c, c.state.o);
    guard let login = r else let e = err_of(r) { return text(401, e.code + ": " + e.detail); }
    let resp = text(200, "sub=" + login.subject + " email=" + login.email + " name=" + login.name +
                    " at=" + login.tokens.access_token + " rt=" + login.tokens.refresh_token +
                    " exp=" + to_str(login.tokens.expires_in) + " to=" + login.return_to);
    return oauth_done(resp, c.state.o);
}

fn oa_router(o: OAuth) -> Router[OAState] {
    let r = new_router(OAState { o: o });
    r.get("/login", oa_login);
    r.get("/cb", oa_callback);
    return r;
}

// The authorization redirect and the cookie value it set.
struct Started { location: str, cookie: str }

fn start(r: Router[OAState], next: str) -> Started {
    let resp = r.serve(get_request("/login?next=" + encoding.url_encode(next)).build());
    assert(resp_status(resp) == 302, resp_text(resp));
    let sc = resp_header(resp, "set-cookie");
    let semi = strings.find(sc, ";");
    return Started { location: resp.location, cookie: strings.slice(sc, 0, semi) };
}

fn qparam(url: str, name: str) -> str {
    return path.query_get(path.query_of(url), name);
}

fn callback(r: Router[OAState], s: Started, query: str) -> http.Response {
    return r.serve(get_request("/cb?" + query).header("Cookie", s.cookie).build());
}

fn test_oauth_start_redirects_with_pkce_and_a_sealed_cookie() {
    let r = oa_router(oa_provider(1));
    let resp = r.serve(get_request("/login?next=%2Fdocs%3Fp%3D2").build());
    assert(resp_status(resp) == 302);
    let loc = resp.location;
    assert(strings.has_prefix(loc, "https://id.example.com/authorize?response_type=code&client_id=app-1" +
           "&redirect_uri=https%3A%2F%2Fapp.example.com%2Fcb&state="), loc);
    assert(qparam(loc, "code_challenge_method") == "S256" && len(qparam(loc, "code_challenge")) == 43);
    assert(qparam(loc, "scope") == "read" && qparam(loc, "nonce") == "", "no nonce without an issuer");
    assert(resp_header(resp, "cache-control") == "no-store");
    let sc = resp_header(resp, "set-cookie");
    assert(strings.has_prefix(sc, "__Host-zk_oauth_test=") && strings.contains(sc, "; Path=/; Max-Age=600;") &&
           strings.has_suffix(sc, "; Secure; HttpOnly; SameSite=Lax"), sc);
    // The cookie holds the verifier and state, sealed: neither is readable.
    assert(!strings.contains(sc, qparam(loc, "state")));
    // Two starts never share a state.
    let again = start(r, "/");
    assert(qparam(again.location, "state") != qparam(loc, "state"));
}

fn test_oauth_finish_exchanges_the_code_with_the_verifier() {
    let p = provider_reply(200, "{\"access_token\":\"at-1\",\"token_type\":\"Bearer\",\"expires_in\":3600," +
                           "\"refresh_token\":\"rt-1\"}", 1);
    let r = oa_router(oa_provider(p.port));
    let s = start(r, "/docs?p=2");
    let resp = callback(r, s, "code=c%2F1&state=" + qparam(s.location, "state"));
    assert(chan_recv(p.done) ?? false);
    assert(resp_text(resp) == "sub= email= name= at=at-1 rt=rt-1 exp=3600 to=/docs?p=2", resp_text(resp));
    // The flow cookie is deleted on the way out.
    assert(strings.has_prefix(resp_header(resp, "set-cookie"), "__Host-zk_oauth_test=; Path=/; Max-Age=0;"),
           resp_header(resp, "set-cookie"));
    let req = p.requests[0];
    assert(strings.has_prefix(req, "POST /token HTTP/1.1\r\n"), req);
    assert(strings.contains(strings.to_lower(req), "authorization: basic " +
           strings.to_lower(encoding.base64_encode(to_bytes("app-1:s3cret")))), req);
    let body = strings.slice(req, strings.find(req, "\r\n\r\n") + 4, len(req));
    assert(strings.has_prefix(body, "grant_type=authorization_code&code=c%2F1&redirect_uri=" +
           "https%3A%2F%2Fapp.example.com%2Fcb&code_verifier="), body);
    // The verifier sent is the one whose S256 the provider was shown.
    let verifier = path.query_get(body, "code_verifier");
    assert(crypto_challenge(verifier) == qparam(s.location, "code_challenge"));
}

fn crypto_challenge(v: str) -> str {
    return strings.replace(encoding.base64url_encode(crypto.sha256(to_bytes(v))), "=", "");
}

fn test_oauth_finish_refuses_a_forged_or_missing_flow() {
    let r = oa_router(oa_provider(1));
    let s = start(r, "/");
    let state = qparam(s.location, "state");
    // Another browser's state.
    assert(strings.has_prefix(resp_text(callback(r, s, "code=c&state=" + state + "x")), "state_mismatch"));
    assert(strings.has_prefix(resp_text(callback(r, s, "code=c")), "state_mismatch"));
    // No cookie, or one with a byte changed.
    let none_ck = r.serve(get_request("/cb?code=c&state=" + state).build());
    assert(strings.has_prefix(resp_text(none_ck), "flow_missing"), resp_text(none_ck));
    let eq = strings.find(s.cookie, "=");
    let v = strings.slice(s.cookie, eq + 1, len(s.cookie));
    let flipped = "A";
    if strings.has_prefix(v, "A") {
        flipped = "B";
    }
    let bad = Started { location: s.location, cookie: "__Host-zk_oauth_test=" + flipped + strings.slice(v, 1, len(v)) };
    assert(strings.has_prefix(resp_text(callback(r, bad, "code=c&state=" + state)), "flow_missing"));
    // A cookie sealed for another provider name does not open here.
    let other = oa_provider(1);
    other.name = "other";
    let r2 = oa_router(other);
    let moved = Started { location: s.location, cookie: "__Host-zk_oauth_other=" + v };
    assert(strings.has_prefix(resp_text(callback(r2, moved, "code=c&state=" + state)), "flow_missing"));
    // The provider's own error comes back as its code.
    let denied = callback(r, s, "error=access_denied&error_description=user+said+no&state=" + state);
    assert(resp_text(denied) == "access_denied: user said no", resp_text(denied));
}

fn test_oauth_flow_expires_and_survives_key_rotation() {
    let o = oa_provider(1);
    o.flow_ttl = -1;
    let r = oa_router(o);
    let s = start(r, "/");
    assert(strings.has_prefix(resp_text(callback(r, s, "code=c&state=" + qparam(s.location, "state"))),
                              "flow_expired"));
    // Sealed under key a, opened after b was put in front of it.
    let p = provider_reply(200, "{\"access_token\":\"at\",\"token_type\":\"Bearer\"}", 1);
    let old = oa_router(oa_provider(p.port));
    let s2 = start(old, "/");
    let rotated = oa_provider(p.port);
    rotated.keys = oa_keys([oa_key_b(), oa_key_a()]);
    let resp = callback(oa_router(rotated), s2, "code=c&state=" + qparam(s2.location, "state"));
    assert(chan_recv(p.done) ?? false);
    assert(strings.has_prefix(resp_text(resp), "sub= email= name= at=at "), resp_text(resp));
}

fn test_oauth_token_errors_carry_the_providers_code() {
    let p = provider_reply(400, "{\"error\":\"invalid_grant\",\"error_description\":\"code used\"}", 1);
    let r = oa_router(oa_provider(p.port));
    let s = start(r, "/");
    assert(resp_text(callback(r, s, "code=c&state=" + qparam(s.location, "state"))) == "invalid_grant: code used");
    // GitHub's shape: 200 with an error body.
    let gh = provider_reply(200, "{\"error\":\"bad_verification_code\"}", 1);
    let r2 = oa_router(oa_provider(gh.port));
    let s2 = start(r2, "/");
    assert(strings.has_prefix(resp_text(callback(r2, s2, "code=c&state=" + qparam(s2.location, "state"))),
                              "bad_verification_code"));
    let junk = provider_reply(502, "<html>bad gateway</html>", 1);
    let r3 = oa_router(oa_provider(junk.port));
    let s3 = start(r3, "/");
    assert(resp_text(callback(r3, s3, "code=c&state=" + qparam(s3.location, "state"))) == "token_reply: HTTP 502");
}

fn test_oauth_refresh_sends_the_refresh_grant() {
    let p = provider_reply(200, "{\"access_token\":\"at-2\",\"token_type\":\"Bearer\",\"refresh_token\":\"rt-2\"}", 1);
    let o = oa_provider(p.port);
    o.secret_in_body = true;
    let rr = oauth_refresh(o, "rt-1", []);
    guard let t = rr else let e = err_of(rr) { panic(e.code + ": " + e.detail); }
    assert(t.access_token == "at-2" && t.refresh_token == "rt-2");
    let req = p.requests[0];
    assert(!strings.contains(strings.to_lower(req), "authorization:"), req);
    assert(strings.has_suffix(req, "\r\n\r\ngrant_type=refresh_token&refresh_token=rt-1&client_id=app-1&client_secret=s3cret"),
           req);
    let empty = oauth_refresh(o, "", []);
    guard let _e = empty else let e = err_of(empty) { assert(e.code == "invalid_request"); return; }
    panic("refreshed without a token");
}

// ---- OpenID Connect ----------------------------------------------------------------

struct TestIdClaims {
    iss: str,
    aud: str,
    sub: str,
    exp: int,
    iat: int,
    nonce: str,
    email: str,
    email_verified: bool,
    name: str,
}

fn oidc_key() -> jwt.Key {
    let sr = crypto.ed25519_generate();
    guard let seed = sr else let e = err_of(sr) { panic(e); }
    let kr = jwt.ed25519_private_key(seed, "k1");
    guard let k = kr else let e = err_of(kr) { panic(e); }
    return k;
}

fn oidc_provider_for(port: int, k: jwt.Key) -> OAuth {
    let o = oa_provider(port);
    o.issuer = "https://id.example.com";
    o.scopes = ["openid", "email"];
    let jr = jwt.new_jwks("https://id.example.com/jwks");
    guard let j = jr else let e = err_of(jr) { panic(e); }
    let pr = jwt.public_of(k);
    guard let pub_k = pr else let e = err_of(pr) { panic(e); }
    jwt.jwks_set_keys(j, [pub_k]);
    o.jwks = some(j);
    return o;
}

fn id_token(k: jwt.Key, c: TestIdClaims) -> str {
    let r = jwt.sign_with(c, k);
    guard let t = r else let e = err_of(r) { panic(e); }
    return t;
}

fn claims_for(nonce: str) -> TestIdClaims {
    let now = (time.wall() as int) / 1000000000;
    return TestIdClaims { iss: "https://id.example.com", aud: "app-1", sub: "user-42", exp: now + 300,
                          iat: now, nonce: nonce, email: "ada@example.com", email_verified: true, name: "Ada" };
}

// Starts a login, then answers its code with an ID token made from the
// claims `edit` returns for the login's nonce.
fn oidc_finish(k: jwt.Key, claims: TestIdClaims, use_nonce: bool, query_extra: str) -> str {
    let o = oidc_provider_for(1, k);
    let r = oa_router(o);
    let s = start(r, "/");
    let nonce = qparam(s.location, "nonce");
    assert(len(nonce) == 43 && qparam(s.location, "scope") == "openid email", s.location);
    let c = claims;
    if use_nonce {
        c.nonce = nonce;
    }
    let p = provider_reply(200, "{\"access_token\":\"at\",\"token_type\":\"Bearer\",\"id_token\":\"" +
                           id_token(k, c) + "\"}", 1);
    o.token_url = "http://127.0.0.1:" + to_str(p.port) + "/token";
    return resp_text(callback(r, s, "code=c&state=" + qparam(s.location, "state") + query_extra));
}

fn test_oidc_login_verifies_the_id_token() {
    let k = oidc_key();
    let got = oidc_finish(k, claims_for(""), true, "");
    assert(got == "sub=user-42 email=ada@example.com name=Ada at=at rt= exp=0 to=/", got);
    // An address the provider has not verified is not handed on.
    let unverified = claims_for("");
    unverified.email_verified = false;
    assert(strings.has_prefix(oidc_finish(k, unverified, true, ""), "sub=user-42 email= name=Ada"));
    // RFC 9207: the issuer the reply names must be ours.
    assert(strings.has_prefix(oidc_finish(k, claims_for(""), true, "&iss=https%3A%2F%2Fevil.example.com"),
                              "issuer_mismatch"));
    assert(strings.has_prefix(oidc_finish(k, claims_for(""), true, "&iss=https%3A%2F%2Fid.example.com"),
                              "sub=user-42"));
}

fn test_oidc_login_refuses_bad_id_tokens() {
    let k = oidc_key();
    // A replayed token: its nonce is another login's.
    assert(strings.has_prefix(oidc_finish(k, claims_for("other-nonce"), false, ""), "id_token"));
    let wrong_aud = claims_for("");
    wrong_aud.aud = "another-app";
    assert(strings.has_prefix(oidc_finish(k, wrong_aud, true, ""), "id_token"));
    let wrong_iss = claims_for("");
    wrong_iss.iss = "https://evil.example.com";
    assert(strings.has_prefix(oidc_finish(k, wrong_iss, true, ""), "id_token"));
    let expired = claims_for("");
    expired.exp = expired.iat - 600;
    assert(strings.has_prefix(oidc_finish(k, expired, true, ""), "id_token"));
    // Signed by a key the provider never published.
    let rogue = oidc_key();
    let o = oidc_provider_for(1, k);
    let r = oa_router(o);
    let s = start(r, "/");
    let c = claims_for(qparam(s.location, "nonce"));
    let p = provider_reply(200, "{\"access_token\":\"at\",\"token_type\":\"Bearer\",\"id_token\":\"" +
                           id_token(rogue, c) + "\"}", 1);
    o.token_url = "http://127.0.0.1:" + to_str(p.port) + "/token";
    assert(strings.has_prefix(resp_text(callback(r, s, "code=c&state=" + qparam(s.location, "state"))), "id_token"));
    // No ID token at all.
    let p2 = provider_reply(200, "{\"access_token\":\"at\",\"token_type\":\"Bearer\"}", 1);
    let s2 = start(r, "/");
    o.token_url = "http://127.0.0.1:" + to_str(p2.port) + "/token";
    assert(resp_text(callback(r, s2, "code=c&state=" + qparam(s2.location, "state"))) ==
           "id_token: the provider returned no ID token");
}

// ---- setup ------------------------------------------------------------------------

fn test_oauth_provider_names_every_problem() {
    let r = oauth_provider("bad name", "", "", "http://id.example.com/a", "ftp://x", "", ["a b"], oa_keys([oa_key_a()]));
    guard let _o = r else let e = err_of(r) {
        for want in ["name must be", "client id is empty", "authorize URL must use https", "token URL must be",
                     "redirect URL is missing", "scope \"a b\""] {
            assert(strings.contains(e, want), want + " in " + e);
        }
        return;
    }
    panic("accepted a bad provider");
}

fn test_oauth_from_config_reads_its_settings() {
    let vals: map[str]str = {};
    vals["OAUTH_GITHUB_CLIENT_ID"] = "gh-app";
    vals["OAUTH_GITHUB_CLIENT_SECRET"] = "gh-secret";
    vals["OAUTH_GITHUB_AUTHORIZE_URL"] = "https://github.com/login/oauth/authorize";
    vals["OAUTH_GITHUB_TOKEN_URL"] = "https://github.com/login/oauth/access_token";
    vals["OAUTH_GITHUB_USERINFO_URL"] = "https://api.github.com/user";
    vals["OAUTH_GITHUB_REDIRECT_URL"] = "https://app.example.com/auth/github/cb";
    vals["OAUTH_GITHUB_SCOPES"] = "read:user  user:email";
    let r = oauth_from_config(config_from_values(vals), "github", oa_keys([oa_key_a()]), ofdl());
    guard let o = r else let e = err_of(r) { panic(e); }
    assert(o.client_id == "gh-app" && o.userinfo_url == "https://api.github.com/user" && len(o.scopes) == 2 &&
           o.scopes[1] == "user:email" && o.issuer == "");
    let empty: map[str]str = {};
    let missing = oauth_from_config(config_from_values(empty), "google", oa_keys([oa_key_a()]), ofdl());
    guard let _m = missing else let e = err_of(missing) {
        assert(strings.contains(e, "OAUTH_GOOGLE_CLIENT_ID") && strings.contains(e, "OAUTH_GOOGLE_REDIRECT_URL") &&
               strings.contains(e, "OAUTH_GOOGLE_ISSUER"), e);
        return;
    }
    panic("configured from nothing");
}

fn test_oauth_start_needs_cookie_keys() {
    let o = oa_provider(1);
    o.keys = CookieKeys { keys: [] };
    let resp = oa_router(o).serve(get_request("/login").build());
    assert(resp_status(resp) == 500 && strings.contains(resp_text(resp), "COOKIE_KEYS"));
}
