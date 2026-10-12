import "http";
import "time";

gc struct HcState {
    lock: mutex,
    calls: int,
    up: bool,
    slow_ns: int,
}

fn hc_state() -> HcState {
    return HcState { lock: make_mutex(), calls: 0, up: true, slow_ns: 0 };
}

fn hc_calls(s: HcState) -> int {
    mutex_lock(s.lock);
    let n = s.calls;
    mutex_unlock(s.lock);
    return n;
}

fn hc_db(s: HcState) -> result[int, str] {
    mutex_lock(s.lock);
    s.calls = s.calls + 1;
    let up = s.up;
    let slow = s.slow_ns;
    mutex_unlock(s.lock);
    if slow > 0 {
        time.sleep(slow);
    }
    if !up {
        return err("dial tcp 10.0.0.9:5432: connection refused (user=svc)");
    }
    return ok(0);
}

fn hc_always(s: HcState) -> result[int, str] {
    return ok(0);
}

fn hc_panics(s: HcState) -> result[int, str] {
    let xs: [int] = [];
    return ok(xs[3]);
}

fn hc_router(s: HcState) -> Router[HcState] {
    let r = new_router(s);
    assert(r.health() > 0);
    return r;
}

fn hc_get(r: Router[HcState], p: str) -> http.Response {
    return r.serve(get_request(p).build());
}

fn test_healthz_answers_ok_without_adding_routes() {
    let r = hc_router(hc_state());
    let resp = hc_get(r, "/healthz");
    assert(resp_status(resp) == 200);
    assert(resp_text(resp) == "{\"status\":\"ok\"}", resp_text(resp));
    assert(len(r.routes) == 0);
}

fn test_unmounted_health_paths_are_404() {
    let r = new_router(hc_state());
    assert(resp_status(hc_get(r, "/healthz")) == 404);
    assert(resp_status(hc_get(r, "/readyz")) == 404);
}

fn hc_mine(c: Ctx[HcState]) -> http.Response {
    return text(200, "mine");
}

fn test_a_service_route_at_the_same_path_wins() {
    let r = hc_router(hc_state());
    r.get("/healthz", hc_mine);
    assert(resp_text(hc_get(r, "/healthz")) == "mine");
}

fn hc_refuse_all(c: Ctx[HcState]) -> opt[http.Response] {
    return some(respond(c.errors, "unauthorized", c.request_id));
}

fn test_probes_skip_befores() {
    let r = hc_router(hc_state());
    r.before(hc_refuse_all);
    assert(resp_status(hc_get(r, "/healthz")) == 200);
    assert(resp_status(hc_get(r, "/readyz")) == 200);
    assert(resp_status(hc_get(r, "/other")) == 404);
}

fn test_head_has_no_body_and_other_methods_are_405() {
    let r = hc_router(hc_state());
    let h = r.serve(request(Method.HEAD, "/readyz").build());
    assert(resp_status(h) == 200);
    assert(len(h.body) == 0);
    let p = r.serve(request(Method.POST, "/healthz").build());
    assert(resp_status(p) == 405);
    assert(resp_header(p, "allow") == "GET, HEAD", resp_header(p, "allow"));
}

fn test_probe_query_strings_are_ignored() {
    let r = hc_router(hc_state());
    assert(resp_status(hc_get(r, "/readyz?verbose=1")) == 200);
}

fn test_healthz_ignores_failing_dependencies() {
    let s = hc_state();
    s.up = false;
    let r = hc_router(s);
    assert(r.ready_check("db", hc_db) == 1);
    assert(resp_status(hc_get(r, "/healthz")) == 200);
    assert(resp_status(hc_get(r, "/readyz")) == 503);
}

fn test_readyz_without_checks_is_ready() {
    let r = hc_router(hc_state());
    let resp = hc_get(r, "/readyz");
    assert(resp_status(resp) == 200);
    assert(resp_text(resp) == "{\"status\":\"ok\",\"checks\":{}}", resp_text(resp));
}

fn test_readyz_names_each_check() {
    let r = hc_router(hc_state());
    r.ready_check("db", hc_db);
    r.ready_check("cache", hc_always);
    let resp = hc_get(r, "/readyz");
    assert(resp_status(resp) == 200);
    assert(resp_text(resp) == "{\"status\":\"ok\",\"checks\":{\"db\":\"ok\",\"cache\":\"ok\"}}",
           resp_text(resp));
}

fn test_readyz_503_when_a_check_fails_without_leaking_why() {
    let s = hc_state();
    s.up = false;
    let r = hc_router(s);
    r.ready_check("db", hc_db);
    r.ready_check("cache", hc_always);
    let resp = hc_get(r, "/readyz");
    assert(resp_status(resp) == 503);
    let body = resp_text(resp);
    assert(body == "{\"status\":\"unavailable\",\"checks\":{\"db\":\"failing\",\"cache\":\"ok\"}}", body);
    assert(!contains(body, "10.0.0.9"), "the driver's error text must not reach the client");
}

fn test_readyz_recovers_when_the_dependency_does() {
    let s = hc_state();
    s.up = false;
    let r = hc_router(s);
    r.ready_check("db", hc_db);
    assert(resp_status(hc_get(r, "/readyz")) == 503);
    mutex_lock(s.lock);
    s.up = true;
    mutex_unlock(s.lock);
    assert(resp_status(hc_get(r, "/readyz")) == 200);
    assert(hc_calls(s) == 2, "each probe runs the check afresh");
}

fn test_a_panicking_check_fails_the_check_not_the_probe() {
    let r = hc_router(hc_state());
    r.ready_check("broken", hc_panics);
    r.ready_check("cache", hc_always);
    let resp = hc_get(r, "/readyz");
    assert(resp_status(resp) == 503);
    assert(resp_text(resp) == "{\"status\":\"unavailable\",\"checks\":{\"broken\":\"failing\",\"cache\":\"ok\"}}",
           resp_text(resp));
    // and the check is usable again on the next probe
    assert(resp_status(hc_get(r, "/readyz")) == 503);
}

fn test_a_slow_check_times_out_and_is_not_restarted_while_running() {
    let s = hc_state();
    s.slow_ns = 300000000;
    let r = hc_router(s);
    r.ready_check("db", hc_db);
    assert(r.ready_timeout(20000000) == 20000000);
    let t0 = time.mono();
    let resp = hc_get(r, "/readyz");
    let took = (time.mono() - t0) as int;
    assert(resp_status(resp) == 503);
    assert(resp_text(resp) == "{\"status\":\"unavailable\",\"checks\":{\"db\":\"timeout\"}}",
           resp_text(resp));
    assert(took < 200000000, "the probe waited " + to_str(took) + "ns, past its timeout");
    // A second probe while the first run is still going joins it.
    assert(resp_status(hc_get(r, "/readyz")) == 503);
    assert(hc_calls(s) == 1, "a hung check must cost one task, not one per probe");
    // Once that run finishes, the next probe starts a fresh one.
    mutex_lock(s.lock);
    s.slow_ns = 0;
    mutex_unlock(s.lock);
    time.sleep(400000000);
    assert(resp_status(hc_get(r, "/readyz")) == 200);
    assert(hc_calls(s) == 2);
}

fn test_ready_timeout_has_a_floor() {
    let r = hc_router(hc_state());
    assert(r.ready_timeout(0) == 1000000);
    assert(r.ready_timeout(-5) == 1000000);
}

fn test_ready_check_refuses_bad_and_duplicate_names() {
    let r = hc_router(hc_state());
    assert(r.ready_check("", hc_always) == -1);
    assert(r.ready_check("has space", hc_always) == -1);
    assert(r.ready_check("quote\"", hc_always) == -1);
    assert(r.ready_check("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", hc_always) == -1);
    assert(r.ready_check("pg-main.v2_x", hc_always) == 1);
    assert(r.ready_check("pg-main.v2_x", hc_db) == -1);
    assert(len(r.ready.checks) == 1);
}

fn test_health_at_custom_paths() {
    let r = new_router(hc_state());
    assert(r.health_at("/livez", "/internal/ready") > 0);
    assert(resp_status(hc_get(r, "/livez")) == 200);
    assert(resp_status(hc_get(r, "/internal/ready")) == 200);
    assert(resp_status(hc_get(r, "/healthz")) == 404);
}

fn test_health_at_refuses_relative_or_identical_paths() {
    let r = new_router(hc_state());
    assert(r.health_at("healthz", "/readyz") == -1);
    assert(r.health_at("/healthz", "") == -1);
    assert(r.health_at("/same", "/same") == -1);
    assert(resp_status(hc_get(r, "/readyz")) == 404, "nothing is half-mounted");
}
