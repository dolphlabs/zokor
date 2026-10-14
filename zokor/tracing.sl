// Request-scoped W3C context, carried explicitly across tasks and calls.
import "crypto";
import "encoding";
import "httpc";
import "internal/trace" as tracewire;

// Startup limits for incoming W3C headers.
pub gc struct TraceConfig {
    max_parent_bytes: int,
    max_state_bytes: int,
    max_state_members: int,
}

// Validated, immutable startup tracing settings.
pub gc struct Tracer {
    max_parent_bytes: int,
    max_state_bytes: int,
    max_state_members: int,
}

// Explicit request context; pass this value when spawning background work.
pub struct TraceContext {
    trace_id: str,
    parent_id: str,
    span_id: str,
    sampled: bool,
    state: str,
}

// Default limits: 256 parent bytes, 512 state bytes, 32 state members.
pub fn trace_config() -> TraceConfig {
    return TraceConfig { max_parent_bytes: 256, max_state_bytes: 512, max_state_members: 32 };
}

// Validate all startup limits together and copy them.
pub fn new_tracer(cfg: TraceConfig) -> result[Tracer, str] {
    let problems: [str] = [];
    if cfg.max_parent_bytes < 55 { push(problems, "max_parent_bytes must be at least 55"); }
    if cfg.max_state_bytes < 1 || cfg.max_state_bytes > 512 { push(problems, "max_state_bytes must be 1..512"); }
    if cfg.max_state_members < 1 || cfg.max_state_members > 32 { push(problems, "max_state_members must be 1..32"); }
    if len(problems) > 0 { return err("tracing: " + strings.join(problems, "; ")); }
    return ok(Tracer { max_parent_bytes: cfg.max_parent_bytes, max_state_bytes: cfg.max_state_bytes, max_state_members: cfg.max_state_members });
}

fn empty_trace() -> TraceContext {
    return TraceContext { trace_id: "", parent_id: "", span_id: "", sampled: false, state: "" };
}

fn trace_random(size: int) -> result[str, str] {
    let i = 0;
    while i < 4 {
        let generated = crypto.rand(size);
        guard let random = generated else let e = err_of(generated) { return err("cannot generate trace identifier: " + e); }
        let id = encoding.hex_encode(random);
        if tracewire.id_ok(id, size * 2) { return ok(id); }
        i += 1;
    }
    return err("random source could not produce a nonzero trace identifier");
}

// Invalid, absent or duplicate parents start a new trace. Invalid state
// is dropped separately, never changing a valid parent or sampled bit.
pub fn trace_context(t: Tracer, headers: bytes) -> result[TraceContext, str] {
    let generated = trace_random(8);
    guard let span = generated else let e = err_of(generated) { return err(e); }
    let parents = header_list(headers, "traceparent");
    if len(parents) == 1 && len(parents[0]) <= t.max_parent_bytes {
        let parsed = tracewire.parent(parents[0]);
        if let parent = parsed {
            let state = "";
            let too_big = false;
            for part in header_list(headers, "tracestate") {
                let extra = len(part);
                if len(state) > 0 { extra += 1; }
                if extra > t.max_state_bytes - len(state) { too_big = true; break; }
                if len(state) > 0 { state = state + ","; }
                state = state + part;
            }
            if too_big { state = ""; }
            state = tracewire.state(state, t.max_state_bytes, t.max_state_members);
            return ok(TraceContext { trace_id: parent.trace_id, parent_id: parent.span_id,
                span_id: span, sampled: parent.sampled, state: state });
        }
    }
    let made = trace_random(16);
    guard let id = made else let e = err_of(made) { return err(e); }
    return ok(TraceContext { trace_id: id, parent_id: "", span_id: span, sampled: false, state: "" });
}

// A validated version-00 header; reserved flags are always zero.
pub fn trace_header(ctx: TraceContext) -> result[str, str] {
    if !tracewire.id_ok(ctx.trace_id, 32) || !tracewire.id_ok(ctx.span_id, 16) {
        return err("TraceContext trace_id/span_id must be nonzero lowercase hex identifiers of 32/16 characters");
    }
    let flags = "00";
    if ctx.sampled { flags = "01"; }
    return ok("00-" + ctx.trace_id + "-" + ctx.span_id + "-" + flags);
}

// Copy the request and its headers; never mutate a shared caller request.
// Each outbound call gets a child span under the current request span.
pub fn trace_request(ctx: TraceContext, req: httpc.Request) -> result[httpc.Request, str] {
    if len(ctx.trace_id) == 0 { return ok(req); }
    let valid = trace_header(ctx);
    guard let _h = valid else let e = err_of(valid) { return err(e); }
    let state = tracewire.state(ctx.state, 512, 32);
    if len(ctx.state) > 0 && len(state) == 0 { return err("TraceContext state must be valid W3C tracestate"); }
    let generated = trace_random(8);
    guard let span = generated else let e = err_of(generated) { return err(e); }
    let child = TraceContext { trace_id: ctx.trace_id, parent_id: ctx.span_id,
        span_id: span, sampled: ctx.sampled, state: state };
    let hdr = trace_header(child);
    guard let parent = hdr else let e = err_of(hdr) { return err(e); }
    let headers: map[str]str = {};
    for k, v in req.headers {
        let lower = strings.to_lower(k);
        if lower != "traceparent" && lower != "tracestate" { headers[k] = v; }
    }
    headers["traceparent"] = parent;
    if len(state) > 0 { headers["tracestate"] = state; }
    return ok(httpc.Request { method: req.method, url: req.url, headers: headers,
        body: req.body, max_redirects: req.max_redirects, ca_path: req.ca_path });
}

// Bind a registry by copying its startup references, never changing the
// shared registry as concurrent requests arrive with different trace ids.
pub fn trace_registry(reg: Registry, ctx: TraceContext) -> Registry {
    if len(ctx.trace_id) == 0 { return reg; }
    return Registry { codes: reg.codes, render: reg.render, trace_id: ctx.trace_id };
}

fn trace_locals(ctx: TraceContext) -> opt[map[str]str] {
    let sampled = "0";
    if ctx.sampled { sampled = "1"; }
    let locals: map[str]str = {
        "__zokor_trace_id": ctx.trace_id, "__zokor_parent_id": ctx.parent_id,
        "__zokor_span_id": ctx.span_id, "__zokor_sampled": sampled, "__zokor_tracestate": ctx.state
    };
    return some(locals);
}

// Only traced requests allocate this scope. Startup route/config objects
// remain shared; the error registry and hook locals belong to one request.
fn trace_router[S](r: Router[S], ctx: TraceContext) -> Router[S] {
    return Router[S] { routes: r.routes, befores: r.befores, afters: r.afters,
        state: r.state, errors: trace_registry(r.errors, ctx), auto_options: r.auto_options,
        auto_head: r.auto_head, ready: r.ready, cors: r.cors, security: r.security,
        sanitize: r.sanitize, auto_etag: r.auto_etag, rindex: r.rindex,
        static_paths: r.static_paths, idem: r.idem, gzip: r.gzip, mounts: r.mounts,
        no_lines: r.no_lines, observations: r.observations, tracer: r.no_tracer,
        no_tracer: r.no_tracer, request_locals: trace_locals(ctx) };
}

fn trace_failed[S](r: Router[S], req: http.Request, rid: str, client: str) -> Served {
    let c = static_probe(r.state, r.errors);
    c.req = req;
    c.request_id = rid;
    c.client_ip = client;
    return Served { resp: r.finish(c, respond(r.errors, "internal", rid)), route: "" };
}

// A request binding over a shared Logger, without changing its configuration.
pub struct TraceLogger { logger: Logger, trace_id: str, request_id: str }

// Bind application records to a validated trace id.
pub fn traced_logger(log: Logger, ctx: TraceContext) -> TraceLogger {
    let id = "";
    if tracewire.id_ok(ctx.trace_id, 32) { id = ctx.trace_id; }
    return TraceLogger { logger: log, trace_id: id, request_id: "" };
}

impl TraceLogger {
    fn emit(self: TraceLogger, level: LogLevel, context: str, message: str) {
        if !self.logger.enabled(level) { return; }
        let ev = line_event(level, context, message);
        ev.trace_id = self.trace_id;
        ev.request_id = self.request_id;
        ev.ack = self.logger.no_ack;
        self.logger.emit(ev);
    }
    pub fn debug(self: TraceLogger, context: str, message: str) { self.emit(LogLevel.DEBUG, context, message); }
    pub fn log(self: TraceLogger, context: str, message: str) { self.emit(LogLevel.LOG, context, message); }
    pub fn warn(self: TraceLogger, context: str, message: str) { self.emit(LogLevel.WARN, context, message); }
    pub fn error(self: TraceLogger, context: str, message: str) { self.emit(LogLevel.ERROR, context, message); }
}
