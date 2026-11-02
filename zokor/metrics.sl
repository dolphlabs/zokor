// Opt-in Prometheus metrics with bounded request series and custom scalars.
import "builder";
import "http";
import "strings";
import "time";

pub gc struct MetricsConfig {
    path: str,
    max_series: int,
    max_custom: int,
    buckets_ns: [int],
}

pub fn metrics_config() -> MetricsConfig {
    return MetricsConfig { path: "/metrics", max_series: 1000, max_custom: 100,
        buckets_ns: [500000, 1000000, 5000000, 10000000, 25000000, 50000000,
                     100000000, 250000000, 500000000, 1000000000, 5000000000] };
}

gc struct RequestSeries {
    method: str,
    route: str,
    status: int,
    count: int,
    seconds: float,
    buckets: [int],
}

pub enum MetricKind { Counter, Gauge }

pub gc struct Metric {
    name: str,
    help: str,
    kind: MetricKind,
    lock: mutex,
    value: int,
}

pub gc struct Metrics {
    path: str,
    max_series: int,
    max_custom: int,
    bounds: [int],
    lock: mutex,
    active: int,
    dropped: int,
    routes: map[str]int,
    series_index: map[int]int,
    series: [RequestSeries],
    custom: [Metric],
}

// Copies configuration so later caller mutations cannot change bucket shapes.
pub fn new_metrics(cfg: MetricsConfig) -> result[Metrics, str] {
    let problems: [str] = [];
    let good_path = strings.has_prefix(cfg.path, "/") && !strings.contains(cfg.path, "?") && !strings.contains(cfg.path, "#");
    for byte in to_bytes(cfg.path) { if byte <= 32 || byte == 127 { good_path = false; } }
    if !good_path { push(problems, "path must be an absolute path without whitespace, controls, ? or #"); }
    if cfg.max_series < 1 || cfg.max_series > 1537228672809129 { push(problems, "max_series must be positive and fit integer series keys"); }
    if cfg.max_custom < 1 { push(problems, "max_custom must be positive"); }
    let prev = 0;
    let prev_seconds = 0.0;
    let index = 0;
    for n in cfg.buckets_ns {
        let seconds = (n as float) / 1000000000.0;
        if n <= prev || seconds <= prev_seconds { push(problems, "buckets_ns[" + to_str(index) + "] must be positive, greater than the previous bucket and distinct in seconds"); }
        prev = n;
        prev_seconds = seconds;
        index += 1;
    }
    if len(problems) > 0 { return err("metrics: " + strings.join(problems, "; ")); }
    return ok(Metrics { path: cfg.path, max_series: cfg.max_series, max_custom: cfg.max_custom,
        bounds: cfg.buckets_ns[0..len(cfg.buckets_ns)], lock: make_mutex(), active: 0, dropped: 0,
        routes: {}, series_index: {}, series: [], custom: [] });
}

fn metric_inc(n: int) -> int {
    if n == 9223372036854775807 { return n; }
    return n + 1;
}

fn metric_method(method: str) -> int {
    if method == "GET" { return 0; }
    if method == "HEAD" { return 1; }
    if method == "POST" { return 2; }
    if method == "PUT" { return 3; }
    if method == "PATCH" { return 4; }
    if method == "DELETE" { return 5; }
    if method == "OPTIONS" { return 6; }
    if method == "TRACE" { return 7; }
    if method == "CONNECT" { return 8; }
    return 9;
}

impl Metrics {
    pub fn enter(self: Metrics) {
        mutex_lock(self.lock);
        self.active = metric_inc(self.active);
        mutex_unlock(self.lock);
    }

    // One completion for each enter, including a panic or failed socket write.
    // Route is a registration pattern; unknown methods share OTHER.
    pub fn leave(self: Metrics, method: str, route: str, status: int, ns: int) {
        let pattern = route;
        if len(pattern) == 0 { pattern = "__unmatched__"; }
        let mid = metric_method(method);
        let code = status;
        if code < 100 || code > 599 { code = 0; }
        let elapsed = ns;
        if elapsed < 0 { elapsed = 0; }
        mutex_lock(self.lock);
        if self.active > 0 { self.active = self.active - 1; }
        if !has(self.routes, pattern) {
            if len(self.series) >= self.max_series { self.dropped = metric_inc(self.dropped); mutex_unlock(self.lock); return; }
            self.routes[pattern] = len(self.routes);
        }
        let key = self.routes[pattern] * 6000 + mid * 600 + code;
        if !has(self.series_index, key) {
            if len(self.series) >= self.max_series { self.dropped = metric_inc(self.dropped); mutex_unlock(self.lock); return; }
            let buckets: [int] = [];
            for _n in self.bounds { push(buckets, 0); }
            let verb = method;
            if mid == 9 { verb = "OTHER"; }
            self.series_index[key] = len(self.series);
            push(self.series, RequestSeries { method: verb, route: pattern, status: code, count: 0, seconds: 0.0, buckets: buckets });
        }
        let s = self.series[self.series_index[key]];
        s.count = metric_inc(s.count);
        s.seconds = s.seconds + (elapsed as float) / 1000000000.0;
        let i = 0;
        while i < len(self.bounds) {
            if elapsed <= self.bounds[i] { s.buckets[i] = metric_inc(s.buckets[i]); }
            i += 1;
        }
        mutex_unlock(self.lock);
    }

    pub fn counter(self: Metrics, name: str, help: str) -> result[Metric, str] {
        return metric_register(self, name, help, MetricKind.Counter);
    }

    pub fn gauge(self: Metrics, name: str, help: str) -> result[Metric, str] {
        return metric_register(self, name, help, MetricKind.Gauge);
    }
}

fn metric_name_ok(name: str) -> bool {
    let b = to_bytes(name);
    if len(b) == 0 || strings.has_prefix(name, "zokor_") { return false; }
    let i = 0;
    for v in b {
        let c = v as int;
        if !((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 58 || (i > 0 && c >= 48 && c <= 57)) { return false; }
        i += 1;
    }
    return true;
}

fn metric_register(m: Metrics, name: str, help: str, kind: MetricKind) -> result[Metric, str] {
    if !metric_name_ok(name) { return err("metric name must use Prometheus ASCII identifiers and must not start with zokor_"); }
    let scalar = Metric { name: name, help: help, kind: kind, lock: make_mutex(), value: 0 };
    mutex_lock(m.lock);
    for c in m.custom {
        if c.name == name { mutex_unlock(m.lock); return err("metric '" + name + "' is already registered"); }
    }
    if len(m.custom) >= m.max_custom { mutex_unlock(m.lock); return err("custom metrics exceed max_custom"); }
    push(m.custom, scalar);
    mutex_unlock(m.lock);
    return ok(scalar);
}

impl Metric {
    // Counters only increase; gauges can add a signed delta.
    pub fn add(self: Metric, delta: int) -> result[bool, str] {
        if self.kind == MetricKind.Counter && delta < 0 { return err("counter delta must be nonnegative"); }
        mutex_lock(self.lock);
        let v = self.value;
        if (delta > 0 && v > 9223372036854775807 - delta) ||
           (delta < 0 && v < (-9223372036854775807 - 1) - delta) {
            mutex_unlock(self.lock); return err("metric addition would overflow");
        }
        self.value = v + delta;
        mutex_unlock(self.lock);
        return ok(true);
    }

    pub fn set(self: Metric, value: int) -> result[bool, str] {
        if self.kind != MetricKind.Gauge { return err("only gauges can be set; use counter.add"); }
        mutex_lock(self.lock); self.value = value; mutex_unlock(self.lock);
        return ok(true);
    }

    pub fn read(self: Metric) -> int {
        mutex_lock(self.lock); let v = self.value; mutex_unlock(self.lock);
        return v;
    }
}

fn metric_escape(text: str, label: bool) -> str {
    let s = strings.replace(text, "\\", "\\\\");
    s = strings.replace(s, "\n", "\\n");
    if label { s = strings.replace(s, "\"", "\\\""); }
    return s;
}

fn metric_labels(s: RequestSeries) -> str {
    return "method=\"" + s.method + "\",route=\"" + metric_escape(s.route, true) + "\",status=\"" + to_str(s.status) + "\"";
}

fn metric_seconds(ns: int) -> str {
    let whole = to_str(ns / 1000000000);
    let rem = ns % 1000000000;
    if rem == 0 { return whole; }
    let fraction = to_str(rem);
    while len(fraction) < 9 { fraction = "0" + fraction; }
    while strings.has_suffix(fraction, "0") { fraction = strings.slice(fraction, 0, len(fraction) - 1); }
    return whole + "." + fraction;
}

// A consistent snapshot is copied under the lock; text formatting happens
// after unlocking so scrapes do not hold up request accounting.
pub fn metrics_text(m: Metrics) -> str {
    let series: [RequestSeries] = [];
    mutex_lock(m.lock);
    for s in m.series {
        push(series, RequestSeries { method: s.method, route: s.route, status: s.status,
            count: s.count, seconds: s.seconds, buckets: s.buckets[0..len(s.buckets)] });
    }
    let active = m.active;
    let dropped = m.dropped;
    let custom = m.custom[0..len(m.custom)];
    mutex_unlock(m.lock);
    let sb = builder.new_str();
    sb.write("# HELP zokor_http_requests_total Completed HTTP requests.\n# TYPE zokor_http_requests_total counter\n");
    for s in series { sb.write("zokor_http_requests_total{" + metric_labels(s) + "} " + to_str(s.count) + "\n"); }
    sb.write("# HELP zokor_http_request_duration_seconds HTTP request duration in seconds.\n# TYPE zokor_http_request_duration_seconds histogram\n");
    for s in series {
        let labels = metric_labels(s);
        let i = 0;
        while i < len(m.bounds) {
            sb.write("zokor_http_request_duration_seconds_bucket{" + labels + ",le=\"" + metric_seconds(m.bounds[i]) + "\"} " + to_str(s.buckets[i]) + "\n");
            i += 1;
        }
        sb.write("zokor_http_request_duration_seconds_bucket{" + labels + ",le=\"+Inf\"} " + to_str(s.count) + "\n");
        sb.write("zokor_http_request_duration_seconds_sum{" + labels + "} " + to_str(s.seconds) + "\n");
        sb.write("zokor_http_request_duration_seconds_count{" + labels + "} " + to_str(s.count) + "\n");
    }
    sb.write("# HELP zokor_http_in_flight HTTP requests currently being served.\n# TYPE zokor_http_in_flight gauge\nzokor_http_in_flight " + to_str(active) + "\n");
    sb.write("# HELP zokor_http_observations_dropped_total Completions beyond the configured series cap.\n# TYPE zokor_http_observations_dropped_total counter\nzokor_http_observations_dropped_total " + to_str(dropped) + "\n");
    for c in custom {
        let kind = "gauge";
        if c.kind == MetricKind.Counter { kind = "counter"; }
        sb.write("# HELP " + c.name + " " + metric_escape(c.help, false) + "\n# TYPE " + c.name + " " + kind + "\n" + c.name + " " + to_str(c.read()) + "\n");
    }
    return sb.finish();
}

fn metrics_response(m: Metrics) -> http.Response {
    return http.text_response(200, "OK", "text/plain; version=0.0.4; charset=utf-8", metrics_text(m));
}

fn metrics_scrape(method: str, raw: str, m: Metrics) -> bool {
    return (method == "GET" || method == "HEAD") && path.strip_query(raw) == m.path;
}

fn metrics_frame_core[S](r: Router[S], f: http.WireFrame, rid: str, client: str) -> Served {
    return r.serve_frame_core(f, rid, client);
}

fn metrics_request_core[S](r: Router[S], req: http.Request, rid: str, client: str) -> Served {
    return r.serve_id_core(req, rid, client);
}

fn metrics_frame[S](r: Router[S], m: Metrics, f: http.WireFrame, rid: str, client: str) -> Served {
    if metrics_scrape(f.method, f.path, m) { return r.serve_frame_core(f, rid, client); }
    m.enter(); let started = time.mono();
    let jr = join_wait(spawn metrics_frame_core(r, f, rid, client));
    guard let served = jr else let e = err_of(jr) {
        m.leave(f.method, r.metrics_pattern(f.method, f.path), 500, (time.mono() - started) as int);
        panic(e);
    }
    m.leave(f.method, served.route, served.resp.status as int, (time.mono() - started) as int);
    return served;
}

fn metrics_request[S](r: Router[S], m: Metrics, req: http.Request, rid: str, client: str) -> Served {
    if metrics_scrape(req.method, req.path, m) { return r.serve_id_core(req, rid, client); }
    m.enter(); let started = time.mono();
    let jr = join_wait(spawn metrics_request_core(r, req, rid, client));
    guard let served = jr else let e = err_of(jr) {
        m.leave(req.method, r.metrics_pattern(req.method, req.path), 500, (time.mono() - started) as int);
        panic(e);
    }
    m.leave(req.method, served.route, served.resp.status as int, (time.mono() - started) as int);
    return served;
}
