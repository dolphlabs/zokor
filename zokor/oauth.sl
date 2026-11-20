// Sign in with an OAuth 2.0 or OpenID Connect provider: Google, Microsoft,
// GitHub, Okta, Auth0, Keycloak, or any other that speaks the
// authorization code flow.
//
// Two handlers, and zokor keeps everything between them:
//
//     fn login(c: zokor.Ctx[App]) -> http.Response {
//         return zokor.oauth_start(c, c.state.google, c.query("next")) ??
//             zokor.text(500, "login is not configured");
//     }
//
//     fn callback(c: zokor.Ctx[App]) -> http.Response {
//         let r = zokor.oauth_finish(c, c.state.google);
//         guard let login = r else let e = err_of(r) {
//             return zokor.text(401, "sign-in failed: " + e.code);
//         }
//         // login.subject is the provider's stable id for this user;
//         // start a session for it, then send the user on:
//         let resp = zokor.redirect(303, login.return_to);
//         return zokor.oauth_done(resp, c.state.google);
//     }
//
// oauth_start makes a fresh state, PKCE verifier (RFC 7636, S256) and
// OpenID nonce, seals them into a short-lived __Host- cookie with AES-GCM
// under a key derived from COOKIE_KEYS, and redirects to the provider.
// oauth_finish opens that cookie and checks it is unexpired and that the
// state matches, refuses an issuer mix-up (RFC 9207), exchanges the code
// with the verifier, and for OpenID Connect verifies the ID token (its
// signature against the provider's JWKS, issuer, audience, expiry and
// nonce) before it returns who signed in. Nothing in the URL or the
// cookie can be changed without the flow failing.
//
// Configuration, for a provider named "google":
//
//   OAUTH_GOOGLE_ISSUER        https://accounts.google.com (OpenID Connect:
//                              endpoints and keys come from discovery)
//   OAUTH_GOOGLE_AUTHORIZE_URL and OAUTH_GOOGLE_TOKEN_URL instead of an
//                              issuer, for plain OAuth 2.0 (GitHub)
//   OAUTH_GOOGLE_USERINFO_URL  optional; discovery fills it for OIDC
//   OAUTH_GOOGLE_CLIENT_ID, OAUTH_GOOGLE_CLIENT_SECRET (blank for a public
//                              client), OAUTH_GOOGLE_REDIRECT_URL (this
//                              app's callback, exactly as registered)
//   OAUTH_GOOGLE_SCOPES        space-separated; default "openid email
//                              profile" with an issuer, none without

import "crypto";
import "encoding";
import "http";
import "httpc";
import "internal/oauth" as oauthwire;
import "json";
import "jwt";
import "strings";
import "time";

pub gc struct OAuth {
    // Names the flow cookie: letters, digits, - and _.
    name: str,
    client_id: str,
    // "" for a public client, which proves itself with PKCE alone.
    client_secret: str,
    authorize_url: str,
    token_url: str,
    // "" when there is none; oauth_userinfo then refuses.
    userinfo_url: str,
    redirect_url: str,
    scopes: [str],
    // The OpenID issuer, "" for plain OAuth 2.0. With an issuer, every
    // login must carry an ID token that verifies against `jwks`.
    issuer: str,
    jwks: opt[jwt.Jwks],
    // client_secret_post rather than HTTP Basic (client_secret_basic).
    secret_in_body: bool,
    // Extra authorization parameters, such as prompt=consent.
    extra: [OAuthParam],
    keys: CookieKeys,
    // Seconds a user has to finish signing in at the provider.
    flow_ttl: int,
    // Nanoseconds for each call to the provider.
    timeout: int,
    http: httpc.Client,
}

pub struct OAuthParam { name: str, value: str }

pub struct OAuthTokens {
    access_token: str,
    // "" when the provider issued none.
    refresh_token: str,
    id_token: str,
    scope: str,
    // Seconds from issue; 0 when the provider did not say.
    expires_in: int,
}

// Who signed in. subject is the ID token's `sub` with OpenID Connect and
// "" with plain OAuth 2.0 (ask oauth_userinfo). email is only an address
// the provider has verified: unverified ones are left out, since anyone
// can type any address into a provider's sign-up form.
pub struct OAuthLogin {
    tokens: OAuthTokens,
    subject: str,
    email: str,
    name: str,
    // The path oauth_start was given, checked to stay on this site.
    return_to: str,
}

// code is the provider's own error code (access_denied,
// invalid_grant, ...) or one of zokor's: flow_missing (no or forged
// flow cookie), flow_expired, state_mismatch, issuer_mismatch,
// provider_unreachable, token_reply, id_token, userinfo. detail is for
// logs; it never contains a token or secret.
pub struct OAuthError { code: str, detail: str }

// The flow cookie's name before the provider's, and the largest reply
// read from a provider.
fn oauth_flow_prefix() -> str { return "__Host-zk_oauth_"; }
fn oauth_max_body() -> int { return 1048576; }

fn oauth_fail(code: str, detail: str) -> OAuthError {
    return OAuthError { code: code, detail: detail };
}

fn name_ok(n: str) -> bool {
    if len(n) == 0 || len(n) > 32 {
        return false;
    }
    for c in to_bytes(n) {
        let ok_c = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 45 || c == 95;
        if !ok_c {
            return false;
        }
    }
    return true;
}

// A plain OAuth 2.0 provider from its endpoints. URLs must be https, or
// http to localhost (a provider on the developer's machine). Every
// problem is reported at once.
pub fn oauth_provider(name: str, client_id: str, client_secret: str, authorize_url: str,
                      token_url: str, redirect_url: str, scopes: [str],
                      keys: CookieKeys) -> result[OAuth, str] {
    let problems: [str] = [];
    if !name_ok(name) {
        push(problems, "name must be 1-32 letters, digits, - or _");
    }
    if len(client_id) == 0 {
        push(problems, "client id is empty");
    }
    let urls: [OAuthParam] = [
        OAuthParam { name: "authorize URL", value: authorize_url },
        OAuthParam { name: "token URL", value: token_url },
        OAuthParam { name: "redirect URL", value: redirect_url }
    ];
    for u in urls {
        let why = oauthwire.url_problem(u.value, true);
        if len(why) > 0 {
            push(problems, u.name + " " + why);
        }
    }
    for s in scopes {
        if len(s) == 0 || strings.contains(s, " ") {
            push(problems, "scope " + json.encode(s) + " is empty or has a space; list scopes one each");
        }
    }
    if len(keys.keys) == 0 {
        push(problems, "no cookie keys to seal the login flow with: set COOKIE_KEYS");
    }
    if len(problems) > 0 {
        return err("oauth " + name + ": " + strings.join(problems, "; "));
    }
    let none_extra: [OAuthParam] = [];
    return ok(OAuth {
        name: name, client_id: client_id, client_secret: client_secret,
        authorize_url: authorize_url, token_url: token_url, userinfo_url: "",
        redirect_url: redirect_url, scopes: scopes, issuer: "", jwks: none,
        secret_in_body: false, extra: none_extra, keys: keys, flow_ttl: 600,
        timeout: 10000000000, http: httpc.new_client()
    });
}

// An OpenID Connect provider, its endpoints and signing keys found
// through discovery at `issuer` (which must be https). Scopes default to
// openid, email and profile; pass your own to change them, openid
// included.
pub fn oidc_provider(name: str, issuer: str, client_id: str, client_secret: str,
                     redirect_url: str, scopes: [str], keys: CookieKeys,
                     deadline: until) -> result[OAuth, str] {
    let why = oauthwire.url_problem(issuer, false);
    if len(why) > 0 {
        return err("oauth " + name + ": issuer " + why);
    }
    let resp_r = httpc.get(oauthwire.discovery_url(issuer), deadline);
    guard let resp = resp_r else let e = err_of(resp_r) {
        return err("oauth " + name + ": discovery: " + e);
    }
    if resp.status != 200 {
        return err("oauth " + name + ": discovery: HTTP " + to_str(resp.status));
    }
    if len(resp.body) > oauth_max_body() {
        return err("oauth " + name + ": discovery document is larger than 1 MB");
    }
    let dr = oauthwire.parse_discovery(to_str(resp.body), issuer, false);
    guard let d = dr else let e = err_of(dr) { return err("oauth " + name + ": " + e); }
    return oidc_with(name, d.issuer, d.authorization_endpoint, d.token_endpoint, d.userinfo_endpoint,
                     d.jwks_uri, d.secret_in_body, client_id, client_secret, redirect_url, scopes, keys);
}

fn oidc_with(name: str, issuer: str, authorize_url: str, token_url: str, userinfo_url: str,
             jwks_uri: str, secret_in_body: bool, client_id: str, client_secret: str,
             redirect_url: str, scopes: [str], keys: CookieKeys) -> result[OAuth, str] {
    let sc = scopes;
    if len(sc) == 0 {
        sc = ["openid", "email", "profile"];
    }
    let has_openid = false;
    for s in sc {
        if s == "openid" {
            has_openid = true;
        }
    }
    if !has_openid {
        return err("oauth " + name + ": an OpenID Connect provider needs the openid scope");
    }
    let jr = jwt.new_jwks(jwks_uri);
    guard let j = jr else let e = err_of(jr) { return err("oauth " + name + ": jwks_uri: " + e); }
    let r = oauth_provider(name, client_id, client_secret, authorize_url, token_url, redirect_url, sc, keys);
    guard let o = r else let e = err_of(r) { return err(e); }
    o.issuer = issuer;
    o.jwks = some(j);
    o.userinfo_url = userinfo_url;
    o.secret_in_body = secret_in_body;
    return ok(o);
}

// The provider `name` from OAUTH_<NAME>_* (see the top of this file):
// discovered when an issuer is set, else from its two endpoints. Every
// missing or bad setting is named.
pub fn oauth_from_config(cfg: Config, name: str, keys: CookieKeys,
                         deadline: until) -> result[OAuth, str] {
    let p = "OAUTH_" + strings.to_upper(strings.replace(name, "-", "_")) + "_";
    let issuer = str_or(cfg, p + "ISSUER", "");
    let client_id = str_or(cfg, p + "CLIENT_ID", "");
    let secret = str_or(cfg, p + "CLIENT_SECRET", "");
    let redirect_url = str_or(cfg, p + "REDIRECT_URL", "");
    let scopes: [str] = [];
    for s in strings.split(str_or(cfg, p + "SCOPES", ""), " ") {
        if len(s) > 0 {
            push(scopes, s);
        }
    }
    let missing: [str] = [];
    if len(client_id) == 0 {
        push(missing, p + "CLIENT_ID");
    }
    if len(redirect_url) == 0 {
        push(missing, p + "REDIRECT_URL");
    }
    let authorize_url = str_or(cfg, p + "AUTHORIZE_URL", "");
    let token_url = str_or(cfg, p + "TOKEN_URL", "");
    if len(issuer) == 0 && (len(authorize_url) == 0 || len(token_url) == 0) {
        push(missing, p + "ISSUER (or " + p + "AUTHORIZE_URL and " + p + "TOKEN_URL)");
    }
    if len(missing) > 0 {
        return err("oauth " + name + ": set " + strings.join(missing, ", "));
    }
    let ui = str_or(cfg, p + "USERINFO_URL", "");
    if len(ui) > 0 {
        let why = oauthwire.url_problem(ui, true);
        if len(why) > 0 {
            return err("oauth " + name + ": " + p + "USERINFO_URL " + why);
        }
    }
    if len(issuer) > 0 {
        return with_userinfo(oidc_provider(name, issuer, client_id, secret, redirect_url, scopes, keys,
                                           deadline), ui);
    }
    return with_userinfo(oauth_provider(name, client_id, secret, authorize_url, token_url, redirect_url,
                                        scopes, keys), ui);
}

fn with_userinfo(r: result[OAuth, str], url: str) -> result[OAuth, str] {
    guard let o = r else let e = err_of(r) { return err(e); }
    if len(url) > 0 {
        o.userinfo_url = url;
    }
    return ok(o);
}

// ---- the flow cookie ----------------------------------------------------------

struct Flow { s: str, v: str, n: str, r: str, t: int }

fn flow_cookie_name(o: OAuth) -> str {
    return oauth_flow_prefix() + o.name;
}

// One AES-256-GCM key per cookie key, so rotating COOKIE_KEYS rotates
// these too; HKDF keeps them apart from the keys' HMAC use.
fn flow_key(k: bytes) -> result[bytes, str] {
    return crypto.hkdf_sha256(k, b"", to_bytes("zokor oauth flow v1"), 32);
}

fn oauth_now() -> int {
    return (time.wall() as int) / 1000000000;
}

fn seal_flow(o: OAuth, f: Flow) -> result[str, str] {
    let kr = flow_key(o.keys.keys[0]);
    guard let k = kr else let e = err_of(kr) { return err(e); }
    let sr = crypto.seal(k, to_bytes(json.encode(f)), to_bytes(flow_cookie_name(o)));
    guard let sealed = sr else let e = err_of(sr) { return err(e); }
    return ok(strings.replace(encoding.base64url_encode(sealed), "=", ""));
}

fn open_flow(o: OAuth, raw: str) -> opt[Flow] {
    if len(raw) == 0 || len(raw) > 4096 {
        return none;
    }
    let pad = raw;
    while len(pad) % 4 != 0 {
        pad = pad + "=";
    }
    let br = encoding.base64url_decode(pad);
    guard let sealed = br else { return none; }
    for key in o.keys.keys {
        let kr = flow_key(key);
        guard let k = kr else { continue; }
        let pr = crypto.open(k, sealed, to_bytes(flow_cookie_name(o)));
        guard let plain = pr else { continue; }
        let fr: result[Flow, str] = json.decode(plain);
        guard let f = fr else { return none; }
        return some(f);
    }
    return none;
}

fn random_token(n: int) -> result[str, str] {
    let rr = crypto.rand(n);
    guard let b = rr else let e = err_of(rr) { return err(e); }
    return ok(oauthwire.token_of(b));
}

// ---- the two steps --------------------------------------------------------------

// Starts a sign-in: a redirect to the provider, with the flow cookie that
// oauth_finish needs. return_to is where to land afterwards, a path on
// this site ("/" when it is anything else).
pub fn oauth_start[S](c: Ctx[S], o: OAuth, return_to: str) -> result[http.Response, str] {
    if len(o.keys.keys) == 0 {
        return err("oauth " + o.name + ": no cookie keys to seal the login flow with: set COOKIE_KEYS");
    }
    let vr = crypto.rand(32);
    guard let vb = vr else let e = err_of(vr) { return err("oauth: random: " + e); }
    let verr = oauthwire.pkce_verifier(vb);
    guard let verifier = verr else let e = err_of(verr) { return err(e); }
    let sr = random_token(32);
    guard let state = sr else let e = err_of(sr) { return err("oauth: random: " + e); }
    let nonce = "";
    if len(o.issuer) > 0 {
        let nr = random_token(32);
        guard let n = nr else let e = err_of(nr) { return err("oauth: random: " + e); }
        nonce = n;
    }
    let extra: [oauthwire.Param] = [];
    for x in o.extra {
        push(extra, oauthwire.Param { name: x.name, value: x.value });
    }
    let ur = oauthwire.authorize_url(o.authorize_url, o.client_id, o.redirect_url, o.scopes, state,
                                     oauthwire.pkce_challenge(verifier), nonce, extra);
    guard let url = ur else let e = err_of(ur) { return err("oauth " + o.name + ": " + e); }
    let f = Flow { s: state, v: verifier, n: nonce, r: oauthwire.safe_return(return_to),
                   t: oauth_now() + o.flow_ttl };
    let cr = seal_flow(o, f);
    guard let sealed = cr else let e = err_of(cr) { return err("oauth: sealing the flow: " + e); }
    let ck = new_cookie(flow_cookie_name(o), sealed);
    ck.max_age = o.flow_ttl;
    // Lax, not Strict: the provider's redirect back is a cross-site
    // top-level GET, which Lax lets the cookie ride on.
    ck.same_site = SameSite.LAX;
    let resp = no_store(redirect(302, url));
    return set_cookie(resp, ck);
}

// Finishes a sign-in on the redirect URL's handler. Only the first call
// for a flow can succeed: the provider refuses a code twice, and
// oauth_done deletes the cookie.
pub fn oauth_finish[S](c: Ctx[S], o: OAuth) -> result[OAuthLogin, OAuthError] {
    let fo = open_flow(o, c.cookie(flow_cookie_name(o)));
    guard let f = fo else {
        return err(oauth_fail("flow_missing", "no valid login cookie; start the sign-in again"));
    }
    if oauth_now() > f.t {
        return err(oauth_fail("flow_expired", "the sign-in took longer than " + to_str(o.flow_ttl) + " seconds"));
    }
    let state = c.query("state");
    if !constant_time_equal(to_bytes(state), to_bytes(f.s)) {
        return err(oauth_fail("state_mismatch", "the state parameter does not match this browser's sign-in"));
    }
    // RFC 9207: a provider that names itself must be the one asked.
    let iss = c.query("iss");
    if len(iss) > 0 && len(o.issuer) > 0 && iss != o.issuer {
        return err(oauth_fail("issuer_mismatch", "the reply came from " + json.encode(iss)));
    }
    let provider_err = c.query("error");
    if len(provider_err) > 0 {
        return err(oauth_fail(provider_err, c.query("error_description")));
    }
    let code = c.query("code");
    if len(code) == 0 {
        return err(oauth_fail("invalid_request", "the redirect carries no code"));
    }
    let deadline = until_of(time.mono() + o.timeout);
    let body = oauthwire.code_body(code, o.redirect_url, f.v, o.client_id, o.client_secret, o.secret_in_body);
    let tr = token_request(o, body, deadline);
    guard let t = tr else let e = err_of(tr) { return err(e); }
    let login = OAuthLogin { tokens: t, subject: "", email: "", name: "", return_to: f.r };
    if len(o.issuer) == 0 {
        return ok(login);
    }
    return id_login(o, login, f.n, deadline);
}

// The ID token's claims zokor reads; your own come from
// jwt.verify_id_token_jwks on login.tokens.id_token.
struct IdClaims {
    sub: str,
    email: opt[str],
    email_verified: opt[bool],
    name: opt[str],
}

fn id_login(o: OAuth, login: OAuthLogin, nonce: str, deadline: until) -> result[OAuthLogin, OAuthError] {
    if len(login.tokens.id_token) == 0 {
        return err(oauth_fail("id_token", "the provider returned no ID token"));
    }
    guard let j = o.jwks else {
        return err(oauth_fail("id_token", "no JWKS to verify the ID token with"));
    }
    let rules = jwt.id_token_rules(o.issuer, o.client_id);
    rules.nonce = some(nonce);
    let vr: result[IdClaims, str] = jwt.verify_id_token_jwks(login.tokens.id_token, j, rules, oauth_now(), deadline);
    guard let claims = vr else let e = err_of(vr) { return err(oauth_fail("id_token", e)); }
    if len(claims.sub) == 0 {
        return err(oauth_fail("id_token", "the ID token has no subject"));
    }
    login.subject = claims.sub;
    if claims.email_verified ?? false {
        login.email = claims.email ?? "";
    }
    login.name = claims.name ?? "";
    return ok(login);
}

// `resp` with the flow cookie deleted: return it from the callback.
pub fn oauth_done(resp: http.Response, o: OAuth) -> http.Response {
    return clear_cookie(resp, flow_cookie_name(o), "/", "") ?? resp;
}

// Fresh tokens for a refresh token (RFC 6749 6). Scopes empty keeps the
// grant's. A provider may rotate the refresh token: store the new one when
// it is not "".
pub fn oauth_refresh(o: OAuth, refresh_token: str, scopes: [str]) -> result[OAuthTokens, OAuthError] {
    if len(refresh_token) == 0 {
        return err(oauth_fail("invalid_request", "no refresh token"));
    }
    let body = oauthwire.refresh_body(refresh_token, scopes, o.client_id, o.client_secret, o.secret_in_body);
    return token_request(o, body, until_of(time.mono() + o.timeout));
}

// The provider's user info for an access token, decoded as T: the
// OpenID userinfo endpoint, or a provider API such as GitHub's
// https://api.github.com/user (set userinfo_url).
pub fn oauth_userinfo[T](o: OAuth, access_token: str) -> result[T, OAuthError] {
    if len(o.userinfo_url) == 0 {
        return err(oauth_fail("userinfo", "oauth " + o.name + " has no userinfo URL"));
    }
    let req = httpc.new_request("GET", o.userinfo_url);
    req.headers["Authorization"] = "Bearer " + access_token;
    req.headers["Accept"] = "application/json";
    req.max_redirects = 0;
    let rr = httpc.client_send(o.http, req, until_of(time.mono() + o.timeout));
    guard let resp = rr else let e = err_of(rr) { return err(oauth_fail("provider_unreachable", e)); }
    if resp.status != 200 {
        return err(oauth_fail("userinfo", "HTTP " + to_str(resp.status)));
    }
    if len(resp.body) > oauth_max_body() {
        return err(oauth_fail("userinfo", "reply larger than 1 MB"));
    }
    let vr: result[T, str] = json.decode(resp.body);
    guard let v = vr else let e = err_of(vr) { return err(oauth_fail("userinfo", e)); }
    return ok(v);
}

fn token_request(o: OAuth, body: str, deadline: until) -> result[OAuthTokens, OAuthError] {
    let req = httpc.new_request("POST", o.token_url);
    req.headers["Content-Type"] = "application/x-www-form-urlencoded";
    // GitHub answers in form encoding without it.
    req.headers["Accept"] = "application/json";
    if !o.secret_in_body && len(o.client_secret) > 0 {
        req.headers["Authorization"] = oauthwire.basic_auth(o.client_id, o.client_secret);
    }
    req.body = to_bytes(body);
    req.max_redirects = 0;
    let rr = httpc.client_send(o.http, req, deadline);
    guard let resp = rr else let e = err_of(rr) { return err(oauth_fail("provider_unreachable", e)); }
    if len(resp.body) > oauth_max_body() {
        return err(oauth_fail("token_reply", "reply larger than 1 MB"));
    }
    let text = to_str(resp.body);
    // GitHub reports a bad code with 200 and an error body.
    if let pe = oauthwire.parse_error(text) {
        return err(oauth_fail(pe.code, pe.description));
    }
    if resp.status != 200 {
        return err(oauth_fail("token_reply", "HTTP " + to_str(resp.status)));
    }
    let tr = oauthwire.parse_tokens(text);
    guard let t = tr else let e = err_of(tr) { return err(oauth_fail("token_reply", e)); }
    return ok(OAuthTokens { access_token: t.access_token, refresh_token: t.refresh_token,
                            id_token: t.id_token, scope: t.scope, expires_in: t.expires_in });
}
