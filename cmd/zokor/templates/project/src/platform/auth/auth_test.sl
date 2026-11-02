import "http";
import "zokor";
import "../app" as app;
import "../config" as config;

fn whoami(c: zokor.Ctx[app.App]) -> http.Response {
    return zokor.text(200, c.local("tenant_id"));
}

fn guarded() -> zokor.Router[app.App] {
    let m: map[str]str = {};
    m["PORT"] = "8080";
    m["API_KEYS"] = "acme:acme-key-0123456789abcdef012345";
    let r = zokor.new_router(app.for_tests(config.settings_from(zokor.config_from_values(m))));
    r.before(require_tenant);
    r.get("/whoami", whoami);
    return r;
}

fn test_a_known_key_names_its_tenant() {
    let r = guarded().serve(zokor.get_request("/whoami")
                            .header("x-api-key", "acme-key-0123456789abcdef012345").build());
    assert(zokor.resp_status(r) == 200 && zokor.resp_text(r) == "acme", zokor.resp_text(r));
}

fn test_a_missing_or_wrong_key_is_401() {
    let none_given = guarded().serve(zokor.get_request("/whoami").build());
    assert(zokor.resp_status(none_given) == 401);
    let wrong = guarded().serve(zokor.get_request("/whoami").header("x-api-key", "nope").build());
    assert(zokor.resp_status(wrong) == 401);
}
