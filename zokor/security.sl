// Security headers.
//
// On by default, on every response -- dynamic, static, errors, the 500
// after a panic -- with the values an API wants:
//
//   content-security-policy: default-src 'none'; frame-ancestors 'none'
//   strict-transport-security: max-age=31536000; includeSubDomains
//   x-content-type-options: nosniff
//   x-frame-options: DENY
//   referrer-policy: no-referrer
//
// An API answers JSON, so its CSP allows nothing: a response opened in a
// browser can load no script and cannot be framed. HSTS tells browsers to
// use HTTPS for a year; a browser ignores it on a plain-HTTP response, so
// it is harmless where TLS ends at a proxy and right where it does not.
// Cross-Origin-Opener-Policy and Cross-Origin-Resource-Policy are left
// off unless asked for: CORP `same-origin` blocks legitimate cross-origin
// embeds, and COOP matters for pages, not JSON.
//
// A handler that sets one of these headers itself keeps its own value.
//
//     r.security_headers(zokor.security_from(cfg));   // or no_security_headers()

import "builder";
import "http";
import "strings";

pub gc struct SecurityHeaders {
    // "" leaves a header out.
    csp: str,
    // HSTS max-age in seconds; 0 leaves the header out.
    hsts_max_age: int,
    hsts_subdomains: bool,
    hsts_preload: bool,
    nosniff: bool,
    frame_options: str,
    referrer_policy: str,
    coop: str,
    corp: str,
}

pub fn default_security_headers() -> SecurityHeaders {
    return SecurityHeaders {
        csp: "default-src 'none'; frame-ancestors 'none'",
        hsts_max_age: 31536000,
        hsts_subdomains: true,
        hsts_preload: false,
        nosniff: true,
        frame_options: "DENY",
        referrer_policy: "no-referrer",
        coop: "",
        corp: ""
    };
}

pub fn no_security_headers() -> SecurityHeaders {
    return SecurityHeaders {
        csp: "", hsts_max_age: 0, hsts_subdomains: false, hsts_preload: false,
        nosniff: false, frame_options: "", referrer_policy: "", coop: "", corp: ""
    };
}

fn one_of(v: str, allowed: [str]) -> bool {
    for a in allowed {
        if v == a {
            return true;
        }
    }
    return false;
}

fn referrer_policies() -> [str] {
    return ["no-referrer", "no-referrer-when-downgrade", "origin", "origin-when-cross-origin",
            "same-origin", "strict-origin", "strict-origin-when-cross-origin", "unsafe-url"];
}

// What is wrong with `h`, or "".
pub fn security_problem(h: SecurityHeaders) -> str {
    let out: [str] = [];
    if strings.contains(h.csp, "\r") || strings.contains(h.csp, "\n") {
        push(out, "the CSP must be one line");
    }
    if h.hsts_max_age < 0 {
        push(out, "HSTS max-age must be 0 (off) or more seconds");
    }
    if h.hsts_preload && (h.hsts_max_age < 31536000 || !h.hsts_subdomains) {
        push(out, "HSTS preload needs max-age of at least 31536000 and includeSubDomains");
    }
    if len(h.frame_options) > 0 && !one_of(h.frame_options, ["DENY", "SAMEORIGIN"]) {
        push(out, "frame options must be DENY or SAMEORIGIN");
    }
    if len(h.referrer_policy) > 0 && !one_of(h.referrer_policy, referrer_policies()) {
        push(out, "referrer policy must be one of " + strings.join(referrer_policies(), ", "));
    }
    if len(h.coop) > 0 && !one_of(h.coop, ["same-origin", "same-origin-allow-popups", "unsafe-none"]) {
        push(out, "cross-origin-opener-policy must be same-origin, same-origin-allow-popups or unsafe-none");
    }
    if len(h.corp) > 0 && !one_of(h.corp, ["same-origin", "same-site", "cross-origin"]) {
        push(out, "cross-origin-resource-policy must be same-origin, same-site or cross-origin");
    }
    return strings.join(out, "; ");
}

// The header lines, "name: value", in a fixed order.
pub fn security_lines(h: SecurityHeaders) -> [str] {
    let out: [str] = [];
    if len(h.csp) > 0 {
        push(out, "content-security-policy: " + h.csp);
    }
    if h.hsts_max_age > 0 {
        let v = "max-age=" + to_str(h.hsts_max_age);
        if h.hsts_subdomains {
            v = v + "; includeSubDomains";
        }
        if h.hsts_preload {
            v = v + "; preload";
        }
        push(out, "strict-transport-security: " + v);
    }
    if h.nosniff {
        push(out, "x-content-type-options: nosniff");
    }
    if len(h.frame_options) > 0 {
        push(out, "x-frame-options: " + h.frame_options);
    }
    if len(h.referrer_policy) > 0 {
        push(out, "referrer-policy: " + h.referrer_policy);
    }
    if len(h.coop) > 0 {
        push(out, "cross-origin-opener-policy: " + h.coop);
    }
    if len(h.corp) > 0 {
        push(out, "cross-origin-resource-policy: " + h.corp);
    }
    return out;
}

// SECURITY_HEADERS (false turns all of them off), CONTENT_SECURITY_POLICY
// ("off" for none), HSTS_MAX_AGE (seconds, 0 = off), HSTS_INCLUDE_SUBDOMAINS,
// HSTS_PRELOAD, FRAME_OPTIONS (DENY, SAMEORIGIN or off), REFERRER_POLICY,
// CROSS_ORIGIN_OPENER_POLICY and CROSS_ORIGIN_RESOURCE_POLICY. Problems
// are recorded on `cfg`; settings with problems come back as the defaults.
pub fn security_from(cfg: Config) -> SecurityHeaders {
    let on = strings.to_lower(str_or(cfg, "SECURITY_HEADERS", ""));
    if on == "false" || on == "0" || on == "off" || on == "no" {
        return no_security_headers();
    }
    if len(on) > 0 && on != "true" && on != "1" && on != "on" && on != "yes" {
        record(cfg, "SECURITY_HEADERS", on, "must be true or false");
    }
    let h = default_security_headers();
    let csp = str_or(cfg, "CONTENT_SECURITY_POLICY", "");
    if strings.to_lower(csp) == "off" {
        h.csp = "";
    } else if len(csp) > 0 {
        h.csp = csp;
    }
    let ma = str_or(cfg, "HSTS_MAX_AGE", "");
    if len(ma) > 0 {
        let pr = to_int(ma);
        if let n = pr {
            h.hsts_max_age = n;
        } else {
            record(cfg, "HSTS_MAX_AGE", ma, "must be a whole number of seconds (0 turns HSTS off)");
        }
    }
    h.hsts_subdomains = bool_or(cfg, "HSTS_INCLUDE_SUBDOMAINS", h.hsts_subdomains);
    h.hsts_preload = bool_or(cfg, "HSTS_PRELOAD", h.hsts_preload);
    let fo = strings.to_upper(str_or(cfg, "FRAME_OPTIONS", ""));
    if fo == "OFF" {
        h.frame_options = "";
    } else if len(fo) > 0 {
        h.frame_options = fo;
    }
    let rp = strings.to_lower(str_or(cfg, "REFERRER_POLICY", ""));
    if rp == "off" {
        h.referrer_policy = "";
    } else if len(rp) > 0 {
        h.referrer_policy = rp;
    }
    let coop = strings.to_lower(str_or(cfg, "CROSS_ORIGIN_OPENER_POLICY", ""));
    if len(coop) > 0 && coop != "off" {
        h.coop = coop;
    }
    let corp = strings.to_lower(str_or(cfg, "CROSS_ORIGIN_RESOURCE_POLICY", ""));
    if len(corp) > 0 && corp != "off" {
        h.corp = corp;
    }
    let why = security_problem(h);
    if len(why) > 0 {
        record(cfg, "SECURITY_HEADERS", "", why);
        return default_security_headers();
    }
    return h;
}

// What the router keeps: the lines, and each line's lowercase name for
// the "a handler set its own" check.
pub gc struct Security {
    lines: [str],
    // "name:" per line, lowercase, for the "a handler set its own" check.
    prefixes: [str],
}

pub fn security_compile(h: SecurityHeaders) -> Security {
    let lines = security_lines(h);
    let prefixes: [str] = [];
    for l in lines {
        push(prefixes, strings.slice(l, 0, strings.find(l, ":") + 1));
    }
    return Security { lines: lines, prefixes: prefixes };
}

impl Security {
    // `resp` with every line it does not already carry. A handler's own
    // header is recognised by its lowercase name, which is how
    // `with_header` stores every name: a prefix compare per line, so the
    // check allocates nothing (http.has_resp_header copies each line).
    pub fn apply(self: Security, resp: http.Response) -> http.Response {
        if len(self.lines) == 0 {
            return resp;
        }
        let n = len(resp.extra);
        let i = 0;
        if n == 0 {
            while i < len(self.lines) {
                push(resp.extra, self.lines[i]);
                i = i + 1;
            }
            return resp;
        }
        while i < len(self.lines) {
            let mine = false;
            let k = 0;
            while k < n {
                if strings.has_prefix(resp.extra[k], self.prefixes[i]) {
                    mine = true;
                    break;
                }
                k = k + 1;
            }
            if !mine {
                push(resp.extra, self.lines[i]);
            }
            i = i + 1;
        }
        return resp;
    }
}

// A static route's bytes: status line, content type, the security lines,
// length, connection, the date line, body. `keep_alive` false renders the
// close variant. Built once per route, so a static answer carries the
// headers at no cost per request; the header block ends with
// http.static_date_line(), whose date slang's write_static refreshes on
// every send (RFC 9110 requires a current Date). A 1xx, 204 or 304 has no
// content: no Content-Length and no body, whatever the route holds.
pub fn static_render_with(status: i32, content_type: str, lines: [str], body: bytes,
                          keep_alive: bool) -> bytes {
    let no_content = status < 200 || status == 204 || status == 304;
    let sb = builder.new_bytes();
    sb.write_str("HTTP/1.1 ");
    sb.write_str(to_str(status));
    sb.write_str(" ");
    sb.write_str(status_text(status));
    sb.write_str("\r\ncontent-type: ");
    sb.write_str(content_type);
    sb.write_str("\r\n");
    for l in lines {
        sb.write_str(l);
        sb.write_str("\r\n");
    }
    if !no_content {
        sb.write_str("Content-Length: ");
        sb.write_str(to_str(len(body)));
        sb.write_str("\r\n");
    }
    if keep_alive {
        sb.write_str("Connection: keep-alive\r\n");
    } else {
        sb.write_str("Connection: close\r\n");
    }
    sb.write_str(http.static_date_line());
    sb.write_str("\r\n");
    if !no_content {
        sb.write(body);
    }
    return sb.finish();
}
