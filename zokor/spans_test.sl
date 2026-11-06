import "http";
import "httpc";
import "strings";
import "time";
import "timez";

// A collector: whatever is POSTed to it, kept to read back.
gc struct OtCollector {
    bodies: [str],
    paths: [str],
    auth: [str],
    lock: mutex,
    status: int,
}

fn ot_receive(c: Ctx[OtCollector]) -> http.Response {
    mutex_lock(c.state.lock);
    push(c.state.bodies, to_str(c.req.body));
    push(c.state.paths, c.req.path);
    push(c.state.auth, c.header("x-api-key"));
    let status = c.state.status;
    mutex_unlock(c.state.lock);
    return text(status as i32, "{}");
}

fn ot_serve_all(ln: link, r: Router[OtCollector], sc: ServerConfig) {
    let mut_ln = ln;
    while true {
        let ar = mut_ln.accept(until_never());
        guard let conn = ar else { return; }
        spawn serve_conn(r, conn, sc);
    }
}

fn ot_collector(status: int) -> OtPair {
    let no: [str] = [];
    let no2: [str] = [];
    let no3: [str] = [];
    let state = OtCollector { bodies: no, paths: no2, auth: no3, lock: make_mutex(), status: status };
    let r = new_router(state);
    r.post("/v1/traces", ot_receive);
    let sc = default_server_config();
    sc.logger = no_logger();
    let lr = link_listen(0);
    guard let ln = lr else { panic("listen"); }
    let port = ln.port();
    spawn ot_serve_all(ln, r, sc);
    return OtPair { state: state, url: "http://127.0.0.1:" + to_str(port) };
}

gc struct OtPair {
    state: OtCollector,
    url: str,
}

fn ot_exporter(url: str) -> SpanExporter {
    let cfg = span_exporter_config(url, "orders");
    cfg.flush_every = 10 * timez.MILLISECOND;
    let r = new_span_exporter(cfg);
    guard let e = r else let x = err_of(r) { panic(x); }
    return e;
}

fn ot_seen(p: OtPair) -> str {
    mutex_lock(p.state.lock);
    let out = strings.join(p.state.bodies, "\n");
    mutex_unlock(p.state.lock);
    return out;
}

gc struct OtApp {
    spans: SpanExporter,
    downstream: str,
}

fn ot_plain(c: Ctx[OtApp]) -> http.Response {
    return ok_json("{}");
}

fn ot_org(c: Ctx[OtApp]) -> http.Response {
    return ok_json("{}");
}

fn ot_boom(c: Ctx[OtApp]) -> http.Response {
    return respond(c.errors, "internal", c.request_id);
}

fn ot_nested(c: Ctx[OtApp]) -> http.Response {
    let sp = c.state.spans.start(c.trace(), "charge card");
    sp.attr("order", "42").attr_int("cents", 1999);
    let child = c.state.spans.start(sp.context(), "call bank");
    child.fail("declined").finish();
    sp.finish();
    sp.finish();
    return ok_json("{}");
}

fn ot_router(e: SpanExporter, ratio: float) -> Router[OtApp] {
    let cfg = trace_config();
    cfg.sample_ratio = ratio;
    let tr = new_tracer(cfg);
    guard let tracer = tr else let x = err_of(tr) { panic(x); }
    let r = new_router(OtApp { spans: e, downstream: "" });
    r.tracing(tracer);
    r.export_spans(e);
    r.get("/plain", ot_plain);
    r.get("/orgs/:id", ot_org);
    r.get("/boom", ot_boom);
    r.get("/nested", ot_nested);
    return r;
}

fn test_span_reaches_the_collector_at_its_otlp_path() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url + "/");
    let r = ot_router(e, 1.0);
    r.serve(get_request("/plain").build());
    assert(e.flush(2 * timez.SECOND));
    assert(e.stats().sent == 1);
    assert(contains(ot_seen(c), "\"name\":\"GET /plain\""));
    assert(contains(ot_seen(c), "\"stringValue\":\"orders\""));
    assert(c.state.paths[0] == "/v1/traces");
}

// A span name is a low-cardinality thing, and a URL can be personal data.
fn test_span_names_the_route_pattern_never_the_path() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url);
    let r = ot_router(e, 1.0);
    r.serve(get_request("/orgs/secret-tenant-7?token=abc").build());
    assert(e.flush(2 * timez.SECOND));
    let body = ot_seen(c);
    assert(contains(body, "GET /orgs/:id"));
    assert(!contains(body, "secret-tenant-7"));
    assert(!contains(body, "abc"));
}

fn test_span_marks_a_server_error_failed_and_a_good_one_not() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url);
    let r = ot_router(e, 1.0);
    r.serve(get_request("/plain").build());
    assert(e.flush(2 * timez.SECOND));
    assert(!contains(ot_seen(c), "\"status\""));
    r.serve(get_request("/boom").build());
    assert(e.flush(2 * timez.SECOND));
    assert(contains(ot_seen(c), "\"status\":{\"code\":2,\"message\":\"status 500\"}"));
}

fn test_span_is_a_child_of_the_callers_trace() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url);
    let r = ot_router(e, 0.0);
    r.serve(get_request("/plain")
        .header("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01").build());
    assert(e.flush(2 * timez.SECOND));
    let body = ot_seen(c);
    assert(contains(body, "\"traceId\":\"4bf92f3577b34da6a3ce929d0e0e4736\""));
    assert(contains(body, "\"parentSpanId\":\"00f067aa0ba902b7\""));
}

// A caller's decision not to sample stands, whatever the ratio here.
fn test_span_respects_a_parent_that_is_not_sampled() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url);
    let r = ot_router(e, 1.0);
    r.serve(get_request("/plain")
        .header("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00").build());
    assert(e.flush(2 * timez.SECOND));
    assert(e.stats().sent == 0);
}

fn test_span_ratio_zero_samples_no_new_trace() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url);
    let r = ot_router(e, 0.0);
    r.serve(get_request("/plain").build());
    assert(e.flush(2 * timez.SECOND));
    assert(e.stats().sent == 0);
}

fn test_manual_spans_nest_under_the_request_span() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url);
    let r = ot_router(e, 1.0);
    r.serve(get_request("/nested").build());
    assert(e.flush(2 * timez.SECOND));
    assert(e.stats().sent == 3);        // the second finish() sent nothing
    let body = ot_seen(c);
    assert(contains(body, "\"name\":\"charge card\""));
    assert(contains(body, "\"name\":\"call bank\""));
    assert(contains(body, "{\"key\":\"cents\",\"value\":{\"intValue\":\"1999\"}}"));
    assert(contains(body, "\"message\":\"declined\""));
}

fn test_unsampled_span_records_nothing_and_needs_no_check() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url);
    let ctx = empty_trace();
    let sp = e.start(ctx, "x");
    sp.attr("a", "b").attr_int("c", 1).fail("no").finish();
    assert(e.flush(2 * timez.SECOND));
    assert(e.stats().sent == 0);
}

fn ot_context(sampled: bool) -> TraceContext {
    return TraceContext { trace_id: "4bf92f3577b34da6a3ce929d0e0e4736", parent_id: "",
                          span_id: "00f067aa0ba902b7", sampled: sampled, state: "" };
}

gc struct OtEcho {
    got: chan[str],
}

fn ot_record_parent(c: Ctx[OtEcho]) -> http.Response {
    chan_send(c.state.got, c.header("traceparent"));
    return text(200, "ok");
}

fn ot_echo_serve(ln: link, r: Router[OtEcho], sc: ServerConfig) {
    let mut_ln = ln;
    while true {
        let ar = mut_ln.accept(until_never());
        guard let conn = ar else { return; }
        spawn serve_conn(r, conn, sc);
    }
}

fn ot_downstream(got: chan[str]) -> str {
    let r = new_router(OtEcho { got: got });
    r.get("/", ot_record_parent);
    let sc = default_server_config();
    sc.logger = no_logger();
    let lr = link_listen(0);
    guard let ln = lr else { panic("listen"); }
    let port = ln.port();
    spawn ot_echo_serve(ln, r, sc);
    return "http://127.0.0.1:" + to_str(port) + "/?secret=topsecret";
}

fn ot_get(url: str) -> httpc.Request {
    let h: map[str]str = {};
    return httpc.Request { method: "GET", url: url, headers: h, body: b"", max_redirects: 0,
                           ca_path: "" };
}

// The point of traced_send: the next service's parent is a span we sent.
fn test_traced_send_records_the_span_the_next_service_hangs_from() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url);
    let got: chan[str] = make_chan(1);
    let url = ot_downstream(got);
    let r = traced_send(e, ot_context(true), ot_get(url), until_of(time.mono() + 2000000000));
    guard let resp = r else let x = err_of(r) { panic(x); }
    assert(resp.status == 200);
    let header = chan_recv(got) ?? "";
    let parts = strings.split(header, "-");
    assert(len(parts) == 4);
    assert(parts[1] == "4bf92f3577b34da6a3ce929d0e0e4736");
    assert(e.flush(2 * timez.SECOND));
    let body = ot_seen(c);
    assert(contains(body, "\"spanId\":\"" + parts[2] + "\""));
    assert(contains(body, "\"parentSpanId\":\"00f067aa0ba902b7\""));
    assert(contains(body, "\"kind\":3"));
}

fn test_traced_send_keeps_secrets_in_the_url_off_the_span() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url);
    let got: chan[str] = make_chan(1);
    let url = ot_downstream(got);
    let r = traced_send(e, ot_context(true), ot_get(url), until_of(time.mono() + 2000000000));
    guard let _resp = r else let x = err_of(r) { panic(x); }
    assert(e.flush(2 * timez.SECOND));
    let body = ot_seen(c);
    assert(contains(body, "127.0.0.1"));
    assert(!contains(body, "topsecret"));
}

fn test_traced_send_marks_a_call_that_failed() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url);
    let r = traced_send(e, ot_context(true), ot_get("http://127.0.0.1:1/"),
                        until_of(time.mono() + 500000000));
    guard let _resp = r else {
        assert(e.flush(2 * timez.SECOND));
        assert(contains(ot_seen(c), "\"status\":{\"code\":2"));
        return;
    }
    assert(false);
}

fn test_traced_send_still_passes_on_an_unsampled_trace() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url);
    let got: chan[str] = make_chan(1);
    let url = ot_downstream(got);
    let r = traced_send(e, ot_context(false), ot_get(url), until_of(time.mono() + 2000000000));
    guard let _resp = r else let x = err_of(r) { panic(x); }
    let header = chan_recv(got) ?? "";
    assert(strings.has_suffix(header, "-00"));
    assert(e.flush(2 * timez.SECOND));
    assert(e.stats().sent == 0);
}

fn test_exporter_sends_its_headers_to_the_collector() {
    let c = ot_collector(200);
    let cfg = span_exporter_config(c.url, "orders");
    cfg.headers["x-api-key"] = "k-123";
    cfg.flush_every = 10 * timez.MILLISECOND;
    let r = new_span_exporter(cfg);
    guard let e = r else { assert(false); return; }
    e.start(ot_context(true), "x").finish();
    assert(e.flush(2 * timez.SECOND));
    assert(c.state.auth[0] == "k-123");
}

fn test_exporter_counts_what_a_collector_refuses() {
    let c = ot_collector(503);
    let e = ot_exporter(c.url);
    e.start(ot_context(true), "x").finish();
    assert(e.flush(2 * timez.SECOND));
    assert(e.stats().failed == 1 && e.stats().sent == 0);
}

fn test_exporter_counts_when_no_collector_answers() {
    let cfg = span_exporter_config("http://127.0.0.1:1", "orders");
    cfg.timeout = 200 * timez.MILLISECOND;
    let r = new_span_exporter(cfg);
    guard let e = r else { assert(false); return; }
    e.start(ot_context(true), "x").finish();
    assert(e.flush(2 * timez.SECOND));
    assert(e.stats().failed == 1);
}

// The promise that matters most: a span never costs a request.
fn test_exporter_never_waits_and_counts_what_it_drops() {
    let cfg = span_exporter_config("http://127.0.0.1:1", "orders");
    cfg.max_queue = 2;
    cfg.flush_every = timez.HOUR;
    cfg.max_batch = 1000;
    let r = new_span_exporter(cfg);
    guard let e = r else { assert(false); return; }
    let t0 = time.mono();
    let i = 0;
    while i < 200 {
        e.start(ot_context(true), "x").finish();
        i = i + 1;
    }
    assert(((time.mono() - t0) as int) < 100000000);
    assert(e.stats().dropped > 0);
}

fn test_exporter_batches_up_to_max_batch() {
    let c = ot_collector(200);
    let cfg = span_exporter_config(c.url, "orders");
    cfg.max_batch = 3;
    cfg.flush_every = timez.HOUR;
    let r = new_span_exporter(cfg);
    guard let e = r else { assert(false); return; }
    let i = 0;
    while i < 7 {
        e.start(ot_context(true), "x").finish();
        i = i + 1;
    }
    assert(e.flush(2 * timez.SECOND));
    assert(e.stats().sent == 7);
    mutex_lock(c.state.lock);
    let batches = len(c.state.bodies);
    mutex_unlock(c.state.lock);
    assert(batches == 3);
}

fn test_exporter_flush_gives_up_at_its_timeout() {
    let e = ot_exporter("http://10.255.255.1:9");
    e.start(ot_context(true), "x").finish();
    assert(!e.flush(20 * timez.MILLISECOND));
}

fn test_exporter_stop_ends_the_task_and_drops_what_comes_after() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url);
    e.start(ot_context(true), "before").finish();
    assert(e.flush(2 * timez.SECOND));
    e.stop();
    e.stop();
    e.start(ot_context(true), "after").finish();
    assert(e.stats().dropped == 1);
    assert(e.stats().sent == 1);
}

fn test_exporter_names_every_bad_setting_at_once() {
    let cfg = span_exporter_config("ftp://x", "");
    cfg.max_queue = 0;
    cfg.max_batch = 0;
    let r = new_span_exporter(cfg);
    guard let _e = r else let x = err_of(r) {
        assert(contains(x, "endpoint"));
        assert(contains(x, "service"));
        assert(contains(x, "max_queue"));
        assert(contains(x, "max_batch"));
        return;
    }
    assert(false);
}

fn test_exporter_reads_the_standard_otel_variables() {
    let c = ot_collector(200);
    let r = span_exporter_from(cfg_of("OTEL_EXPORTER_OTLP_ENDPOINT=" + c.url +
        "\nOTEL_SERVICE_NAME=billing\nOTEL_EXPORTER_OTLP_HEADERS=x-api-key=k-9\n"));
    guard let e = r else let x = err_of(r) { panic(x); }
    e.start(ot_context(true), "x").finish();
    assert(e.flush(7 * timez.SECOND));
    assert(contains(ot_seen(c), "\"stringValue\":\"billing\""));
    assert(c.state.auth[0] == "k-9");
}

fn test_exporter_refuses_malformed_otel_headers() {
    let r = span_exporter_from(cfg_of("OTEL_EXPORTER_OTLP_ENDPOINT=http://x\n" +
        "OTEL_SERVICE_NAME=s\nOTEL_EXPORTER_OTLP_HEADERS=no-equals\n"));
    guard let _e = r else let x = err_of(r) {
        assert(!contains(x, "no-equals"));
        return;
    }
    assert(false);
}

fn test_otel_headers_are_masked_in_config_problems() {
    assert(!contains(mask("OTEL_EXPORTER_OTLP_HEADERS", "api-key=s3cret"), "s3cret"));
}

fn test_tracer_refuses_a_ratio_outside_0_to_1() {
    let cfg = trace_config();
    cfg.sample_ratio = 1.5;
    let r = new_tracer(cfg);
    guard let _t = r else let x = err_of(r) {
        assert(contains(x, "sample_ratio"));
        return;
    }
    assert(false);
}

fn test_tracer_samples_about_its_ratio_of_new_traces() {
    let cfg = trace_config();
    cfg.sample_ratio = 0.25;
    let tr = new_tracer(cfg);
    guard let t = tr else { assert(false); return; }
    let hits = 0;
    let i = 0;
    while i < 2000 {
        let cr = trace_context(t, b"");
        guard let ctx = cr else { assert(false); return; }
        if ctx.sampled {
            hits = hits + 1;
        }
        i = i + 1;
    }
    assert(hits > 350 && hits < 650);
}

gc struct OtServe {
    n: int,
}

fn ot_panics(c: Ctx[OtServe]) -> http.Response {
    let empty: [int] = [];
    return ok_json(to_str(empty[3]));
}

fn ot_fine(c: Ctx[OtServe]) -> http.Response {
    return ok_json("{}");
}

fn ot_serve_real(ln: link, r: Router[OtServe], sc: ServerConfig) {
    let mut_ln = ln;
    while true {
        let ar = mut_ln.accept(until_never());
        guard let conn = ar else { return; }
        spawn serve_conn(r, conn, sc);
    }
}

// The real serve loop has its own exits, and a panic is one of them.
fn test_span_is_recorded_through_the_serve_loop_even_on_a_panic() {
    let c = ot_collector(200);
    let e = ot_exporter(c.url);
    let cfg = trace_config();
    cfg.sample_ratio = 1.0;
    let tr = new_tracer(cfg);
    guard let tracer = tr else { assert(false); return; }
    let r = new_router(OtServe { n: 0 });
    r.tracing(tracer);
    r.export_spans(e);
    r.get("/fine", ot_fine);
    r.get("/panics", ot_panics);
    let sc = default_server_config();
    sc.logger = no_logger();
    let lr = link_listen(0);
    guard let ln = lr else { panic("listen"); }
    let port = ln.port();
    spawn ot_serve_real(ln, r, sc);
    let base = "http://127.0.0.1:" + to_str(port);
    let fine = httpc.send(ot_get(base + "/fine"), until_of(time.mono() + 2000000000));
    guard let good = fine else let x = err_of(fine) { panic(x); }
    assert(good.status == 200);
    let bad = httpc.send(ot_get(base + "/panics"), until_of(time.mono() + 2000000000));
    guard let broken = bad else let x = err_of(bad) { panic(x); }
    assert(broken.status == 500);
    assert(e.flush(2 * timez.SECOND));
    assert(e.stats().sent == 2);
    let body = ot_seen(c);
    assert(contains(body, "\"name\":\"GET /fine\""));
    assert(contains(body, "\"status\":{\"code\":2,\"message\":\"status 500\"}"));
}
