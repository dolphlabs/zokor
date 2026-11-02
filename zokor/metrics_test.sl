import "http";
import "strings";
import "time";

fn metrics_test_store() -> Metrics {
    let made = new_metrics(metrics_config());
    guard let m = made else let e = err_of(made) { panic(e); }
    return m;
}

fn metrics_ok(c: Ctx[int]) -> http.Response { return text(200, "ok"); }
fn metrics_panic(c: Ctx[int]) -> http.Response { panic("metrics handler"); }

fn test_metrics_are_opt_in_and_use_route_patterns() {
    let r = new_router(0);
    r.get("/users/:id", metrics_ok);
    assert(r.serve(get_request("/metrics").build()).status == 404);
    let m = metrics_test_store();
    r.metrics(m);
    r.serve(get_request("/users/123").build());
    r.serve(get_request("/users/456").build());
    r.serve(get_request("/missing/789").build());
    let resp = r.serve(get_request("/metrics").build());
    let body = resp_text(resp);
    assert(resp.status == 200 && strings.contains(resp.content_type, "version=0.0.4"));
    assert(strings.contains(body, "zokor_http_requests_total{method=\"GET\",route=\"/users/:id\",status=\"200\"} 2\n"), body);
    assert(!strings.contains(body, "/users/123") && !strings.contains(body, "/users/456") && !strings.contains(body, "/missing/789"));
    assert(strings.contains(body, "zokor_http_in_flight 0\n"), body);
    assert(strings.contains(body, "le=\"+Inf\"}"));
}

fn test_metrics_histograms_caps_and_custom_values() {
    let cfg = metrics_config();
    cfg.buckets_ns = [1000000, 10000000];
    cfg.max_series = 1;
    let made = new_metrics(cfg);
    guard let m = made else let e = err_of(made) { panic(e); }
    m.enter(); m.leave("GET", "/x\"\\\n", 200, 500000);
    m.enter(); m.leave("GET", "/x\"\\\n", 200, 5000000);
    m.enter(); m.leave("GET", "/new", 404, 1);
    let cr = m.counter("service_jobs_total", "jobs\ncompleted");
    guard let counter = cr else let e = err_of(cr) { panic(e); }
    assert((counter.add(3) ?? false));
    assert(!(counter.add(-1) ?? false));
    let gr = m.gauge("service_queue_depth", "queued jobs");
    guard let gauge = gr else let e = err_of(gr) { panic(e); }
    gauge.set(7);
    let body = metrics_text(m);
    assert(strings.contains(body, "le=\"0.001\"} 1\n"), body);
    assert(strings.contains(body, "le=\"0.01\"} 2\n"), body);
    assert(strings.contains(body, "zokor_http_observations_dropped_total 1\n"), body);
    assert(strings.contains(body, "service_jobs_total 3\n") && strings.contains(body, "service_queue_depth 7\n"));
    assert(strings.contains(body, "route=\"/x\\\"\\\\\\n\""), body);
    let duplicate = m.gauge("service_jobs_total", "duplicate");
    guard let _v = duplicate else { return; }
    panic("duplicate metric registered");
}

fn metrics_calls(m: Metrics) -> int {
    let i = 0;
    while i < 1000 { m.enter(); m.leave("GET", "/jobs", 200, 10); i += 1; }
    return 0;
}

fn test_metrics_concurrent_updates_are_exact() {
    let m = metrics_test_store();
    let a = spawn metrics_calls(m);
    let b = spawn metrics_calls(m);
    join_wait(a); join_wait(b);
    let body = metrics_text(m);
    assert(strings.contains(body, "status=\"200\"} 2000\n"), body);
    assert(strings.contains(body, "zokor_http_in_flight 0\n"));
}

fn metrics_throwing_call(r: Router[int]) -> int {
    r.serve(get_request("/boom").build());
    return 0;
}

fn test_metrics_balance_direct_panics_and_frame_fallbacks() {
    let r = new_router(0);
    let m = metrics_test_store();
    r.metrics(m);
    r.get("/boom", metrics_panic);
    r.get("/orgs/:org/users/:id", metrics_ok);
    let failed = join_wait(spawn metrics_throwing_call(r));
    guard let _ok = failed else {
        r.serve_frame(frame_req("GET", "/orgs/1/users/2"), "");
        let body = metrics_text(m);
        assert(strings.contains(body, "route=\"/boom\",status=\"500\"} 1\n"), body);
        assert(strings.contains(body, "route=\"/orgs/:org/users/:id\",status=\"200\"} 1\n"), body);
        assert(strings.contains(body, "zokor_http_in_flight 0\n"));
        return;
    }
    panic("direct handler panic was swallowed");
}

fn test_metrics_count_server_static_dynamic_and_panics_once() {
    let r = panic_test_router();
    let m = metrics_test_store();
    r.metrics(m);
    r.static_bytes("/fixed", 200, "text/plain", b"hi", ok_hi);
    let sc = default_server_config();
    sc.logger = no_logger();
    assert(strings.contains(one_exchange(r, sc, "GET /hi HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"), "200 OK"));
    assert(strings.contains(one_exchange(r, sc, "GET /fixed HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"), "200 OK"));
    assert(strings.contains(one_exchange(r, sc, "GET /boom HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"), "500 Internal"));
    // The peer can read the response just before its serving task records
    // completion; joining all tasks would include unrelated logger tasks.
    let deadline = time.mono() + 1000000000;
    let body = metrics_text(m);
    while !strings.contains(body, "route=\"/boom\",status=\"500\"} 1\n") && time.mono() < deadline {
        time.sleep(1000000);
        body = metrics_text(m);
    }
    assert(strings.contains(body, "route=\"/hi\",status=\"200\"} 1\n"), body);
    assert(strings.contains(body, "route=\"/fixed\",status=\"200\"} 1\n"), body);
    assert(strings.contains(body, "route=\"/boom\",status=\"500\"} 1\n"), body);
    assert(strings.contains(body, "zokor_http_in_flight 0\n"), body);
}

gc struct MetricsBlocked { started: chan[int], resume: chan[int] }

fn metrics_block(c: Ctx[MetricsBlocked]) -> http.Response {
    chan_send(c.state.started, 1);
    chan_recv(c.state.resume);
    return text(200, "done");
}

fn metrics_block_call(r: Router[MetricsBlocked]) -> int {
    r.serve(get_request("/blocked").build());
    return 0;
}

fn test_metrics_scrape_sees_an_in_flight_handler_and_does_not_count_itself() {
    let started: chan[int] = make_chan(1);
    let resume: chan[int] = make_chan(1);
    let r = new_router(MetricsBlocked { started: started, resume: resume });
    let m = metrics_test_store();
    r.metrics(m);
    r.get("/blocked", metrics_block);
    let running = spawn metrics_block_call(r);
    chan_recv(started);
    let body = resp_text(r.serve(get_request("/metrics").build()));
    assert(strings.contains(body, "zokor_http_in_flight 1\n"), body);
    assert(!strings.contains(body, "route=\"/metrics\""), body);
    chan_send(resume, 1);
    join_wait(running);
    assert(strings.contains(metrics_text(m), "zokor_http_in_flight 0\n"));
}

fn test_metrics_config_reports_every_bad_field() {
    let cfg = metrics_config();
    cfg.path = "/metrics\n";
    cfg.max_series = 0;
    cfg.max_custom = 0;
    cfg.buckets_ns = [0, 0];
    let r = new_metrics(cfg);
    guard let _m = r else let e = err_of(r) {
        assert(strings.contains(e, "path") && strings.contains(e, "max_series") && strings.contains(e, "max_custom"), e);
        assert(strings.contains(e, "buckets_ns[0]") && strings.contains(e, "buckets_ns[1]"), e);
        return;
    }
    panic("invalid metrics configuration accepted");
}
