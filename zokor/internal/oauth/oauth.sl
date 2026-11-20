// OAuth 2.0 (RFC 6749) with PKCE (RFC 7636) and OpenID Connect discovery,
// as pure functions: URLs, form bodies, and the provider's JSON replies.
// No sockets, no clock, no randomness; the caller supplies all three.
import "crypto";
import "encoding";
import "json";
import "strings";

pub struct Param { name: str, value: str }

// ---- PKCE ---------------------------------------------------------------------

fn b64url(b: bytes) -> str {
    return strings.replace(encoding.base64url_encode(b), "=", "");
}

// A code verifier from 32 random bytes: 43 characters, inside RFC 7636's
// 43-128 and from its unreserved alphabet.
pub fn pkce_verifier(random: bytes) -> result[str, str] {
    if len(random) < 32 {
        return err("PKCE verifier needs 32 random bytes, got " + to_str(len(random)));
    }
    return ok(b64url(random));
}

// The S256 challenge for a verifier: BASE64URL(SHA256(verifier)).
pub fn pkce_challenge(verifier: str) -> str {
    return b64url(crypto.sha256(to_bytes(verifier)));
}

// A random value for state or nonce: base64url of the bytes, no padding.
pub fn token_of(random: bytes) -> str {
    return b64url(random);
}

// ---- URLs and bodies ----------------------------------------------------------

// application/x-www-form-urlencoded, in the order given.
pub fn form(params: [Param]) -> str {
    let out = "";
    for p in params {
        if len(out) > 0 {
            out = out + "&";
        }
        out = out + encoding.form_encode(p.name) + "=" + encoding.form_encode(p.value);
    }
    return out;
}

// The authorization request (RFC 6749 4.1.1 with RFC 7636 4.3). nonce ""
// sends none. `extra` is for provider parameters such as prompt or
// access_type; it cannot replace a parameter set here.
pub fn authorize_url(endpoint: str, client_id: str, redirect_uri: str, scopes: [str],
                     state: str, challenge: str, nonce: str, extra: [Param]) -> result[str, str] {
    if strings.contains(endpoint, "#") {
        return err("authorization endpoint has a fragment");
    }
    let ps: [Param] = [
        Param { name: "response_type", value: "code" },
        Param { name: "client_id", value: client_id },
        Param { name: "redirect_uri", value: redirect_uri },
        Param { name: "state", value: state },
        Param { name: "code_challenge", value: challenge },
        Param { name: "code_challenge_method", value: "S256" }
    ];
    if len(scopes) > 0 {
        push(ps, Param { name: "scope", value: strings.join(scopes, " ") });
    }
    if len(nonce) > 0 {
        push(ps, Param { name: "nonce", value: nonce });
    }
    for x in extra {
        for p in ps {
            if p.name == x.name {
                return err("authorize parameter " + x.name + " is set by zokor; drop it from extra");
            }
        }
        push(ps, x);
    }
    let sep = "?";
    if strings.contains(endpoint, "?") {
        sep = "&";
    }
    return ok(endpoint + sep + form(ps));
}

// The token request body for an authorization code (RFC 6749 4.1.3 with
// the PKCE verifier). client_id goes in the body only when the client
// does not authenticate with HTTP Basic.
pub fn code_body(code: str, redirect_uri: str, verifier: str, client_id: str,
                 client_secret: str, secret_in_body: bool) -> str {
    let ps: [Param] = [
        Param { name: "grant_type", value: "authorization_code" },
        Param { name: "code", value: code },
        Param { name: "redirect_uri", value: redirect_uri },
        Param { name: "code_verifier", value: verifier }
    ];
    return form(client_params(ps, client_id, client_secret, secret_in_body));
}

// The refresh request body (RFC 6749 6). scopes empty keeps the grant's.
pub fn refresh_body(refresh_token: str, scopes: [str], client_id: str,
                    client_secret: str, secret_in_body: bool) -> str {
    let ps: [Param] = [
        Param { name: "grant_type", value: "refresh_token" },
        Param { name: "refresh_token", value: refresh_token }
    ];
    if len(scopes) > 0 {
        push(ps, Param { name: "scope", value: strings.join(scopes, " ") });
    }
    return form(client_params(ps, client_id, client_secret, secret_in_body));
}

fn client_params(ps: [Param], client_id: str, client_secret: str, secret_in_body: bool) -> [Param] {
    if secret_in_body || len(client_secret) == 0 {
        push(ps, Param { name: "client_id", value: client_id });
        if len(client_secret) > 0 {
            push(ps, Param { name: "client_secret", value: client_secret });
        }
    }
    return ps;
}

// client_secret_basic (RFC 6749 2.3.1): both halves form-encoded first.
pub fn basic_auth(client_id: str, client_secret: str) -> str {
    let pair = encoding.form_encode(client_id) + ":" + encoding.form_encode(client_secret);
    return "Basic " + encoding.base64_encode(to_bytes(pair));
}

// ---- token replies ------------------------------------------------------------

pub struct Tokens {
    access_token: str,
    token_type: str,
    // Seconds from issue; 0 when the provider did not say.
    expires_in: int,
    refresh_token: str,
    scope: str,
    id_token: str,
}

struct ReplyInt {
    access_token: str,
    token_type: str,
    expires_in: opt[int],
    refresh_token: opt[str],
    scope: opt[str],
    id_token: opt[str],
}

// A few providers send expires_in as a string.
struct ReplyStr {
    access_token: str,
    token_type: str,
    expires_in: str,
    refresh_token: opt[str],
    scope: opt[str],
    id_token: opt[str],
}

// A successful token reply (RFC 6749 5.1). The token type must be Bearer:
// zokor sends tokens only that way.
pub fn parse_tokens(body: str) -> result[Tokens, str] {
    let t = Tokens { access_token: "", token_type: "", expires_in: 0, refresh_token: "",
                     scope: "", id_token: "" };
    let ri: result[ReplyInt, str] = json.decode(body);
    if let r = ri {
        t = Tokens { access_token: r.access_token, token_type: r.token_type,
                     expires_in: r.expires_in ?? 0, refresh_token: r.refresh_token ?? "",
                     scope: r.scope ?? "", id_token: r.id_token ?? "" };
    } else let e = err_of(ri) {
        let rs: result[ReplyStr, str] = json.decode(body);
        guard let r = rs else { return err("token reply: " + e); }
        let n = parse_int(r.expires_in);
        if n < 0 {
            return err("token reply: expires_in is not a number");
        }
        t = Tokens { access_token: r.access_token, token_type: r.token_type,
                     expires_in: n, refresh_token: r.refresh_token ?? "",
                     scope: r.scope ?? "", id_token: r.id_token ?? "" };
    }
    if len(t.access_token) == 0 {
        return err("token reply has no access_token");
    }
    if strings.to_lower(t.token_type) != "bearer" {
        return err("token type is " + json.encode(t.token_type) + ", not Bearer");
    }
    if t.expires_in < 0 {
        return err("token reply: expires_in is negative");
    }
    return ok(t);
}

fn parse_int(s: str) -> int {
    if len(s) == 0 || len(s) > 12 {
        return -1;
    }
    let n = 0;
    for c in to_bytes(s) {
        if c < 48 || c > 57 {
            return -1;
        }
        n = n * 10 + (c as int) - 48;
    }
    return n;
}

pub struct ErrorReply { code: str, description: str }

struct ErrBody { error: str, error_description: opt[str] }

// An error reply (RFC 6749 5.2), or none when the body is not one.
pub fn parse_error(body: str) -> opt[ErrorReply] {
    let r: result[ErrBody, str] = json.decode(body);
    guard let b = r else { return none; }
    if len(b.error) == 0 {
        return none;
    }
    return some(ErrorReply { code: b.error, description: b.error_description ?? "" });
}

// ---- discovery ----------------------------------------------------------------

pub struct Discovery {
    issuer: str,
    authorization_endpoint: str,
    token_endpoint: str,
    userinfo_endpoint: str,
    jwks_uri: str,
    // Whether the provider lists client_secret_basic; when it lists only
    // client_secret_post the secret goes in the body.
    secret_in_body: bool,
}

struct DiscoveryDoc {
    issuer: str,
    authorization_endpoint: str,
    token_endpoint: str,
    userinfo_endpoint: opt[str],
    jwks_uri: str,
    code_challenge_methods_supported: opt[[str]],
    token_endpoint_auth_methods_supported: opt[[str]],
}

// The well-known URL for an issuer (OpenID Connect Discovery 4).
pub fn discovery_url(issuer: str) -> str {
    let base = issuer;
    while strings.has_suffix(base, "/") {
        base = strings.slice(base, 0, len(base) - 1);
    }
    return base + "/.well-known/openid-configuration";
}

// A provider configuration document, checked: its issuer must be exactly
// the one asked for (Discovery 4.3, so one provider cannot speak for
// another), every endpoint must pass `url_ok`, and S256 must be offered
// when the provider lists its PKCE methods. Every problem is reported.
pub fn parse_discovery(body: str, issuer: str, loopback_http: bool) -> result[Discovery, str] {
    let r: result[DiscoveryDoc, str] = json.decode(body);
    guard let d = r else let e = err_of(r) { return err("discovery document: " + e); }
    let problems: [str] = [];
    if d.issuer != issuer {
        push(problems, "issuer is " + json.encode(d.issuer) + ", expected " + json.encode(issuer));
    }
    let named: [Param] = [
        Param { name: "authorization_endpoint", value: d.authorization_endpoint },
        Param { name: "token_endpoint", value: d.token_endpoint },
        Param { name: "jwks_uri", value: d.jwks_uri },
        Param { name: "userinfo_endpoint", value: d.userinfo_endpoint ?? "" }
    ];
    for p in named {
        if p.name == "userinfo_endpoint" && len(p.value) == 0 {
            continue;
        }
        let e = url_problem(p.value, loopback_http);
        if len(e) > 0 {
            push(problems, p.name + " " + e);
        }
    }
    if let ms = d.code_challenge_methods_supported {
        let s256 = false;
        for m in ms {
            if m == "S256" {
                s256 = true;
            }
        }
        if !s256 {
            push(problems, "provider does not offer PKCE S256");
        }
    }
    let in_body = false;
    if let am = d.token_endpoint_auth_methods_supported {
        let basic = false;
        let post = false;
        for m in am {
            if m == "client_secret_basic" {
                basic = true;
            }
            if m == "client_secret_post" {
                post = true;
            }
        }
        in_body = post && !basic;
    }
    if len(problems) > 0 {
        return err("discovery: " + strings.join(problems, "; "));
    }
    return ok(Discovery { issuer: d.issuer, authorization_endpoint: d.authorization_endpoint,
                          token_endpoint: d.token_endpoint,
                          userinfo_endpoint: d.userinfo_endpoint ?? "",
                          jwks_uri: d.jwks_uri, secret_in_body: in_body });
}

// "" when u is an absolute https URL with a host and no fragment, or
// http to a loopback host when loopback_http is set (a provider running
// on the developer's machine); otherwise what is wrong with it.
pub fn url_problem(u: str, loopback_http: bool) -> str {
    if len(u) == 0 {
        return "is missing";
    }
    if len(u) > 2048 {
        return "is longer than 2048 bytes";
    }
    for c in to_bytes(u) {
        if c <= 32 || c == 127 {
            return "has a space or control character";
        }
    }
    if strings.contains(u, "#") {
        return "has a fragment";
    }
    let rest = "";
    if strings.has_prefix(u, "https://") {
        rest = strings.slice(u, 8, len(u));
    } else if strings.has_prefix(u, "http://") {
        rest = strings.slice(u, 7, len(u));
        if !loopback_http || !is_loopback(host_of(rest)) {
            return "must use https (http is allowed only to localhost)";
        }
    } else {
        return "must be an absolute https URL";
    }
    let host = host_of(rest);
    if len(host) == 0 {
        return "has no host";
    }
    if strings.contains(host, "@") {
        return "has user info";
    }
    return "";
}

// The host[:port] of "host[:port]/path?query", lowercased.
fn host_of(rest: str) -> str {
    let end = len(rest);
    for sep in ["/", "?"] {
        let i = strings.find(rest, sep);
        if i >= 0 && i < end {
            end = i;
        }
    }
    return strings.to_lower(strings.slice(rest, 0, end));
}

fn is_loopback(hostport: str) -> bool {
    let h = hostport;
    if strings.has_prefix(h, "[") {
        let close = strings.find(h, "]");
        if close < 0 {
            return false;
        }
        return strings.slice(h, 1, close) == "::1";
    }
    let colon = strings.find(h, ":");
    if colon >= 0 {
        h = strings.slice(h, 0, colon);
    }
    return h == "localhost" || h == "127.0.0.1";
}

// ---- return paths -------------------------------------------------------------

// Where to send the user after login: a path on this site, never a URL
// that leaves it ("//evil.example" and "/\evil.example" are other hosts
// to a browser). Anything else becomes "/".
pub fn safe_return(path: str) -> str {
    if len(path) == 0 || len(path) > 2048 || !strings.has_prefix(path, "/") {
        return "/";
    }
    if strings.has_prefix(path, "//") || strings.has_prefix(path, "/\\") {
        return "/";
    }
    for c in to_bytes(path) {
        if c < 32 || c == 127 || c == 92 {
            return "/";
        }
    }
    return path;
}
