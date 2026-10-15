import "zokor";

fn test_settings_keep_the_configured_port() {
    let values: map[str]str = {};
    values["PORT"] = "9090";
    let cfg = zokor.config_from_values(values);
    let settings = settings_from(cfg);
    assert(settings.port == 9090);
    let checked = zokor.check(cfg);
    guard let _ok = checked else let e = err_of(checked) { panic(e); }
}

fn test_missing_port_is_reported_by_config_check() {
    let values: map[str]str = {};
    let cfg = zokor.config_from_values(values);
    let _settings = settings_from(cfg);
    let checked = zokor.check(cfg);
    guard let _ok = checked else let e = err_of(checked) {
        assert(strings_has(e, "PORT"), e);
        return;
    }
    panic("a missing PORT passed configuration validation");
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
