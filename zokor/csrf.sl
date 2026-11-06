// Cross-site request forgery.
//
// A browser attaches cookies to a request whichever site caused it, so a
// page elsewhere can make a logged-in user's browser POST here. SameSite
// cookies stop most of that; this stops the rest, and it needs nothing
// from your pages, because browsers now say where a request came from:
//
//     let g = zokor.csrf_guard([]);          // err for a malformed origin
//     fn csrf(c: zokor.Ctx[App]) -> opt[http.Response] {
//         return zokor.csrf_check(c, c.state.csrf);
//     }
//     r.before(csrf);
//
// GET, HEAD and OPTIONS pass: they must not change anything. For the
// rest, in order:
//
//   - Sec-Fetch-Site, set by every current browser and unforgeable from a
//     page: same-origin and none (the user typed it) pass;
//   - a listed origin passes, for a frontend on another origin;
//   - with no Sec-Fetch-Site, an Origin matching the Host passes;
//   - with neither header it is not a browser, so there is no ambient
//     cookie to abuse, and it passes: API clients keep working.
//
// Anything else is a 403 `csrf_rejected`. This protects cookie-based
// auth; a bearer token is not sent by a browser unasked. Behind a proxy
// that rewrites Host, list your public origin.
//
// For clients that send neither header, or as a second layer, a session
// also carries a token to send back in a form or a header:
// csrf_token_ok (sessions.sl).

import "http";
import "strings";

pub gc struct CsrfGuard {
    trusted: map[str]bool,
}

// A guard that also accepts these origins, like https://app.example.com.
// err naming every malformed one.
pub fn csrf_guard(origins: [str]) -> result[CsrfGuard, str] {
    let trusted: map[str]bool = {};
    let out: [str] = [];
    for o in origins {
        let why = origin_problem(o);
        if len(why) > 0 {
            push(out, "origin '" + o + "' " + why);
        }
        trusted[o] = true;
    }
    if len(out) > 0 {
        return err(strings.join(out, "; "));
    }
    return ok(CsrfGuard { trusted: trusted });
}

// CSRF_TRUSTED_ORIGINS, comma separated. A malformed origin is a config
// problem at startup, like any other.
pub fn csrf_guard_from(cfg: Config) -> CsrfGuard {
    let r = csrf_guard(comma_list(str_or(cfg, "CSRF_TRUSTED_ORIGINS", "")));
    guard let g = r else let e = err_of(r) {
        record(cfg, "CSRF_TRUSTED_ORIGINS", "", e);
        let nothing: map[str]bool = {};
        return CsrfGuard { trusted: nothing };
    }
    return g;
}

fn csrf_safe_method(m: str) -> bool {
    return m == "GET" || m == "HEAD" || m == "OPTIONS";
}

// The part of an origin after the scheme, or "" when it has no scheme.
fn origin_authority(origin: str) -> str {
    let parts = strings.split(origin, "://");
    if len(parts) != 2 {
        return "";
    }
    return parts[1];
}

// Whether this request may go on. Pure, so every rule has a test.
fn csrf_allows(g: CsrfGuard, method: str, fetch_site: str, origin: str, host: str) -> bool {
    if csrf_safe_method(method) {
        return true;
    }
    if fetch_site == "same-origin" || fetch_site == "none" {
        return true;
    }
    if len(origin) > 0 && has(g.trusted, origin) {
        return true;
    }
    if len(fetch_site) > 0 {
        return false;
    }
    if len(origin) == 0 {
        return true;
    }
    return len(host) > 0 && strings.to_lower(origin_authority(origin)) == strings.to_lower(host);
}

// For a `before`: none to go on, or the 403.
pub fn csrf_check[S](c: Ctx[S], g: CsrfGuard) -> opt[http.Response] {
    if csrf_allows(g, c.method_str(), c.header("sec-fetch-site"), c.header("origin"),
                   c.header("host")) {
        return none;
    }
    return some(respond(c.errors, "csrf_rejected", c.request_id));
}
