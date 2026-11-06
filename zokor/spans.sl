// Sending spans to a collector: Jaeger, Tempo, Datadog, Honeycomb, anything
// that takes OTLP/HTTP.
//
//     let cfg = zokor.trace_config();
//     cfg.sample_ratio = 0.1;                     // a tenth of new traces
//     r.tracing(zokor.new_tracer(cfg)?);
//
//     let er = zokor.span_exporter_from(config);  // OTEL_* variables
//     r.export_spans(er?);
//
// Every sampled request is then a server span, named for its route pattern
// and never for its path, so an id in a URL is neither a new span name nor
// a piece of personal data sent to a vendor. Inside a handler:
//
//     let sp = c.state.spans.start(c.trace(), "charge card");
//     ...
//     sp.attr("order", to_str(id));
//     sp.finish();
//
// An outbound call goes through traced_send, which records the call as a
// span and tells the next service so, which is what joins two services'
// spans into one trace. trace_request alone passes the trace on, but under a
// span nobody records, so the tree has a hole there.
//
// A span must never cost a request. So a finished span goes on a bounded
// queue and a task sends batches: a slow collector backs up that queue, and
// a full queue drops spans and counts them. Nothing waits and nothing
// retries; the numbers are in `stats`. Call flush before the process exits,
// or the last batch is lost.

import "builder";
import "http";
import "httpc";
import "internal/trace" as tracewire;
import "strings";
import "time";
import "timez";

// How an exporter behaves. Every limit is here to change.
pub gc struct SpanExporterConfig {
    // The collector's base URL; /v1/traces is added.
    endpoint: str,
    service: str,
    // Sent with every batch: often an API key, so never logged.
    headers: map[str]str,
    max_queue: int,
    max_batch: int,
    flush_every: int,
    timeout: int,
}

pub struct SpanStats {
    sent: int,
    // Not sent: the queue was full.
    dropped: int,
    // Sent to a collector that refused or did not answer.
    failed: int,
}

pub gc struct SpanExporter {
    url: str,
    service: str,
    headers: map[str]str,
    max_batch: int,
    flush_every: int,
    timeout: int,
    outbox: chan[str],
    lock: mutex,
    // Spans queued or being sent: flush waits for this to reach 0.
    pending: int,
    // flush() calls waiting. Held for the whole wait, not consumed by the
    // first batch: a queue longer than max_batch takes several.
    flushing: int,
    stopped: bool,
    sent: int,
    dropped: int,
    failed: int,
    logger: Logger,
}

// One span in progress. Not for sharing between tasks.
pub gc struct Span {
    exporter: SpanExporter,
    ctx: TraceContext,
    data: tracewire.SpanData,
    done: bool,
}

// Wall-clock nanoseconds, which is what a span's times are.
fn span_clock() -> int {
    return timez.now().unix_nano();
}

// Defaults for this collector and service name.
pub fn span_exporter_config(endpoint: str, service: str) -> SpanExporterConfig {
    let h: map[str]str = {};
    return SpanExporterConfig { endpoint: endpoint, service: service, headers: h,
        max_queue: 2048, max_batch: 512, flush_every: 5 * timez.SECOND,
        timeout: 10 * timez.SECOND };
}

fn exporter_problems(cfg: SpanExporterConfig) -> [str] {
    let out: [str] = [];
    let scheme_ok = strings.has_prefix(cfg.endpoint, "http://") ||
                    strings.has_prefix(cfg.endpoint, "https://");
    if !scheme_ok || len(tracewire.url_host(cfg.endpoint)) == 0 {
        push(out, "endpoint must be an http or https URL");
    }
    if len(cfg.service) == 0 {
        push(out, "service must not be empty");
    }
    if cfg.max_queue < 1 {
        push(out, "max_queue must be at least 1");
    }
    if cfg.max_batch < 1 {
        push(out, "max_batch must be at least 1");
    }
    if cfg.flush_every < timez.MILLISECOND {
        push(out, "flush_every must be at least 1ms");
    }
    if cfg.timeout < timez.MILLISECOND {
        push(out, "timeout must be at least 1ms");
    }
    return out;
}

// Starts an exporter and its sending task. err naming every problem.
pub fn new_span_exporter(cfg: SpanExporterConfig) -> result[SpanExporter, str] {
    let problems = exporter_problems(cfg);
    if len(problems) > 0 {
        return err("span exporter: " + strings.join(problems, "; "));
    }
    let base = cfg.endpoint;
    while strings.has_suffix(base, "/") {
        base = strings.slice(base, 0, len(base) - 1);
    }
    let box: chan[str] = make_chan(cfg.max_queue);
    let e = SpanExporter {
        url: base + "/v1/traces", service: cfg.service, headers: cfg.headers,
        max_batch: cfg.max_batch, flush_every: cfg.flush_every, timeout: cfg.timeout,
        outbox: box, lock: make_mutex(), pending: 0, flushing: 0, stopped: false,
        sent: 0, dropped: 0, failed: 0, logger: no_logger()
    };
    spawn span_sender(e);
    return ok(e);
}

// `k=v,k2=v2`, the form of OTEL_EXPORTER_OTLP_HEADERS.
fn otlp_headers(raw: str) -> result[map[str]str, str] {
    let out: map[str]str = {};
    for pair in comma_list(raw) {
        let eq = strings.find(pair, "=");
        if eq < 1 {
            return err("OTEL_EXPORTER_OTLP_HEADERS must be name=value pairs, comma separated");
        }
        out[strings.trim(strings.slice(pair, 0, eq))] =
            strings.trim(strings.slice(pair, eq + 1, len(pair)));
    }
    return ok(out);
}

// An exporter from the standard variables: OTEL_EXPORTER_OTLP_ENDPOINT,
// OTEL_SERVICE_NAME, and OTEL_EXPORTER_OTLP_HEADERS, which is masked like
// any other secret.
pub fn span_exporter_from(cfg: Config) -> result[SpanExporter, str] {
    let sc = span_exporter_config(str_or(cfg, "OTEL_EXPORTER_OTLP_ENDPOINT", ""),
                                  str_or(cfg, "OTEL_SERVICE_NAME", ""));
    let hr = otlp_headers(str_or(cfg, "OTEL_EXPORTER_OTLP_HEADERS", ""));
    guard let headers = hr else let e = err_of(hr) {
        return err(e);
    }
    sc.headers = headers;
    return new_span_exporter(sc);
}

impl SpanExporter {
    // Queues a finished span. Never waits.
    fn offer(self: SpanExporter, s: tracewire.SpanData) {
        let text = tracewire.span_json(s);
        mutex_lock(self.lock);
        if self.stopped {
            self.dropped = self.dropped + 1;
            mutex_unlock(self.lock);
            return;
        }
        select {
            case chan_send(self.outbox, text) {
                self.pending = self.pending + 1;
            }
            default {
                self.dropped = self.dropped + 1;
            }
        }
        mutex_unlock(self.lock);
    }

    fn server_span(self: SpanExporter, ctx: TraceContext, method: str, route: str, status: int,
                   start: int) {
        let name = method;
        if len(route) > 0 {
            name = method + " " + route;
        }
        let attrs = [tracewire.attr_str("http.request.method", method),
                     tracewire.attr_int("http.response.status_code", status)];
        if len(route) > 0 {
            push(attrs, tracewire.attr_str("http.route", route));
        }
        let failed = status >= 500;
        let message = "";
        if failed {
            message = "status " + to_str(status);
        }
        self.offer(tracewire.SpanData {
            trace_id: ctx.trace_id, span_id: ctx.span_id, parent_id: ctx.parent_id, name: name,
            kind: tracewire.KIND_SERVER, start_ns: start, end_ns: span_clock(), attrs: attrs,
            failed: failed, message: message
        });
    }

    // A child of `ctx`, running until finish(). A context that is not
    // sampled gives a span that records nothing, so call sites need no
    // check. A new id that cannot be made does the same: a span must not
    // fail a request.
    pub fn start(self: SpanExporter, ctx: TraceContext, name: str) -> Span {
        return self.start_kind(ctx, name, tracewire.KIND_INTERNAL);
    }

    fn start_kind(self: SpanExporter, ctx: TraceContext, name: str, kind: int) -> Span {
        let no_attrs: [tracewire.Attr] = [];
        let data = tracewire.SpanData {
            trace_id: ctx.trace_id, span_id: "", parent_id: ctx.span_id, name: name, kind: kind,
            start_ns: 0, end_ns: 0, attrs: no_attrs, failed: false, message: ""
        };
        let sp = Span { exporter: self, ctx: ctx, data: data, done: true };
        if !ctx.sampled || len(ctx.trace_id) == 0 {
            return sp;
        }
        let gr = trace_random(8);
        guard let id = gr else {
            return sp;
        }
        data.span_id = id;
        data.start_ns = span_clock();
        sp.done = false;
        sp.ctx = TraceContext { trace_id: ctx.trace_id, parent_id: ctx.span_id, span_id: id,
                                sampled: ctx.sampled, state: ctx.state };
        return sp;
    }

    // Sends what is queued now, and waits up to `timeout` for it to
    // finish. true when nothing was left. Call it before exit.
    pub fn flush(self: SpanExporter, timeout: int) -> bool {
        mutex_lock(self.lock);
        self.flushing = self.flushing + 1;
        mutex_unlock(self.lock);
        let end = time.mono() + timeout;
        let done = false;
        while !done && time.mono() < end {
            mutex_lock(self.lock);
            done = self.pending == 0;
            mutex_unlock(self.lock);
            if !done {
                time.sleep(timez.MILLISECOND);
            }
        }
        mutex_lock(self.lock);
        self.flushing = self.flushing - 1;
        if !done {
            done = self.pending == 0;
        }
        mutex_unlock(self.lock);
        return done;
    }

    // Stops the sending task once what is queued has gone.
    pub fn stop(self: SpanExporter) {
        mutex_lock(self.lock);
        if !self.stopped {
            self.stopped = true;
            chan_close(self.outbox);
        }
        mutex_unlock(self.lock);
    }

    pub fn stats(self: SpanExporter) -> SpanStats {
        mutex_lock(self.lock);
        let s = SpanStats { sent: self.sent, dropped: self.dropped, failed: self.failed };
        mutex_unlock(self.lock);
        return s;
    }

    fn flush_wanted(self: SpanExporter) -> bool {
        mutex_lock(self.lock);
        let f = self.flushing > 0;
        mutex_unlock(self.lock);
        return f;
    }

    fn post(self: SpanExporter, batch: [str]) {
        let n = len(batch);
        let headers: map[str]str = {};
        for k, v in self.headers {
            headers[k] = v;
        }
        headers["content-type"] = "application/json";
        let req = httpc.Request {
            method: "POST", url: self.url, headers: headers,
            body: to_bytes(tracewire.export_json(self.service, batch)), max_redirects: 0,
            ca_path: ""
        };
        let r = httpc.send(req, until_of(time.mono() + self.timeout));
        let good = false;
        let why = "";
        if let resp = r {
            good = resp.status >= 200 && resp.status < 300;
            why = "status " + to_str(resp.status);
        } else let e = err_of(r) {
            why = e;
        }
        mutex_lock(self.lock);
        self.pending = self.pending - n;
        if good {
            self.sent = self.sent + n;
        } else {
            self.failed = self.failed + n;
        }
        mutex_unlock(self.lock);
        if !good {
            self.logger.warn("Tracing", to_str(n) + " spans not accepted by the collector: " + why);
        }
    }
}

impl Span {
    pub fn attr(self: Span, key: str, value: str) -> Span {
        if !self.done {
            push(self.data.attrs, tracewire.attr_str(key, value));
        }
        return self;
    }

    pub fn attr_int(self: Span, key: str, value: int) -> Span {
        if !self.done {
            push(self.data.attrs, tracewire.attr_int(key, value));
        }
        return self;
    }

    // Marks the span failed, for whoever is reading the trace.
    pub fn fail(self: Span, message: str) -> Span {
        self.data.failed = true;
        self.data.message = message;
        return self;
    }

    // This span's context: for a child of it, or for traced_send.
    pub fn context(self: Span) -> TraceContext {
        return self.ctx;
    }

    // Ends the span. A second call does nothing.
    pub fn finish(self: Span) {
        if self.done {
            return;
        }
        self.done = true;
        self.data.end_ns = span_clock();
        self.exporter.offer(self.data);
    }
}

// httpc.send under a client span, so the service it calls joins this trace
// at a span that exists. Only the URL's host goes on the span: a URL can
// hold a secret. With no trace, or none sampled, it still sends the trace
// along.
pub fn traced_send(e: SpanExporter, ctx: TraceContext, req: httpc.Request,
                   deadline: until) -> result[httpc.Response, str] {
    let sp = e.start_kind(ctx, req.method, tracewire.KIND_CLIENT);
    if sp.done {
        let tr = trace_request(ctx, req);
        guard let plain = tr else let te = err_of(tr) {
            return err(te);
        }
        return httpc.send(plain, deadline);
    }
    sp.attr("http.request.method", req.method).attr("server.address", tracewire.url_host(req.url));
    let hr = traced_as(sp.ctx, req);
    guard let out = hr else let te = err_of(hr) {
        sp.fail(te).finish();
        return err(te);
    }
    let r = httpc.send(out, deadline);
    guard let resp = r else let se = err_of(r) {
        sp.fail(se).finish();
        return err(se);
    }
    sp.attr_int("http.response.status_code", resp.status as int);
    if resp.status >= 500 {
        sp.fail("status " + to_str(resp.status));
    }
    sp.finish();
    return ok(resp);
}

// Sends batches until the queue closes: when one is full, when flush_every
// has passed, or at once after a flush().
fn span_sender(e: SpanExporter) {
    let batch: [str] = [];
    let due = time.mono() + e.flush_every;
    while true {
        let closed = false;
        let idle = false;
        select {
            case let m = chan_recv(e.outbox) {
                if let text = m {
                    push(batch, text);
                } else {
                    closed = true;
                }
            }
            default {
                idle = true;
            }
        }
        // On a flush, a partial batch goes only once the queue is empty, so
        // it does not split what could have gone in one post.
        let flush = idle && e.flush_wanted();
        if len(batch) > 0 && (flush || closed || len(batch) >= e.max_batch || time.mono() >= due) {
            e.post(batch);
            let fresh: [str] = [];
            batch = fresh;
            due = time.mono() + e.flush_every;
        }
        if closed {
            return;
        }
        if idle && !flush {
            // A span in the last moment of this sleep waits this long.
            time.sleep(50 * timez.MILLISECOND);
        }
    }
}
