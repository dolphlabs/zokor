import "strings";

fn is_generated(id: str) -> bool {
    if len(id) != 36 || !strings.has_prefix(id, "req_") {
        return false;
    }
    let b = to_bytes(id);
    let i = 4;
    while i < len(b) {
        let c = b[i];
        if !((c >= 48 && c <= 57) || (c >= 97 && c <= 102)) {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn hdrs(lines: str) -> bytes {
    return to_bytes(lines);
}

fn test_request_id_generated_when_absent() {
    let a = request_id_for(hdrs("Host: t\r\nAccept: */*"));
    let b = request_id_for(hdrs("Host: t"));
    assert(is_generated(a));
    assert(is_generated(b));
    assert(a != b);
}

fn test_request_id_reused_when_well_formed() {
    assert(request_id_for(hdrs("Host: t\r\nX-Request-Id: abc-123.DEF_9")) ==
           "abc-123.DEF_9");
    // header names are case-insensitive, and OWS around the value goes
    assert(request_id_for(hdrs("x-request-id:   trace.1\t")) == "trace.1");
    // a repeated field reads from its last line, as http.header does
    assert(request_id_for(hdrs("X-Request-Id: first\r\nX-Request-Id: second")) ==
           "second");
    let max = strings.repeat("a", 64);
    assert(request_id_for(hdrs("X-Request-Id: " + max)) == max);
}

fn test_request_id_replaced_when_not_well_formed() {
    let bad = [
        "X-Request-Id: ",
        "X-Request-Id: two words",
        "X-Request-Id: semi;colon",
        "X-Request-Id: <script>",
        "X-Request-Id: " + strings.repeat("a", 65),
        "X-Request-Id: tab\tinside"
    ];
    for h in bad {
        let id = request_id_for(hdrs(h));
        if !is_generated(id) {
            panic("kept a malformed id from '" + h + "': " + id);
        }
    }
    // a control byte in the value
    let ctl = to_bytes("X-Request-Id: abc");
    ctl[len(ctl) - 1] = 1;
    assert(is_generated(request_id_for(ctl)));
}

fn test_a_connections_request_ids_are_well_formed_and_distinct() {
    // 100 crosses the 32-id batch three times: a refill must not repeat
    // or truncate an id.
    let ids = request_ids();
    let seen: map[str]bool = {};
    let i = 0;
    while i < 100 {
        let id = ids.next();
        assert(is_generated(id), "malformed: " + id);
        assert(!has(seen, id), "repeated: " + id);
        seen[id] = true;
        i = i + 1;
    }
    // two connections do not share a sequence
    assert(request_ids().next() != request_ids().next());
}

fn test_request_id_with_keeps_the_clients_id() {
    let ids = request_ids();
    assert(request_id_with(hdrs("X-Request-Id: abc-123"), ids) == "abc-123");
    assert(is_generated(request_id_with(hdrs("X-Request-Id: two words"), ids)));
    assert(is_generated(request_id_with(hdrs("Host: t"), ids)));
}
