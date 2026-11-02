// CORS.
//
// A browser lets a page on one origin read a response from another only
// when the response says so. Off by default; on with one call:
//
//     r.cors(zokor.cors_from(cfg));     // CORS_ORIGINS=https://app.example.com
//
// The router applies it, not a `before`: a preflight has to be answered
// for a route that has no OPTIONS handler, and every response -- the 404,
// the 422, the 500 after a panic -- needs the headers, or the browser
// shows the page a CORS error instead of the real one.
//
//   - A preflight (OPTIONS with Origin and Access-Control-Request-Method)
//     to a path that exists is answered 204 before routing, with the
//     allowed methods, headers and max-age.
//   - Any other request from an allowed origin gets
//     Access-Control-Allow-Origin: its own origin (or `*` when every origin
//     is allowed and credentials are not), plus credentials and exposed
//     headers when configured.
//   - `Vary: Origin` whenever the answer depends on the origin, so a shared
//     cache never hands one origin's answer to another.
//
// An origin that is not allowed gets no CORS headers at all: the response
// is still sent, and the browser withholds it from the page. That is the
// whole enforcement; CORS protects users' browsers, not the server, so it
// is no substitute for authentication.

import "http";
import "strings";

pub gc struct CorsPolicy {
    // Exact origins ("https://app.example.com"), subdomain patterns
    // ("https://*.example.com", any depth, never the bare domain), or "*"
    // alone for any origin. Empty: CORS is off.
    origins: [str],
    methods: [str],
    // Request headers a page may send; matched case-insensitively.
    headers: [str],
    // Response headers a page may read beyond the safelisted ones.
    expose: [str],
    credentials: bool,
    // How long a browser may cache a preflight, in seconds.
    max_age: int,
}

// Off: no origins. The other fields are the defaults `cors_policy` and
// `cors_from` start from.
pub fn no_cors() -> CorsPolicy {
    return CorsPolicy {
        origins: [],
        methods: ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"],
        headers: ["Content-Type", "Authorization", "X-Request-Id"],
        expose: ["X-Request-Id"],
        credentials: false,
        max_age: 600
    };
}

// The defaults, for these origins.
pub fn cors_policy(origins: [str]) -> CorsPolicy {
    let p = no_cors();
    p.origins = origins;
    return p;
}

// What is wrong with `p`, or "" when it is usable. Every problem is
// named, with the fix.
pub fn cors_problem(p: CorsPolicy) -> str {
    let out: [str] = [];
    let any = false;
    for o in p.origins {
        if o == "*" {
            any = true;
        } else {
            let why = origin_problem(o);
            if len(why) > 0 {
                push(out, "origin '" + o + "' " + why);
            }
        }
    }
    if any && len(p.origins) > 1 {
        push(out, "'*' allows every origin; list origins or use '*' alone");
    }
    if any && p.credentials {
        push(out, "credentials cannot be allowed for every origin ('*'): browsers refuse " +
                  "that combination; list the origins instead");
    }
    for m in p.methods {
        if !token_ok(m) {
            push(out, "method '" + m + "' is not a valid HTTP method token");
        }
    }
    for h in p.headers {
        if !token_ok(h) {
            push(out, "header '" + h + "' is not a valid header name");
        }
    }
    for h in p.expose {
        if !token_ok(h) {
            push(out, "exposed header '" + h + "' is not a valid header name");
        }
    }
    if p.max_age < 0 || p.max_age > 86400 {
        push(out, "max age must be 0-86400 seconds");
    }
    return strings.join(out, "; ");
}

// "" when `o` is scheme://host[:port] with nothing after it, else why not.
fn origin_problem(o: str) -> str {
    let sep = strings.find(o, "://");
    if sep <= 0 {
        return "must be scheme://host, e.g. https://app.example.com";
    }
    let scheme = strings.slice(o, 0, sep);
    if scheme != "https" && scheme != "http" {
        return "must start with https:// or http://";
    }
    let host = strings.slice(o, sep + 3, len(o));
    if len(host) == 0 {
        return "has no host";
    }
    if strings.contains(host, "/") || strings.contains(host, "?") ||
       strings.contains(host, "#") {
        return "must not have a path or a trailing slash: an Origin header never does";
    }
    if strings.has_prefix(host, "*.") {
        host = strings.slice(host, 2, len(host));
        if len(host) == 0 || strings.contains(host, "*") {
            return "has a bad wildcard: only a leading '*.' is allowed";
        }
    } else if strings.contains(host, "*") {
        return "has a bad wildcard: only a leading '*.' is allowed";
    }
    if strings.to_lower(o) != o {
        return "must be lower case, as browsers send it";
    }
    return "";
}

// An RFC 9110 token: what a method or a header name may be.
fn token_ok(s: str) -> bool {
    let b = to_bytes(s);
    if len(b) == 0 {
        return false;
    }
    for c in b {
        let x = c as int;
        let alnum = (x >= 48 && x <= 57) || (x >= 65 && x <= 90) || (x >= 97 && x <= 122);
        if !alnum && !tchar_symbol(x) {
            return false;
        }
    }
    return true;
}

fn tchar_symbol(x: int) -> bool {
    return x == 33 || x == 35 || x == 36 || x == 37 || x == 38 || x == 39 ||
           x == 42 || x == 43 || x == 45 || x == 46 || x == 94 || x == 95 ||
           x == 96 || x == 124 || x == 126;
}

// CORS_ORIGINS (comma-separated), CORS_METHODS, CORS_HEADERS, CORS_EXPOSE
// (comma-separated, replacing the defaults), CORS_CREDENTIALS
// (true/false) and CORS_MAX_AGE (seconds). Problems are recorded on `cfg`
// for check(cfg); a policy with problems comes back off.
pub fn cors_from(cfg: Config) -> CorsPolicy {
    let p = no_cors();
    p.origins = comma_list(str_or(cfg, "CORS_ORIGINS", ""));
    let m = comma_list(str_or(cfg, "CORS_METHODS", ""));
    if len(m) > 0 {
        let up: [str] = [];
        for x in m {
            push(up, strings.to_upper(x));
        }
        p.methods = up;
    }
    let h = comma_list(str_or(cfg, "CORS_HEADERS", ""));
    if len(h) > 0 {
        p.headers = h;
    }
    let e = comma_list(str_or(cfg, "CORS_EXPOSE", ""));
    if len(e) > 0 {
        p.expose = e;
    }
    let cr = strings.to_lower(str_or(cfg, "CORS_CREDENTIALS", ""));
    if cr == "true" || cr == "1" || cr == "yes" {
        p.credentials = true;
    } else if len(cr) > 0 && cr != "false" && cr != "0" && cr != "no" {
        record(cfg, "CORS_CREDENTIALS", cr, "must be true or false");
    }
    let ma = str_or(cfg, "CORS_MAX_AGE", "");
    if len(ma) > 0 {
        let pr = to_int(ma);
        if let n = pr {
            p.max_age = n;
        } else {
            record(cfg, "CORS_MAX_AGE", ma, "must be a whole number of seconds");
        }
    }
    let why = cors_problem(p);
    if len(why) > 0 {
        record(cfg, "CORS_ORIGINS", str_or(cfg, "CORS_ORIGINS", ""), why);
        return no_cors();
    }
    return p;
}

fn comma_list(s: str) -> [str] {
    let out: [str] = [];
    if len(strings.trim(s)) == 0 {
        return out;
    }
    for part in strings.split(s, ",") {
        let t = strings.trim(part);
        if len(t) > 0 {
            push(out, t);
        }
    }
    return out;
}

// What the router keeps: the policy, and the header values built once.
pub gc struct Cors {
    on: bool,
    any: bool,
    credentials: bool,
    origins: [str],
    allow_methods: str,
    allow_headers: str,
    allow_headers_lower: [str],
    expose: str,
    max_age: str,
}

pub fn cors_off() -> Cors {
    return Cors {
        on: false, any: false, credentials: false, origins: [],
        allow_methods: "", allow_headers: "", allow_headers_lower: [],
        expose: "", max_age: ""
    };
}

fn cors_compile(p: CorsPolicy) -> Cors {
    let lower: [str] = [];
    for h in p.headers {
        push(lower, strings.to_lower(h));
    }
    let any = false;
    for o in p.origins {
        if o == "*" {
            any = true;
        }
    }
    return Cors {
        on: len(p.origins) > 0,
        any: any,
        credentials: p.credentials,
        origins: p.origins,
        allow_methods: strings.join(p.methods, ", "),
        allow_headers: strings.join(p.headers, ", "),
        allow_headers_lower: lower,
        expose: strings.join(p.expose, ", "),
        max_age: to_str(p.max_age)
    };
}

impl Cors {
    // Whether `origin` (an Origin header's value) is allowed.
    pub fn allows(self: Cors, origin: str) -> bool {
        if !self.on || len(origin) == 0 {
            return false;
        }
        if self.any {
            return true;
        }
        for o in self.origins {
            if o == origin {
                return true;
            }
            if origin_matches_pattern(o, origin) {
                return true;
            }
        }
        return false;
    }

    // The headers for an ordinary response to a request with this Origin
    // ("" when it had none).
    pub fn apply(self: Cors, resp: http.Response, origin: str) -> http.Response {
        if !self.on {
            return resp;
        }
        let out = resp;
        if self.any && !self.credentials {
            if len(origin) > 0 {
                out = http.with_header(out, "access-control-allow-origin", "*");
                if len(self.expose) > 0 {
                    out = http.with_header(out, "access-control-expose-headers", self.expose);
                }
            }
            return out;
        }
        // The answer depends on the origin from here on, allowed or not.
        out = http.with_header(out, "vary", "Origin");
        if !self.allows(origin) {
            return out;
        }
        out = http.with_header(out, "access-control-allow-origin", origin);
        if self.credentials {
            out = http.with_header(out, "access-control-allow-credentials", "true");
        }
        if len(self.expose) > 0 {
            out = http.with_header(out, "access-control-expose-headers", self.expose);
        }
        return out;
    }

    // The answer to a preflight from `origin`. 204 either way: an origin
    // that is not allowed gets no CORS headers, which is what makes the
    // browser refuse.
    pub fn preflight(self: Cors, origin: str) -> http.Response {
        let resp = http.Response {
            status: 204,
            status_text: "No Content",
            content_type: "",
            location: "",
            extra: [],
            body: to_bytes("")
        };
        resp = http.with_header(resp, "vary",
            "Origin, Access-Control-Request-Method, Access-Control-Request-Headers");
        if !self.allows(origin) {
            return resp;
        }
        let allow_origin = origin;
        if self.any && !self.credentials {
            allow_origin = "*";
        }
        resp = http.with_header(resp, "access-control-allow-origin", allow_origin);
        resp = http.with_header(resp, "access-control-allow-methods", self.allow_methods);
        if len(self.allow_headers) > 0 {
            resp = http.with_header(resp, "access-control-allow-headers", self.allow_headers);
        }
        if self.credentials {
            resp = http.with_header(resp, "access-control-allow-credentials", "true");
        }
        resp = http.with_header(resp, "access-control-max-age", self.max_age);
        return resp;
    }
}

// "https://*.example.com" against "https://api.eu.example.com": the same
// scheme and port, and a host that ends in ".example.com" with at least
// one label before it. Never the bare domain, never "evilexample.com".
fn origin_matches_pattern(pattern: str, origin: str) -> bool {
    let star = strings.find(pattern, "://*.");
    if star < 0 {
        return false;
    }
    let scheme = strings.slice(pattern, 0, star + 3);
    if !strings.has_prefix(origin, scheme) {
        return false;
    }
    let suffix = strings.slice(pattern, star + 4, len(pattern));
    let host = strings.slice(origin, len(scheme), len(origin));
    if !strings.has_suffix(host, suffix) || len(host) <= len(suffix) {
        return false;
    }
    let label = strings.slice(host, 0, len(host) - len(suffix));
    return !strings.contains(label, "/") && !strings.contains(label, ":") &&
           !strings.has_prefix(label, ".");
}

// Whether a request is a CORS preflight: OPTIONS, with an Origin and the
// method the real request will use.
pub fn is_preflight(method: str, raw_headers: bytes) -> bool {
    return method == "OPTIONS" &&
           strings.find_field(raw_headers, "origin") >= 0 &&
           strings.find_field(raw_headers, "access-control-request-method") >= 0;
}
