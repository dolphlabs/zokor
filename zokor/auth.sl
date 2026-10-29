// Authentication helpers: bearer JWTs, Basic credentials and API keys.
//
// Each answers one question -- who is this? -- and leaves the policy to
// the service. There are no closures, so the keys live in your state and
// a few-line `before` hands them over, the same shape as rate_limit:
//
//     gc struct App { jwt: zokor.JwtAuth }
//
//     struct Claims { sub: str, role: str }
//
//     fn require_user(c: zokor.Ctx[App]) -> opt[http.Response] {
//         let r: result[Claims, http.Response] = zokor.bearer_claims(c, c.state.jwt);
//         guard let claims = r else let deny = err_of(r) {
//             return some(deny);
//         }
//         c.set_local("user_id", claims.sub);
//         return none;
//     }
//
// JWTs are HS256 through dolphlabs/jwt: the MAC, the algorithm and
// duplicate claims are checked there, then `exp` (required), `nbf`, and
// -- when configured -- `aud` and `iss` here, with a leeway for clock
// skew. Every failure is the same 401 with
// `WWW-Authenticate: Bearer error="invalid_token"`: telling a client
// which check failed helps an attacker more than a user.

import "crypto";
import "encoding";
import "http";
import "json";
import "jwt";
import "strings";
import "time";

// ---- JWT --------------------------------------------------------------------

pub gc struct JwtAuth {
    // Newest first: the first signs, every one verifies, so a new secret
    // goes first and the old one stays until its tokens have expired.
    keys: [bytes],
    // "" skips the check; set them, so a token minted for another service
    // or by another issuer is refused.
    audience: str,
    issuer: str,
    // Seconds of clock skew allowed either side of exp and nbf.
    leeway: int,
}

// The claims zokor checks itself. Your own claims struct is decoded from
// the same verified payload; it does not need these fields.
struct StdClaims {
    exp: int,
    nbf: opt[int],
    aud: opt[str],
    iss: opt[str],
}

// Secrets of at least 32 bytes each, newest first.
pub fn jwt_auth(secrets: [str]) -> result[JwtAuth, str] {
    if len(secrets) == 0 {
        return err("no JWT secret: set JWT_SECRETS to one or more random strings of 32+ bytes");
    }
    let keys: [bytes] = [];
    for s in secrets {
        if len(s) < 32 {
            return err("a JWT secret is " + to_str(len(s)) +
                       " bytes; use 32 or more random bytes (openssl rand -base64 48)");
        }
        push(keys, to_bytes(s));
    }
    return ok(JwtAuth { keys: keys, audience: "", issuer: "", leeway: 30 });
}

// JWT_SECRETS (comma-separated, newest first), JWT_AUDIENCE, JWT_ISSUER and
// JWT_LEEWAY (seconds, default 30). Problems are recorded on `cfg`; the
// result then has no keys and refuses every token.
pub fn jwt_auth_from(cfg: Config) -> JwtAuth {
    let raw = str_or(cfg, "JWT_SECRETS", "");
    let r = jwt_auth(comma_list(raw));
    guard let a = r else let e = err_of(r) {
        record(cfg, "JWT_SECRETS", raw, e);
        return JwtAuth { keys: [], audience: "", issuer: "", leeway: 30 };
    }
    a.audience = str_or(cfg, "JWT_AUDIENCE", "");
    a.issuer = str_or(cfg, "JWT_ISSUER", "");
    let lw = str_or(cfg, "JWT_LEEWAY", "");
    if len(lw) > 0 {
        let pr = to_int(lw);
        if let n = pr {
            if n >= 0 && n <= 3600 {
                a.leeway = n;
            } else {
                record(cfg, "JWT_LEEWAY", lw, "must be 0-3600 seconds");
            }
        } else {
            record(cfg, "JWT_LEEWAY", lw, "must be a whole number of seconds");
        }
    }
    return a;
}

// A token for `claims`, signed with the newest key. The claims struct
// should carry `exp` (Unix seconds): bearer_claims refuses a token
// without one.
pub fn sign_token[T](claims: T, a: JwtAuth) -> result[str, str] {
    if len(a.keys) == 0 {
        return err("no JWT secret to sign with: set JWT_SECRETS");
    }
    return jwt.sign(claims, a.keys[0]);
}

fn now_unix() -> int {
    return (time.wall() as int) / 1000000000;
}

// Why `token` is not acceptable at `now`, or "" when it is. The reason
// is for logs and tests, never for the client.
pub fn token_problem(token: str, a: JwtAuth, now: int) -> str {
    if len(token) == 0 {
        return "no bearer token";
    }
    if len(a.keys) == 0 {
        return "no JWT secret configured";
    }
    let why = "signature does not match any key";
    for k in a.keys {
        let r: result[StdClaims, str] = jwt.verify(token, k);
        guard let std = r else let e = err_of(r) {
            why = e;
            continue;
        }
        if std.exp + a.leeway < now {
            return "expired";
        }
        let nbf = std.nbf ?? 0;
        if nbf > now + a.leeway {
            return "not valid yet";
        }
        if len(a.audience) > 0 && (std.aud ?? "") != a.audience {
            return "wrong audience";
        }
        if len(a.issuer) > 0 && (std.iss ?? "") != a.issuer {
            return "wrong issuer";
        }
        return "";
    }
    return why;
}

// The token's claims as your own type, once the token has passed every
// check; otherwise the 401 to send.
pub fn bearer_claims[S, T](c: Ctx[S], a: JwtAuth) -> result[T, http.Response] {
    let token = c.bearer();
    let why = token_problem(token, a, now_unix());
    if len(why) > 0 {
        return err(bearer_denied(c));
    }
    // The payload has been authenticated above; decode it into T.
    let parts = strings.split(token, ".");
    let body = encoding.base64url_decode(parts[1]);
    guard let payload = body else {
        return err(bearer_denied(c));
    }
    let r: result[T, str] = json.decode(to_str(payload));
    guard let claims = r else {
        return err(bearer_denied(c));
    }
    return ok(claims);
}

fn bearer_denied[S](c: Ctx[S]) -> http.Response {
    return http.with_header(respond(c.errors, "unauthorized", c.request_id),
                            "www-authenticate", "Bearer error=\"invalid_token\"");
}

// ---- Basic ------------------------------------------------------------------

pub gc struct BasicCredentials {
    user: str,
    password: str,
}

// The credentials of an `Authorization: Basic` header, or none when there
// is no such header or it does not decode to `user:password`.
pub fn basic_credentials[S](c: Ctx[S]) -> opt[BasicCredentials] {
    let h = c.header("authorization");
    if !strings.has_prefix(h, "Basic ") && !strings.has_prefix(h, "basic ") {
        return none;
    }
    let raw = encoding.base64_decode(strings.trim(strings.slice(h, 6, len(h))));
    guard let b = raw else {
        return none;
    }
    let text = to_str(b);
    let colon = strings.find(text, ":");
    if colon < 0 {
        return none;
    }
    return some(BasicCredentials {
        user: strings.slice(text, 0, colon),
        password: strings.slice(text, colon + 1, len(text))
    });
}

// Whether `got` is `user` / `password`. Both are compared as SHA-256
// digests in constant time, so neither their content nor their length
// leaks through timing.
pub fn basic_matches(got: BasicCredentials, user: str, password: str) -> bool {
    let u = constant_time_equal(crypto.sha256(to_bytes(got.user)), crypto.sha256(to_bytes(user)));
    let p = constant_time_equal(crypto.sha256(to_bytes(got.password)),
                                crypto.sha256(to_bytes(password)));
    return u && p;
}

// The 401 that asks a browser for Basic credentials for `realm`.
pub fn basic_denied[S](c: Ctx[S], realm: str) -> http.Response {
    return http.with_header(respond(c.errors, "unauthorized", c.request_id),
                            "www-authenticate", "Basic realm=\"" + clean_realm(realm) + "\", charset=\"UTF-8\"");
}

fn clean_realm(r: str) -> str {
    return strings.replace(strings.replace(r, "\"", "'"), "\\", "/");
}

// ---- API keys -----------------------------------------------------------------

pub gc struct ApiKeys {
    names: [str],
    // SHA-256 of each key: the keys themselves are not kept in memory.
    digests: [bytes],
}

// `name:key` entries; each key at least 24 bytes.
pub fn api_keys(entries: [str]) -> result[ApiKeys, str] {
    let names: [str] = [];
    let digests: [bytes] = [];
    for e in entries {
        let colon = strings.find(e, ":");
        if colon <= 0 {
            return err("an API key entry must be name:key, so a request can be traced to its client");
        }
        let name = strings.slice(e, 0, colon);
        let key = strings.slice(e, colon + 1, len(e));
        if len(key) < 24 {
            return err("API key '" + name + "' is " + to_str(len(key)) +
                       " bytes; use 24 or more random bytes");
        }
        push(names, name);
        push(digests, crypto.sha256(to_bytes(key)));
    }
    return ok(ApiKeys { names: names, digests: digests });
}

// API_KEYS: comma-separated `name:key` entries. Problems are recorded on
// `cfg`; the result then accepts no key.
pub fn api_keys_from(cfg: Config) -> ApiKeys {
    let raw = str_or(cfg, "API_KEYS", "");
    let r = api_keys(comma_list(raw));
    guard let k = r else let e = err_of(r) {
        record(cfg, "API_KEYS", raw, e);
        return ApiKeys { names: [], digests: [] };
    }
    return k;
}

// The name of the client whose key is in the X-Api-Key header, or none.
// Every stored key is compared, in constant time, whether or not an
// earlier one matched, so timing says nothing about which key -- or how
// much of one -- is right.
pub fn api_key_client[S](c: Ctx[S], keys: ApiKeys) -> opt[str] {
    let got = c.header("x-api-key");
    if len(got) == 0 {
        return none;
    }
    let d = crypto.sha256(to_bytes(got));
    let found = -1;
    let i = 0;
    while i < len(keys.digests) {
        if constant_time_equal(d, keys.digests[i]) && found < 0 {
            found = i;
        }
        i = i + 1;
    }
    if found < 0 {
        return none;
    }
    return some(keys.names[found]);
}
