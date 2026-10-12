import "strings";

fn tp_of(list: str) -> TrustedProxies {
    let r = parse_trusted_proxies(list);
    guard let tp = r else let e = err_of(r) {
        panic("did not parse '" + list + "': " + e);
    }
    return tp;
}

fn h(lines: str) -> bytes {
    return to_bytes(lines);
}

fn test_parse_ipv4_is_strict() {
    assert(parse_ipv4("10.0.0.4") == 167772164);
    assert(parse_ipv4("0.0.0.0") == 0);
    assert(parse_ipv4("255.255.255.255") == 4294967295);
    for bad in ["", "10.0.0", "10.0.0.4.5", "256.0.0.1", "10.0.0.04",
                "010.0.0.1", " 10.0.0.1", "10.0.0.1 ", "10..0.1", "a.b.c.d",
                "10.0.0.-1", "1000.0.0.1", "10.0.0.1:80"] {
        if parse_ipv4(bad) != -1 {
            panic("accepted '" + bad + "'");
        }
    }
}

fn test_trusted_proxies_parse_addresses_and_cidrs() {
    let tp = tp_of(" 10.0.0.0/8 , 192.168.1.10,172.16.0.0/12 ");
    assert(tp.trusts(parse_ipv4("10.200.3.4")));
    assert(tp.trusts(parse_ipv4("192.168.1.10")));
    assert(!tp.trusts(parse_ipv4("192.168.1.11")));
    assert(tp.trusts(parse_ipv4("172.31.255.255")));
    assert(!tp.trusts(parse_ipv4("172.32.0.0")));
    assert(!tp.trusts(-1));
    assert(tp_of("").is_empty());
    assert(tp_of("0.0.0.0/0").trusts(parse_ipv4("8.8.8.8")));
}

fn test_trusted_proxies_report_every_problem_with_a_fix() {
    let r = parse_trusted_proxies("10.0.0.1/8, nonsense, 10.0.0.0/33, 1.2.3.4");
    guard let _tp = r else let e = err_of(r) {
        if strings.find(e, "did you mean 10.0.0.0/8") < 0 ||
           strings.find(e, "'nonsense' is not an IPv4 address or CIDR") < 0 ||
           strings.find(e, "'10.0.0.0/33': the prefix after / must be 0-32") < 0 {
            panic("missing a problem or its fix: " + e);
        }
        return;
    }
    panic("a bad TRUSTED_PROXIES list parsed");
}

// The one way slang exposes a peer's address is inspect(); this pins
// its format, so a change there fails CI instead of blanking addresses.
fn test_peer_ip_from_inspect() {
    assert(peer_ip_of(inspect(peer_v4(10, 0, 0, 4, 8080))) == "10.0.0.4");
    assert(peer_ip_of("127.0.0.1:1") == "127.0.0.1");
}

fn test_client_is_the_peer_without_trusted_proxies() {
    let spoofed = h("Host: t\r\nX-Forwarded-For: 6.6.6.6");
    assert(client_ip_of("203.0.113.9", spoofed, no_trusted_proxies()) ==
           "203.0.113.9");
    // a header from a peer that is not a trusted proxy is ignored
    let tp = tp_of("10.0.0.0/8");
    assert(client_ip_of("203.0.113.9", spoofed, tp) == "203.0.113.9");
}

fn test_client_from_a_trusted_proxy_chain() {
    let tp = tp_of("10.0.0.0/8");
    // one proxy
    assert(client_ip_of("10.0.0.2", h("X-Forwarded-For: 198.51.100.7"), tp) ==
           "198.51.100.7");
    // two trusted hops: the walk passes both
    assert(client_ip_of("10.0.0.2",
                        h("X-Forwarded-For: 198.51.100.7, 10.0.0.5"), tp) ==
           "198.51.100.7");
    // a client-written hop to the left of the real one never wins: the
    // rightmost untrusted address is what the trusted proxy saw
    assert(client_ip_of("10.0.0.2",
                        h("X-Forwarded-For: 1.1.1.1, 198.51.100.7"), tp) ==
           "198.51.100.7");
    // repeated lines are one list, in order, names case-insensitive
    assert(client_ip_of("10.0.0.2",
                        h("x-forwarded-for: 1.1.1.1\r\nX-FORWARDED-FOR: 198.51.100.7, 10.0.0.9"),
                        tp) == "198.51.100.7");
}

fn test_client_edge_cases_fall_back_to_what_is_trusted() {
    let tp = tp_of("10.0.0.0/8");
    // no header at all: the proxy itself
    assert(client_ip_of("10.0.0.2", h("Host: t"), tp) == "10.0.0.2");
    // a malformed hop stops the walk at the last trusted address
    assert(client_ip_of("10.0.0.2",
                        h("X-Forwarded-For: 198.51.100.7, garbage, 10.0.0.5"),
                        tp) == "10.0.0.5");
    // every hop trusted: the leftmost is the client
    assert(client_ip_of("10.0.0.2", h("X-Forwarded-For: 10.1.1.1, 10.0.0.5"),
                        tp) == "10.1.1.1");
}

fn test_only_the_configured_header_is_read() {
    let xff = tp_of("10.0.0.0/8");
    let fwd = tp_of("10.0.0.0/8");
    fwd.header = "forwarded";
    let both = h("Forwarded: for=6.6.6.6\r\nX-Forwarded-For: 198.51.100.7");
    assert(client_ip_of("10.0.0.2", both, xff) == "198.51.100.7");
    assert(client_ip_of("10.0.0.2", both, fwd) == "6.6.6.6");
    // RFC 7239 forms: quoted, with a port, with other parameters
    assert(client_ip_of("10.0.0.2",
                        h("Forwarded: for=\"198.51.100.7:4711\";proto=https, for=10.0.0.5"),
                        fwd) == "198.51.100.7");
}
