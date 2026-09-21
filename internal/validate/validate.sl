// Value validators, as plain predicates over a str.
//
// Configuration arrives as text, whatever its source, so every rule
// here answers one question: is this text a usable X? Each returns
// `result[bool, str]` whose error is the reason, phrased so it can be
// printed to an operator as-is: "PORT: must be a TCP port (1-65535),
// got '0'".
//
// No regular expressions. A regex per rule would mean compiling a
// pattern at startup for every variable, and these checks are short
// enough to scan directly -- which also means no dependency and no
// failure mode where the pattern itself is wrong.

fn is_digit(c: int) -> bool { return c >= 48 && c <= 57; }
fn is_lower(c: int) -> bool { return c >= 97 && c <= 122; }
fn is_upper(c: int) -> bool { return c >= 65 && c <= 90; }
fn is_alpha(c: int) -> bool { return is_lower(c) || is_upper(c); }
fn is_alnum(c: int) -> bool { return is_alpha(c) || is_digit(c); }

fn fail(why: str) -> result[bool, str] {
    return err(why);
}

// Non-empty after trimming: the commonest mistake is KEY= with nothing
// after it, which an "is it set" check alone lets through.
pub fn is_string(v: str) -> result[bool, str] {
    if len(v) == 0 {
        return fail("must not be empty");
    }
    let b = to_bytes(v);
    let i = 0;
    while i < len(b) {
        if b[i] != 32 && b[i] != 9 {
            return ok(true);
        }
        i = i + 1;
    }
    return fail("must not be blank");
}

pub fn min_len(v: str, n: int) -> result[bool, str] {
    if len(v) < n {
        return fail("must be at least " + to_str(n) + " characters");
    }
    return ok(true);
}

pub fn max_len(v: str, n: int) -> result[bool, str] {
    if len(v) > n {
        return fail("must be at most " + to_str(n) + " characters");
    }
    return ok(true);
}

pub fn is_int(v: str) -> result[bool, str] {
    let b = to_bytes(v);
    let n = len(b);
    if n == 0 {
        return fail("must be a whole number");
    }
    let i = 0;
    if b[0] == 45 || b[0] == 43 {
        if n == 1 {
            return fail("must be a whole number");
        }
        i = 1;
    }
    while i < n {
        if !is_digit(b[i]) {
            return fail("must be a whole number");
        }
        i = i + 1;
    }
    return ok(true);
}

pub fn in_range(v: str, lo: int, hi: int) -> result[bool, str] {
    let r = is_int(v);
    guard let _ok = r else let e = err_of(r) {
        return fail(e);
    }
    let n = to_int(v) ?? 0;
    if n < lo || n > hi {
        return fail("must be between " + to_str(lo) + " and " + to_str(hi));
    }
    return ok(true);
}

pub fn is_port(v: str) -> result[bool, str] {
    let r = in_range(v, 1, 65535);
    guard let _ok = r else {
        return fail("must be a TCP port (1-65535)");
    }
    return ok(true);
}

pub fn is_float(v: str) -> result[bool, str] {
    guard let _f = to_float(v) else {
        return fail("must be a number");
    }
    return ok(true);
}

pub fn is_bool(v: str) -> result[bool, str] {
    let l = lower(v);
    if l == "1" || l == "0" || l == "true" || l == "false" ||
       l == "yes" || l == "no" || l == "on" || l == "off" {
        return ok(true);
    }
    return fail("must be a boolean (true/false, yes/no, on/off, 1/0)");
}

pub fn lower(v: str) -> str {
    let b = to_bytes(v);
    let i = 0;
    while i < len(b) {
        if is_upper(b[i]) {
            b[i] = b[i] + 32;
        }
        i = i + 1;
    }
    return to_str(b);
}

// One `@`, something before it, and a dotted host after it with a
// two-character-or-longer last label. Deliberately not RFC 5322: the
// full grammar accepts addresses no mail system will deliver to, and
// the only real test of an address is sending to it.
pub fn is_email(v: str) -> result[bool, str] {
    let b = to_bytes(v);
    let n = len(b);
    if n < 6 || n > 254 {
        return fail("must be an email address");
    }
    let at = -1;
    let i = 0;
    while i < n {
        if b[i] == 64 {
            if at >= 0 {
                return fail("must be an email address (one '@')");
            }
            at = i;
        }
        // checked over the WHOLE address, not just the domain: a space
        // in the local part is the same mistake, and used to pass
        if b[i] <= 32 || b[i] == 127 {
            return fail("must be an email address (no spaces)");
        }
        i = i + 1;
    }
    if at <= 0 || at == n - 1 {
        return fail("must be an email address");
    }
    let dot = -1;
    i = at + 1;
    while i < n {
        if b[i] == 46 {
            dot = i;
        }
        i = i + 1;
    }
    if dot < 0 || dot == at + 1 || n - dot < 3 {
        return fail("must be an email address (needs a domain)");
    }
    return ok(true);
}

pub fn is_url(v: str) -> result[bool, str] {
    let scheme = 0;
    if has_prefix(v, "http://") {
        scheme = 7;
    }
    if has_prefix(v, "https://") {
        scheme = 8;
    }
    if scheme == 0 {
        return fail("must be a URL starting http:// or https://");
    }
    let host = slice_from(v, scheme);
    if len(host) == 0 {
        return fail("must be a URL with a host");
    }
    let pr = is_printable(v);
    guard let _p = pr else let e = err_of(pr) {
        return fail(e);
    }
    return ok(true);
}

// postgres://user:pass@host:5432/db, redis://..., amqp://... -- any
// scheme, as long as it has one and a host.
pub fn is_dsn(v: str) -> result[bool, str] {
    let b = to_bytes(v);
    let n = len(b);
    let i = 0;
    while i + 2 < n {
        if b[i] == 58 && b[i + 1] == 47 && b[i + 2] == 47 {
            if i == 0 {
                return fail("must be a connection URL (missing scheme)");
            }
            if i + 3 >= n {
                return fail("must be a connection URL (missing host)");
            }
            return ok(true);
        }
        i = i + 1;
    }
    return fail("must be a connection URL, e.g. postgres://user@host/db");
}

// 8-4-4-4-12 hex, any case.
pub fn is_uuid(v: str) -> result[bool, str] {
    let b = to_bytes(v);
    if len(b) != 36 {
        return fail("must be a UUID");
    }
    let i = 0;
    while i < 36 {
        let c = b[i];
        if i == 8 || i == 13 || i == 18 || i == 23 {
            if c != 45 {
                return fail("must be a UUID");
            }
        } else {
            let hex = is_digit(c) || (c >= 97 && c <= 102) ||
                      (c >= 65 && c <= 70);
            if !hex {
                return fail("must be a UUID");
            }
        }
        i = i + 1;
    }
    return ok(true);
}

// A hostname or an IPv4 address: letters, digits, dots and hyphens,
// with no empty labels.
pub fn is_host(v: str) -> result[bool, str] {
    let b = to_bytes(v);
    let n = len(b);
    if n == 0 || n > 253 {
        return fail("must be a host name or IP address");
    }
    let label = 0;
    let i = 0;
    while i < n {
        let c = b[i];
        if c == 46 {
            if label == 0 {
                return fail("must be a host name or IP address");
            }
            label = 0;
        } else {
            if !(is_alnum(c) || c == 45) {
                return fail("must be a host name or IP address");
            }
            label = label + 1;
            if label > 63 {
                return fail("must be a host name (label too long)");
            }
        }
        i = i + 1;
    }
    if label == 0 {
        return fail("must be a host name or IP address");
    }
    return ok(true);
}

pub fn is_ipv4(v: str) -> result[bool, str] {
    let parts = split_on(v, 46);
    if len(parts) != 4 {
        return fail("must be an IPv4 address");
    }
    let i = 0;
    while i < 4 {
        let r = in_range(parts[i], 0, 255);
        guard let _ok = r else {
            return fail("must be an IPv4 address");
        }
        i = i + 1;
    }
    return ok(true);
}

// One of a fixed set, compared case-insensitively: log levels, modes,
// environments.
pub fn is_one_of(v: str, allowed: [str]) -> result[bool, str] {
    let l = lower(v);
    let i = 0;
    while i < len(allowed) {
        if lower(allowed[i]) == l {
            return ok(true);
        }
        i = i + 1;
    }
    return fail("must be one of: " + join_list(allowed, ", "));
}

// "30s", "5m", "1500ms", "2h", or a bare number of seconds.
pub fn is_duration(v: str) -> result[bool, str] {
    let b = to_bytes(v);
    let n = len(b);
    if n == 0 {
        return fail("must be a duration, e.g. 30s, 5m, 1500ms");
    }
    let i = 0;
    while i < n && is_digit(b[i]) {
        i = i + 1;
    }
    if i == 0 {
        return fail("must be a duration, e.g. 30s, 5m, 1500ms");
    }
    let unit = to_str(b[i..n]);
    if unit == "" || unit == "ms" || unit == "s" || unit == "m" ||
       unit == "h" {
        return ok(true);
    }
    return fail("must be a duration ending ms, s, m or h");
}

// Nanoseconds for a duration that `is_duration` accepts.
pub fn duration_ns(v: str, fallback: int) -> int {
    let b = to_bytes(v);
    let n = len(b);
    let i = 0;
    while i < n && is_digit(b[i]) {
        i = i + 1;
    }
    if i == 0 {
        return fallback;
    }
    let num = to_int(to_str(b[0..i])) ?? 0;
    let unit = to_str(b[i..n]);
    if unit == "ms" {
        return num * 1000000;
    }
    if unit == "m" {
        return num * 60000000000;
    }
    if unit == "h" {
        return num * 3600000000000;
    }
    return num * 1000000000;
}

// Only characters that are safe in a header value or a log line: no
// control bytes, which is how a config value becomes a header
// injection.
pub fn is_printable(v: str) -> result[bool, str] {
    let b = to_bytes(v);
    let i = 0;
    while i < len(b) {
        if b[i] < 32 || b[i] == 127 {
            return fail("must not contain control characters");
        }
        i = i + 1;
    }
    return ok(true);
}

pub fn has_prefix(v: str, p: str) -> bool {
    let a = to_bytes(v);
    let b = to_bytes(p);
    if len(b) > len(a) {
        return false;
    }
    let i = 0;
    while i < len(b) {
        if a[i] != b[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}

pub fn slice_from(v: str, i: int) -> str {
    let b = to_bytes(v);
    if i >= len(b) {
        return "";
    }
    return to_str(b[i..len(b)]);
}

pub fn split_on(v: str, sep: int) -> [str] {
    let out: [str] = [];
    let b = to_bytes(v);
    let n = len(b);
    let start = 0;
    let i = 0;
    while i <= n {
        if i == n || b[i] == sep {
            push(out, to_str(b[start..i]));
            start = i + 1;
        }
        i = i + 1;
    }
    return out;
}

pub fn join_list(xs: [str], sep: str) -> str {
    let out = "";
    let i = 0;
    while i < len(xs) {
        if i > 0 {
            out = out + sep;
        }
        out = out + xs[i];
        i = i + 1;
    }
    return out;
}
