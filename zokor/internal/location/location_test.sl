fn test_location_preserves_relative_references_and_encoded_bytes() {
    for value in ["/next?a=b#part", "../next", "?page=2", "#part", "/caf%C3%A9", "next:step"] {
        let r = check(value, 100, false);
        if value == "next:step" { guard let _v = r else { continue; } panic("relative scheme ambiguity accepted"); }
        guard let _v = r else let e = err_of(r) { panic(e); }
    }
}
fn test_location_rejects_controls_ambiguous_external_urls_and_invalid_escapes() {
    for value in ["", "//host/path", "/\\host", "/a b", "/a\r\nX: y", "/a%", "/a%0x", "/a#b#c", "/[x]", "javascript:alert(1)", "http://", "https://user:secret@host/"] {
        let r = check(value, 100, true); guard let _v = r else { continue; } panic("invalid location accepted");
    }
    let external = check("https://example.com/next", 100, false);
    guard let _e = external else {
        let allowed = check("https://example.com/next", 100, true);
        guard let _a = allowed else { panic("explicit external URL rejected"); }
        let over = check("/long", 3, false);
        guard let _o = over else { return; } panic("limit bypassed");
    }
    panic("external URL accepted by default");
}
fn test_external_hosts_ports_and_ip_literals_are_checked() {
    for value in ["https://example.com/", "http://[::1]:8080/", "https://[2001:db8:0:0:0:0:0:1]/", "http://[::ffff:192.0.2.1]/"] {
        let r = check(value, 100, true); guard let _v = r else let e = err_of(r) { panic(e); }
    }
    for value in ["http://host:+80/", "http://host:0/", "http://host:65536/", "http://host:/", "http://[broken]/", "http://a[b]/", "http://[1:2:3]/", "http://[1::2::3]/", "http://::1/"] {
        let r = check(value, 100, true); guard let _v = r else { continue; } panic("invalid authority accepted");
    }
}
