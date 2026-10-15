import "zokor";

fn values(pairs: [str]) -> zokor.Config {
    let m: map[str]str = {};
    let i = 0;
    while i + 1 < len(pairs) {
        m[pairs[i]] = pairs[i + 1];
        i = i + 2;
    }
    return zokor.config_from_values(m);
}

fn test_settings_are_read_once_and_checked() {
    let cfg = values(["PORT", "8080", "API_KEYS", "acme:0123456789abcdef0123456789abcdef"]);
    let s = settings_from(cfg);
    assert(s.port == 8080);
    let ok_cfg = zokor.check(cfg);
    guard let _ok = ok_cfg else let e = err_of(ok_cfg) { panic(e); }
}

fn test_every_problem_is_reported_at_once() {
    let cfg = values(["PORT", "0", "MAX_CONNECTIONS", "lots"]);
    let _s = settings_from(cfg);
    let r = zokor.check(cfg);
    guard let _ok = r else let e = err_of(r) {
        assert(strings_has(e, "PORT") && strings_has(e, "MAX_CONNECTIONS"), e);
        return;
    }
    panic("a bad configuration passed");
}

fn strings_has(s: str, part: str) -> bool {
    let b = to_bytes(s);
    let p = to_bytes(part);
    let i = 0;
    while i + len(p) <= len(b) {
        if b[i..i + len(p)] == p { return true; }
        i = i + 1;
    }
    return false;
}
