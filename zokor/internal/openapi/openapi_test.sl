fn test_route_templates_follow_router_segment_normalization() {
    let made = route("GET /orgs//:org/users/:id/", 1000);
    guard let r = made else let e = err_of(made) { panic(e); }
    assert(r.method == "get" && r.template == "/orgs/{org}/users/{id}" && r.shape == "/orgs/{}/users/{}");
    assert(len(r.names) == 2 && r.names[0] == "org" && r.names[1] == "id");
}

fn test_routes_refuse_unsupported_or_ambiguous_shapes() {
    for line in ["CONNECT /", "GET /files/*rest", "GET /:id/:id", "GET /{id}", "GET /q?x=1", "GET x", "GET /:bad name", "GET /a\n"] {
        let made = route(line, 1000);
        guard let _r = made else { continue; }
        panic("invalid route accepted: " + line);
    }
}

fn test_names_and_order_are_stable() {
    assert(name_ok("user.v1-id_2") && !name_ok("bad/name") && !name_ok(""));
    let names = ordered(["z", "a", "b"]);
    assert(names[0] == "a" && names[1] == "b" && names[2] == "z");
}

fn test_ordering_handles_large_input_without_changing_the_source() {
    let names: [str] = [];
    let i = 999;
    while i >= 0 { push(names, "name-" + to_str(i)); i -= 1; }
    let sorted = ordered(names);
    assert(names[0] == "name-999" && sorted[0] == "name-0");
    i = 1;
    while i < len(sorted) { assert(sorted[i - 1] <= sorted[i]); i += 1; }
}

fn test_route_segment_count_is_bounded_before_materializing_segments() {
    let made = route("GET /a/b/c", 2);
    guard let _r = made else let e = err_of(made) { assert(e == "path segments exceed max_collection_entries"); return; }
    panic("segment cap ignored");
}
