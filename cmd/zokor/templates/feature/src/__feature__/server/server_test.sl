import "http";
import "zokor";
import "../../platform/app" as app;
import "../../platform/config" as config;

// The routes through the real router pipeline -- auth, decoding, the use
// cases, the memory store -- without a socket.

fn key_a() -> str { return "acme-0123456789abcdef0123456789"; }
fn key_b() -> str { return "globex-0123456789abcdef01234567"; }

fn router_under_test() -> zokor.Router[app.App] {
    let m: map[str]str = {};
    m["PORT"] = "8080";
    m["API_KEYS"] = "acme:" + key_a() + ",globex:" + key_b();
    let cfg = zokor.config_from_values(m);
    let r = zokor.new_router(app.for_tests(config.settings_from(cfg)));
    mount(r);
    return r;
}

fn post___entity__(r: zokor.Router[app.App], key: str, body: str) -> http.Response {
    return r.serve(zokor.request(zokor.Method.POST, "/__feature__").header("x-api-key", key)
                   .json_body(body).build());
}

fn test_one___entity___round_trips_for_its_tenant_only() {
    let r = router_under_test();
    let made = post___entity__(r, key_a(), "{\"title\":\"plan\",\"body\":\"ship it\"}");
    assert(zokor.resp_status(made) == 201, zokor.resp_text(made));
    let id = zokor.resp_json(made).get("id").str_or("");
    let mine = r.serve(zokor.get_request("/__feature__/" + id).header("x-api-key", key_a()).build());
    assert(zokor.resp_status(mine) == 200 && zokor.resp_json(mine).get("title").str_or("") == "plan");
    let theirs = r.serve(zokor.get_request("/__feature__/" + id).header("x-api-key", key_b()).build());
    assert(zokor.resp_status(theirs) == 404 && zokor.resp_error_code(theirs) == "__feature__.not_found");
}

fn test_no_key_is_401_and_reaches_nothing() {
    let r = router_under_test();
    let denied = r.serve(zokor.get_request("/__feature__").build());
    assert(zokor.resp_status(denied) == 401, zokor.resp_text(denied));
}

fn test_bad_bodies_name_their_fields() {
    let r = router_under_test();
    let missing = post___entity__(r, key_a(), "{\"title\":\"x\"}");
    assert(zokor.resp_status(missing) == 422);
    assert(zokor.resp_error_fields(missing)[0] == "body", inspect(zokor.resp_error_fields(missing)));
    let empty = post___entity__(r, key_a(), "{\"title\":\"\",\"body\":\"\"}");
    assert(zokor.resp_error_fields(empty)[0] == "title");
}

fn test_listing_is_paged_and_bounded() {
    let r = router_under_test();
    for t in ["a", "b", "c"] {
        let _m = post___entity__(r, key_a(), "{\"title\":\"" + t + "\",\"body\":\"\"}");
    }
    let page = r.serve(zokor.get_request("/__feature__?offset=1&limit=1").header("x-api-key", key_a()).build());
    let data = zokor.resp_json(page).get("data");
    assert(data.size() == 1 && data.at(0).get("title").str_or("") == "b", zokor.resp_text(page));
    let too_many = r.serve(zokor.get_request("/__feature__?limit=1000").header("x-api-key", key_a()).build());
    assert(zokor.resp_status(too_many) == 422);
}
