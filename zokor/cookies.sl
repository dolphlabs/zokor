// Cookies.
//
// Reading: `c.cookie("theme")` is the value the browser sent, "" when it
// sent none. A malformed pair in the Cookie header is skipped, the way
// browsers skip it, never guessed at.
//
// Setting: a Cookie starts safe -- HttpOnly, Secure, SameSite=Lax, Path=/
// -- and every attribute is checked before it is written, so a bad name, a
// value with a `;` in it, or SameSite=None without Secure (which browsers
// drop) is an error to handle, not a cookie that silently does nothing:
//
//     let ck = zokor.new_cookie("theme", "dark");
//     ck.max_age = 86400 * 30;
//     return zokor.set_cookie(resp, ck) ?? resp;
//
// Signed cookies carry an HMAC-SHA256 of the name and value, so the client
// can read them but not change them. The keys come from COOKIE_KEYS: the
// first signs, every one verifies, so a new key goes first and the old one
// stays listed until the cookies it signed have expired -- rotation without
// logging everyone out:
//
//     let keys = zokor.cookie_keys_from(cfg);          // COOKIE_KEYS=new,old
//     let ck = zokor.signed_cookie("uid", "42", keys);
//     let uid = zokor.signed_value(c, "uid", keys) ?? "";
//
// Signed is not encrypted: never put a secret in a cookie value.
//
// There is no Expires attribute: it needs an HTTP date, and Max-Age says
// the same thing to every browser in use.

import "crypto";
import "encoding";
import "http";
import "strings";

pub enum SameSite {
    LAX,
    STRICT,
    NONE,
}

pub gc struct Cookie {
    name: str,
    value: str,
    path: str,
    // "" for a host-only cookie (the safest: no subdomain sees it).
    domain: str,
    // Seconds. -1 is a session cookie (no Max-Age); 0 deletes it.
    max_age: int,
    secure: bool,
    http_only: bool,
    same_site: SameSite,
    // CHIPS: a third-party cookie partitioned by the top-level site.
    partitioned: bool,
}

pub fn new_cookie(name: str, value: str) -> Cookie {
    return Cookie {
        name: name,
        value: value,
        path: "/",
        domain: "",
        max_age: -1,
        secure: true,
        http_only: true,
        same_site: SameSite.LAX,
        partitioned: false
    };
}

// RFC 6265 cookie-octet: printable ASCII except space, `"`, `,`, `;` and
// `\`.
fn cookie_octets_ok(s: str) -> bool {
    for c in to_bytes(s) {
        let x = c as int;
        if x < 0x21 || x > 0x7e || x == 0x22 || x == 0x2c || x == 0x3b || x == 0x5c {
            return false;
        }
    }
    return true;
}

// An attribute value: no control bytes and no `;`.
fn attr_ok(s: str) -> bool {
    for c in to_bytes(s) {
        let x = c as int;
        if x < 0x20 || x == 0x7f || x == 0x3b {
            return false;
        }
    }
    return true;
}

fn no_leading_dot(d: str) -> str {
    if strings.has_prefix(d, ".") {
        return strings.slice(d, 1, len(d));
    }
    return d;
}

fn domain_ok(d: str) -> bool {
    if len(d) == 0 || len(d) > 253 {
        return false;
    }
    for c in to_bytes(d) {
        let x = c as int;
        let ok_byte = (x >= 97 && x <= 122) || (x >= 65 && x <= 90) ||
                      (x >= 48 && x <= 57) || x == 45 || x == 46;
        if !ok_byte {
            return false;
        }
    }
    return true;
}

// What is wrong with `c`, or "". Every problem is named, with the fix.
pub fn cookie_problem(c: Cookie) -> str {
    let out: [str] = [];
    if !token_ok(c.name) {
        push(out, "name '" + c.name + "' must be a token: letters, digits and !#$%&'*+-.^_`|~");
    }
    if !cookie_octets_ok(c.value) {
        push(out, "value must not contain spaces, quotes, commas, semicolons, backslashes " +
                  "or control characters; encode it first (encoding.base64url_encode)");
    }
    if len(c.name) + len(c.value) > 4096 {
        push(out, "name and value together exceed 4096 bytes, which browsers drop");
    }
    if len(c.path) > 0 && (!strings.has_prefix(c.path, "/") || !attr_ok(c.path)) {
        push(out, "path must start with / and contain no ; or control characters");
    }
    if len(c.domain) > 0 && !domain_ok(no_leading_dot(c.domain)) {
        push(out, "domain must be a host name like example.com");
    }
    if c.max_age < -1 {
        push(out, "max age must be -1 (session), 0 (delete) or a number of seconds");
    }
    if c.same_site == SameSite.NONE && !c.secure {
        push(out, "SameSite=None needs Secure; browsers drop it otherwise");
    }
    if c.partitioned && !c.secure {
        push(out, "Partitioned needs Secure");
    }
    if strings.has_prefix(c.name, "__Secure-") && !c.secure {
        push(out, "a __Secure- cookie needs Secure");
    }
    if strings.has_prefix(c.name, "__Host-") &&
       (!c.secure || c.path != "/" || len(c.domain) > 0) {
        push(out, "a __Host- cookie needs Secure, Path=/ and no Domain");
    }
    return strings.join(out, "; ");
}

fn same_site_name(s: SameSite) -> str {
    switch s {
        case SameSite.LAX { return "Lax"; }
        case SameSite.STRICT { return "Strict"; }
        case SameSite.NONE { return "None"; }
    }
    return "Lax";
}

// The Set-Cookie value for `c`, unchecked: callers check first.
pub fn cookie_string(c: Cookie) -> str {
    let s = c.name + "=" + c.value;
    if len(c.path) > 0 {
        s = s + "; Path=" + c.path;
    }
    if len(c.domain) > 0 {
        s = s + "; Domain=" + no_leading_dot(c.domain);
    }
    if c.max_age >= 0 {
        s = s + "; Max-Age=" + to_str(c.max_age);
    }
    if c.secure {
        s = s + "; Secure";
    }
    if c.http_only {
        s = s + "; HttpOnly";
    }
    s = s + "; SameSite=" + same_site_name(c.same_site);
    if c.partitioned {
        s = s + "; Partitioned";
    }
    return s;
}

// `resp` with a Set-Cookie header for `c`, or why `c` cannot be sent.
pub fn set_cookie(resp: http.Response, c: Cookie) -> result[http.Response, str] {
    let why = cookie_problem(c);
    if len(why) > 0 {
        return err("cookie " + c.name + ": " + why);
    }
    return ok(http.with_header(resp, "set-cookie", cookie_string(c)));
}

// Tells the browser to delete `name`. Path and domain must match the ones
// it was set with, or the browser keeps the original.
pub fn clear_cookie(resp: http.Response, name: str, path: str,
                    domain: str) -> result[http.Response, str] {
    let c = new_cookie(name, "");
    c.path = path;
    c.domain = domain;
    c.max_age = 0;
    return set_cookie(resp, c);
}

// Every well-formed name=value pair in a Cookie header, in order; a pair
// without `=`, with a bad name or with bytes a cookie value cannot hold is
// skipped. A value in double quotes is unquoted.
pub fn parse_cookies(header: str) -> map[str]str {
    let out: map[str]str = {};
    for part in strings.split(header, ";") {
        let p = strings.trim(part);
        let eq = strings.find(p, "=");
        if eq <= 0 {
            continue;
        }
        let name = strings.trim(strings.slice(p, 0, eq));
        let value = strings.trim(strings.slice(p, eq + 1, len(p)));
        if len(value) >= 2 && strings.has_prefix(value, "\"") && strings.has_suffix(value, "\"") {
            value = strings.slice(value, 1, len(value) - 1);
        }
        if !token_ok(name) || !cookie_octets_ok(value) {
            continue;
        }
        // The first one wins: browsers send the most specific path first.
        if !has(out, name) {
            out[name] = value;
        }
    }
    return out;
}

// c.cookie(name) and c.cookies() are Ctx methods, in router.sl (a type
// has one impl block); both parse with parse_cookies above.

// ---- signed cookies -------------------------------------------------------

pub gc struct CookieKeys {
    // The first signs; every one verifies.
    keys: [bytes],
}

// Keys of at least 32 bytes each, newest first. An empty list signs
// nothing: signed_cookie and signed_value refuse to work without a key.
pub fn cookie_keys(keys: [str]) -> result[CookieKeys, str] {
    if len(keys) == 0 {
        return err("no cookie keys: set COOKIE_KEYS to one or more random strings of 32+ bytes");
    }
    let out: [bytes] = [];
    for k in keys {
        if len(k) < 32 {
            return err("a cookie key is " + to_str(len(k)) +
                       " bytes; use 32 or more random bytes (openssl rand -base64 48)");
        }
        push(out, to_bytes(k));
    }
    return ok(CookieKeys { keys: out });
}

// COOKIE_KEYS, comma-separated, newest first. A problem is recorded on
// `cfg` for check(cfg), and the result then has no keys.
pub fn cookie_keys_from(cfg: Config) -> CookieKeys {
    let raw = str_or(cfg, "COOKIE_KEYS", "");
    let r = cookie_keys(comma_list(raw));
    guard let ks = r else let e = err_of(r) {
        record(cfg, "COOKIE_KEYS", raw, e);
        return CookieKeys { keys: [] };
    }
    return ks;
}

fn cookie_mac(key: bytes, name: str, value: str) -> str {
    return encoding.base64url_encode(crypto.hmac_sha256(key, to_bytes(name + "=" + value)));
}

// Compares in time that depends only on the lengths, so a forged
// signature cannot be found a byte at a time by timing the answer.
pub fn constant_time_equal(a: bytes, b: bytes) -> bool {
    if len(a) != len(b) {
        return false;
    }
    let acc = 0;
    let i = 0;
    while i < len(a) {
        acc = acc | ((a[i] as int) ^ (b[i] as int));
        i = i + 1;
    }
    return acc == 0;
}

// A cookie whose value is `value.signature`. The name is signed with it,
// so a signed value cannot be moved to another cookie. Errors when there
// is no key.
pub fn signed_cookie(name: str, value: str, keys: CookieKeys) -> result[Cookie, str] {
    if len(keys.keys) == 0 {
        return err("no cookie keys to sign with: set COOKIE_KEYS");
    }
    if !cookie_octets_ok(value) {
        return err("cookie " + name + ": value must be cookie-safe; encode it first " +
                   "(encoding.base64url_encode)");
    }
    return ok(new_cookie(name, value + "." + cookie_mac(keys.keys[0], name, value)));
}

// The value of signed cookie `name` when its signature matches any key,
// none when it is missing, unsigned or forged.
pub fn signed_value[S](c: Ctx[S], name: str, keys: CookieKeys) -> opt[str] {
    return verify_signed(name, c.cookie(name), keys);
}

pub fn verify_signed(name: str, raw: str, keys: CookieKeys) -> opt[str] {
    let dot = strings.rfind(raw, ".");
    if dot <= 0 || len(keys.keys) == 0 {
        return none;
    }
    let value = strings.slice(raw, 0, dot);
    let sig = to_bytes(strings.slice(raw, dot + 1, len(raw)));
    for k in keys.keys {
        if constant_time_equal(sig, to_bytes(cookie_mac(k, name, value))) {
            return some(value);
        }
    }
    return none;
}
