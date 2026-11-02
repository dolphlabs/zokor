import "http";
import "strings";
import "timez";

gc struct CkState {
    keys: CookieKeys,
}

fn ck_theme(c: Ctx[CkState]) -> http.Response {
    return text(200, "theme=" + c.cookie("theme") + " n=" + to_str(len(c.cookies())));
}

fn ck_whoami(c: Ctx[CkState]) -> http.Response {
    guard let uid = signed_value(c, "uid", c.state.keys) else {
        return respond(c.errors, "unauthorized", c.request_id);
    }
    return text(200, "uid=" + uid);
}

fn ck_keys(list: [str]) -> CookieKeys {
    let r = cookie_keys(list);
    guard let k = r else let e = err_of(r) {
        panic(e);
    }
    return k;
}

fn key_a() -> str { return "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; }
fn key_b() -> str { return "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; }

fn ck_router(keys: CookieKeys) -> Router[CkState] {
    let r = new_router(CkState { keys: keys });
    r.get("/theme", ck_theme);
    r.get("/me", ck_whoami);
    return r;
}

fn ck_get(r: Router[CkState], p: str, cookie: str) -> http.Response {
    return r.serve(get_request(p).header("Cookie", cookie).build());
}

fn test_a_new_cookie_starts_safe() {
    let s = cookie_string(new_cookie("theme", "dark"));
    assert(s == "theme=dark; Path=/; Secure; HttpOnly; SameSite=Lax", s);
}

fn test_every_attribute_is_written() {
    let c = new_cookie("__Secure-pref", "1");
    c.path = "/app";
    c.domain = ".example.com";
    c.max_age = 3600;
    c.same_site = SameSite.NONE;
    c.partitioned = true;
    c.http_only = false;
    let s = cookie_string(c);
    assert(s == "__Secure-pref=1; Path=/app; Domain=example.com; Max-Age=3600; Secure; " +
                "SameSite=None; Partitioned", s);
}

fn test_set_cookie_adds_the_header_and_refuses_bad_cookies() {
    let r = set_cookie(text(200, "ok"), new_cookie("theme", "dark"));
    guard let resp = r else let e = err_of(r) { panic(e); }
    assert(resp_header(resp, "set-cookie") == "theme=dark; Path=/; Secure; HttpOnly; SameSite=Lax");
    let bad = new_cookie("theme", "dark; Domain=evil.com");
    let rb = set_cookie(text(200, "ok"), bad);
    guard let _no = rb else let e = err_of(rb) {
        assert(strings.contains(e, "semicolons"), e);
        return;
    }
    panic("a value with ; was accepted: it would add attributes of its own");
}

fn test_cookie_problems_name_the_fix() {
    assert(strings.contains(cookie_problem(new_cookie("bad name", "x")), "must be a token"));
    assert(strings.contains(cookie_problem(new_cookie("a", "has space")), "spaces"));
    assert(strings.contains(cookie_problem(new_cookie("a", "line\r\nbreak")), "control"));
    let none_insecure = new_cookie("a", "1");
    none_insecure.same_site = SameSite.NONE;
    none_insecure.secure = false;
    assert(strings.contains(cookie_problem(none_insecure), "SameSite=None needs Secure"));
    let host = new_cookie("__Host-id", "1");
    host.domain = "example.com";
    assert(strings.contains(cookie_problem(host), "__Host-"));
    let p = new_cookie("a", "1");
    p.path = "/x;Secure";
    assert(strings.contains(cookie_problem(p), "path must start with /"));
    let d = new_cookie("a", "1");
    d.domain = "evil.com; Path=/";
    assert(strings.contains(cookie_problem(d), "domain must be a host name"));
    let big = new_cookie("a", strings.repeat("x", 5000));
    assert(strings.contains(cookie_problem(big), "4096"));
}

fn test_clear_cookie_expires_it_now() {
    let r = clear_cookie(text(200, "ok"), "theme", "/", "");
    guard let resp = r else let e = err_of(r) { panic(e); }
    assert(strings.contains(resp_header(resp, "set-cookie"),
                            "theme=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT"));
}

fn test_expires_is_written_as_an_http_date() {
    let c = new_cookie("sid", "abc");
    assert(!strings.contains(cookie_string(c), "Expires"));
    c.expires = some(timez.unix(1792000000));
    c.max_age = 3600;
    assert(cookie_string(c) == "sid=abc; Path=/; Max-Age=3600; " +
           "Expires=Wed, 14 Oct 2026 17:46:40 GMT; Secure; HttpOnly; SameSite=Lax");
}

fn test_expires_before_1601_is_refused() {
    let c = new_cookie("sid", "abc");
    c.expires = some(timez.unix(-11700000000));
    assert(strings.contains(cookie_problem(c), "expires must be in or after 1601"));
    let r = set_cookie(text(200, "ok"), c);
    if let _sent = r {
        panic("a cookie expiring in 1599 was sent");
    }
}

fn test_parse_cookies_skips_what_is_malformed() {
    let m = parse_cookies("a=1; b=\"two\"; junk; =nameless; bad name=3; c=has space; a=second; d=");
    assert(m["a"] == "1", "the first a wins");
    assert(m["b"] == "two", "quotes are removed");
    assert(m["d"] == "");
    assert(!has(m, "junk") && !has(m, "bad name") && !has(m, "c"));
    assert(len(m) == 3, to_str(len(m)));
}

fn test_ctx_reads_cookies() {
    let r = ck_router(ck_keys([key_a()]));
    assert(resp_text(ck_get(r, "/theme", "theme=dark; lang=en")) == "theme=dark n=2");
    assert(resp_text(r.serve(get_request("/theme").build())) == "theme= n=0");
}

fn signed_for(name: str, value: str, keys: CookieKeys) -> str {
    let r = signed_cookie(name, value, keys);
    guard let c = r else let e = err_of(r) { panic(e); }
    return c.value;
}

fn test_signed_cookies_verify_and_refuse_tampering() {
    let keys = ck_keys([key_a()]);
    let r = ck_router(keys);
    let v = signed_for("uid", "42", keys);
    assert(strings.has_prefix(v, "42."));
    assert(resp_text(ck_get(r, "/me", "uid=" + v)) == "uid=42");
    // the value changed, the signature kept
    let forged = "43" + strings.slice(v, 2, len(v));
    assert(resp_status(ck_get(r, "/me", "uid=" + forged)) == 401);
    // a valid signature moved to another cookie name
    let other = signed_for("admin", "42", keys);
    assert(resp_status(ck_get(r, "/me", "uid=" + other)) == 401);
    assert(resp_status(ck_get(r, "/me", "uid=42")) == 401, "unsigned");
    assert(resp_status(ck_get(r, "/me", "")) == 401, "missing");
}

fn test_key_rotation_keeps_old_cookies_valid() {
    let old_keys = ck_keys([key_a()]);
    let v = signed_for("uid", "7", old_keys);
    let rotated = ck_keys([key_b(), key_a()]);
    guard let got = verify_signed("uid", v, rotated) else { panic("old cookie refused after rotation"); }
    assert(got == "7");
    assert(signed_for("uid", "7", rotated) == signed_for("uid", "7", ck_keys([key_b()])),
           "the newest key signs");
    guard let _x = verify_signed("uid", v, ck_keys([key_b()])) else { return; }
    panic("a cookie signed with a retired key still verified");
}

fn test_keys_must_be_long_enough() {
    let r = cookie_keys(["short"]);
    guard let _k = r else let e = err_of(r) {
        assert(strings.contains(e, "32 or more"), e);
        let c = cfg_of("COOKIE_KEYS=tooshort\n");
        let ks = cookie_keys_from(c);
        assert(len(ks.keys) == 0);
        guard let _ok = check(c) else { return; }
        panic("a short COOKIE_KEYS was not reported");
    }
    panic("a 5-byte key was accepted");
}

fn test_signing_without_keys_is_an_error() {
    let r = signed_cookie("uid", "1", CookieKeys { keys: [] });
    guard let _c = r else { return; }
    panic("signed with no key");
}

fn test_constant_time_equal() {
    assert(constant_time_equal(b"abc", b"abc"));
    assert(!constant_time_equal(b"abc", b"abd"));
    assert(!constant_time_equal(b"abc", b"ab"));
    assert(constant_time_equal(b"", b""));
}
