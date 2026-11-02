import "http";
import "httpc";
import "strings";
import "internal/trace" as tracewire;

fn test_traceparent_rejects_ambiguity_and_preserves_sampled_bit() {
    let good = tracewire.parent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-09");
    guard let p = good else { panic("valid parent rejected"); }
    assert(p.trace_id == "4bf92f3577b34da6a3ce929d0e0e4736" && p.sampled);
    for value in ["", "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                  "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
                  "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01",
                  "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
                  "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra"] {
        let r = tracewire.parent(value);
        guard let _v = r else { continue; }
        panic("invalid parent accepted: " + value);
    }
    let future = tracewire.parent("01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-future");
    guard let _f = future else { panic("future prefix rejected"); }
}

fn tracing_test_driver() -> Tracer {
    let r = new_tracer(trace_config());
    guard let t = r else let e = err_of(r) { panic(e); }
    return t;
}

fn tracing_test_context(t: Tracer, headers: bytes) -> TraceContext {
    let r = trace_context(t, headers);
    guard let ctx = r else let e = err_of(r) { panic(e); }
    return ctx;
}

fn tracing_failure(c: Ctx[int]) -> http.Response {
    let tc = c.trace();
    assert(tc.trace_id == "4bf92f3577b34da6a3ce929d0e0e4736");
    assert(tc.parent_id == "00f067aa0ba902b7" && tc.span_id != tc.parent_id);
    return respond(c.errors, "bad_request", c.request_id);
}

fn test_tracing_binds_error_registry_without_changing_shared_registry() {
    let r = new_router(0);
    r.tracing(tracing_test_driver());
    r.get("/fail", tracing_failure);
    let req = get_request("/fail").header("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01").build();
    let resp = r.serve(req);
    assert(strings.contains(resp_text(resp), "\"trace_id\":\"4bf92f3577b34da6a3ce929d0e0e4736\""), resp_text(resp));
    assert(r.errors.trace_id == "", "the startup registry is never mutated per request");
}

fn test_tracing_outbound_headers_are_private_and_get_a_child_span() {
    let tc = tracing_test_context(tracing_test_driver(), b"traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\ntracestate: vendor=value\r\n");
    let req = httpc.new_request("GET", "http://127.0.0.1/");
    req.headers["TraceParent"] = "stale";
    req.headers["X-Test"] = "kept";
    let made = trace_request(tc, req);
    guard let out = made else let e = err_of(made) { panic(e); }
    assert(req.headers["TraceParent"] == "stale" && !has(req.headers, "traceparent"));
    assert(!has(out.headers, "TraceParent") && out.headers["X-Test"] == "kept");
    assert(out.headers["tracestate"] == "vendor=value");
    let parsed = tracewire.parent(out.headers["traceparent"]);
    guard let p = parsed else { panic("outbound header invalid"); }
    assert(p.trace_id == tc.trace_id && p.span_id != tc.span_id && p.sampled);
}

fn test_tracing_generates_fresh_ids_for_missing_invalid_or_duplicate_parents() {
    let t = tracing_test_driver();
    let a = tracing_test_context(t, b"");
    let b = tracing_test_context(t, b"traceparent: invalid\r\ntracestate: vendor=secret\r\n");
    let c = tracing_test_context(t, b"traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\ntraceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\n");
    assert(len(a.trace_id) == 32 && len(a.span_id) == 16);
    assert(a.trace_id != b.trace_id && b.trace_id != c.trace_id);
    assert(!a.sampled && b.state == "" && c.trace_id != "4bf92f3577b34da6a3ce929d0e0e4736");
}

fn test_tracing_config_collects_errors_and_bounds_headers() {
    let cfg = trace_config();
    cfg.max_parent_bytes = 54; cfg.max_state_bytes = 513; cfg.max_state_members = 0;
    let bad = new_tracer(cfg);
    guard let _t = bad else let e = err_of(bad) {
        assert(strings.contains(e, "max_parent_bytes") && strings.contains(e, "max_state_bytes") && strings.contains(e, "max_state_members"), e);
        let good = trace_config();
        good.max_parent_bytes = 55; good.max_state_bytes = 8; good.max_state_members = 1;
        let made = new_tracer(good);
        guard let driver = made else { panic("valid config rejected"); }
        let ctx = tracing_test_context(driver, b"TraceParent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-fe\r\ntracestate: a=one\r\ntracestate: b=two\r\n");
        assert(ctx.trace_id == "4bf92f3577b34da6a3ce929d0e0e4736" && !ctx.sampled && ctx.state == "");
        let h = trace_header(ctx);
        assert(strings.has_suffix(h ?? "", "-00"));
        let future = tracing_test_context(driver, b"traceparent: 01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra\r\n");
        assert(future.parent_id == "");
        return;
    }
    panic("bad tracing config accepted");
}

fn tracing_frame_echo(c: Ctx[int]) -> http.Response {
    return text(200, c.trace().parent_id + "/" + c.trace().span_id);
}

fn test_tracing_frame_fallback_has_one_context() {
    let r = new_router(0);
    r.tracing(tracing_test_driver());
    r.get("/orgs/:org/users/:id", tracing_frame_echo);
    let f = frame_req("GET", "/orgs/1/users/2");
    f.headers = b"traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\n";
    let answer = r.serve_frame(f, "req");
    assert(strings.has_prefix(resp_text(answer), "00f067aa0ba902b7/"), resp_text(answer));
}

gc struct TraceLogState { log: Logger }

fn tracing_app_log(c: Ctx[TraceLogState]) -> http.Response {
    c.logger(c.state.log).log("Handler", "working");
    return respond(c.errors, "bad_request", c.request_id);
}

fn test_tracing_application_and_server_logs_correlate_errors_and_panics() {
    let ch: chan[LogEvent] = make_chan(16);
    let log = channel_logger(ch, LogLevel.LOG, true);
    let app = new_router(TraceLogState { log: log });
    app.tracing(tracing_test_driver());
    app.get("/fail", tracing_app_log);
    let resp = app.serve_id(get_request("/fail").header("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01").build(), "request-1");
    let ev = next_event(ch);
    assert(ev.trace_id == "4bf92f3577b34da6a3ce929d0e0e4736" && ev.request_id == "request-1");
    assert(strings.contains(resp_text(resp), ev.trace_id));
    let fmt = new_log_format(1);
    assert(strings.contains(fmt.json(ev), "\"trace_id\":\"" + ev.trace_id + "\""));
    assert(strings.contains(fmt.pretty(ev, false, 0), " trace=" + ev.trace_id));

    let r = panic_test_router();
    r.tracing(tracing_test_driver());
    r.static_bytes("/fixed", 200, "text/plain", b"hi", ok_hi);
    let sc = log_config(ch);
    let headers = " HTTP/1.1\r\nHost: t\r\nTraceParent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\nConnection: close\r\n\r\n";
    let normal = one_exchange(r, sc, "GET /missing" + headers);
    let rec = next_event(ch);
    assert(rec.status == 404 && rec.trace_id == ev.trace_id && strings.contains(normal, ev.trace_id));
    let failed = one_exchange(r, sc, "GET /boom" + headers);
    let line = next_event(ch);
    let panic_rec = next_event(ch);
    assert(line.trace_id == ev.trace_id && panic_rec.trace_id == ev.trace_id && strings.contains(failed, ev.trace_id));
    one_exchange(r, sc, "GET /fixed" + headers);
    let fixed = next_event(ch);
    assert(fixed.status == 200 && fixed.trace_id == ev.trace_id);
    assert(r.errors.trace_id == "");
}

fn tracing_concurrent_call(r: Router[TraceLogState], id: str) -> int {
    let i = 0;
    while i < 20 {
        let resp = r.serve_id(get_request("/fail").header("traceparent", "00-" + id + "-00f067aa0ba902b7-01").build(), id);
        assert(strings.contains(resp_text(resp), "\"trace_id\":\"" + id + "\""));
        i += 1;
    }
    return 0;
}

fn test_tracing_concurrent_requests_do_not_share_ids() {
    let ch: chan[LogEvent] = make_chan(64);
    let r = new_router(TraceLogState { log: channel_logger(ch, LogLevel.LOG, true) });
    r.tracing(tracing_test_driver());
    r.get("/fail", tracing_app_log);
    let a = spawn tracing_concurrent_call(r, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    let b = spawn tracing_concurrent_call(r, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    assert((join_wait(a) ?? -1) == 0 && (join_wait(b) ?? -1) == 0);
    let seen_a = 0;
    let seen_b = 0;
    let i = 0;
    while i < 40 {
        let ev = next_event(ch);
        assert(ev.trace_id == ev.request_id);
        if ev.trace_id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" { seen_a += 1; }
        if ev.trace_id == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" { seen_b += 1; }
        i += 1;
    }
    assert(seen_a == 20 && seen_b == 20 && r.errors.trace_id == "");
}

fn test_tracing_framing_error_uses_a_fresh_trace_and_shared_renderer() {
    let ch: chan[LogEvent] = make_chan(4);
    let sc = tiny_body_config();
    sc.logger = channel_logger(ch, LogLevel.LOG, true);
    let r = serve_test_router();
    r.tracing(tracing_test_driver());
    let resp = one_exchange(r, sc, "GET /hi HTTP/1.1\r\nHost: t\r\nX-Long: " + strings.repeat("a", 400));
    let ev = next_event(ch);
    assert(ev.status == 431 && len(ev.trace_id) == 32 && strings.contains(resp, ev.trace_id), resp);
}

fn tracing_custom_renderer(v: ErrorView) -> http.Response {
    return text(v.status, v.code + " " + v.trace_id);
}

fn test_tracing_custom_error_renderer_receives_the_context() {
    let r = new_router(0);
    r.tracing(tracing_test_driver());
    set_renderer(r.errors, tracing_custom_renderer);
    let req = get_request("/missing").header("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01").build();
    let resp = r.serve(req);
    assert(resp_text(resp) == "not_found 4bf92f3577b34da6a3ce929d0e0e4736", resp_text(resp));
}
