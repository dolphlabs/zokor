// Logging.
//
// One record per request, plus the server's own lines (routes mapped,
// listening, dropped records), on by default:
//
//   [zokor] 51734  - 2026-10-12 18:47:01.123Z     LOG [HTTP] GET /users/:id 200 512B 10.0.0.4 req_1a2b... +3.21ms
//
// coloured on a terminal in the NestJS layout, and one JSON object per
// line anywhere else, which is what a log shipper wants:
//
//   {"time":"2026-10-12T18:47:01.123Z","level":"log","pid":51734,"context":"HTTP",...}
//
// LOG_FORMAT (pretty or json) overrides the choice, LOG_LEVEL (debug, log,
// warn, error, off) sets the floor, LOG_REQUESTS=false keeps the server's
// own lines and drops the per-request ones, and NO_COLOR turns colour off.
//
// A request never waits on the log. The serve loop builds a LogEvent and
// offers it to a bounded channel; one task drains it, formats, and writes
// a batch per wake-up. When the channel is full the event is dropped and
// counted, and the count is reported as a WARN line once there is room:
// a log that slows the server down under load is worse than a gap in it.
//
// Not coupled to this writer: a Logger is a channel plus a level. A
// separate package makes one with `channel_logger`, drains the channel
// itself, and reuses `format_json` / `format_pretty` or writes its own.
//
// What is never logged: query strings, bodies, headers. A matched request
// is logged by its route PATTERN (`/users/:id`), never its path, so ids in
// paths stay out of the log and a dashboard sees one series per route; an
// unmatched path is logged truncated, with control characters escaped, so
// a client cannot forge log lines or terminal escapes.

import "builder";
import "io";
import "os";
import "proc";
import "strings";
import "time";

pub enum LogLevel {
    DEBUG,
    LOG,
    WARN,
    ERROR,
    OFF,
}

pub fn level_rank(l: LogLevel) -> int {
    switch l {
        case LogLevel.DEBUG { return 0; }
        case LogLevel.LOG { return 1; }
        case LogLevel.WARN { return 2; }
        case LogLevel.ERROR { return 3; }
        case LogLevel.OFF { return 4; }
    }
    return 4;
}

pub fn level_name(l: LogLevel) -> str {
    switch l {
        case LogLevel.DEBUG { return "debug"; }
        case LogLevel.LOG { return "log"; }
        case LogLevel.WARN { return "warn"; }
        case LogLevel.ERROR { return "error"; }
        case LogLevel.OFF { return "off"; }
    }
    return "off";
}

pub fn parse_level(s: str) -> opt[LogLevel] {
    let l = strings.to_lower(strings.trim(s));
    if l == "debug" { return some(LogLevel.DEBUG); }
    if l == "log" || l == "info" { return some(LogLevel.LOG); }
    if l == "warn" || l == "warning" { return some(LogLevel.WARN); }
    if l == "error" { return some(LogLevel.ERROR); }
    if l == "off" || l == "none" { return some(LogLevel.OFF); }
    return none;
}

pub gc struct LogEvent {
    // Unix nanoseconds (time.wall), taken when the event was made.
    time: int,
    level: LogLevel,
    // The part of the program speaking: "HTTP" for requests, "Router",
    // "Server", or a service's own.
    context: str,
    // The line itself. For a request it is the readable summary; the
    // fields below carry the same facts for JSON.
    message: str,
    request: bool,
    method: str,
    route: str,
    // Only for an unmatched request (route ""), already made safe by
    // safe_path; "" otherwise.
    path: str,
    status: int,
    duration_ns: int,
    size: int,
    request_id: str,
    client_ip: str,
    // For a flush marker only: the writer sends 1 here once everything
    // before the marker is written.
    ack: opt[chan[int]],
}

pub gc struct Logger {
    // none: nothing is logged (no_logger, or a console logger whose
    // writer has not been started yet -- see start).
    events: opt[chan[LogEvent]],
    level: LogLevel,
    requests: bool,
    // The console writer's settings; unused by a channel_logger.
    console: bool,
    json: bool,
    color: bool,
    capacity: int,
    lock: mutex,
    // Events dropped because the channel was full, not yet reported.
    dropped: int,
    // The `ack` of every ordinary event. A slang `none` is a heap object,
    // so one shared none saves an allocation per request.
    no_ack: opt[chan[int]],
}

// How many events may wait for the writer: enough to absorb a burst of
// a few thousand requests between two wake-ups.
pub fn default_log_capacity() -> int {
    return 4096;
}

// Logs nothing.
pub fn no_logger() -> Logger {
    return Logger {
        events: none,
        level: LogLevel.OFF,
        requests: false,
        console: false,
        json: false,
        color: false,
        capacity: 0,
        lock: make_mutex(),
        dropped: 0,
        no_ack: none
    };
}

// zokor's own writer, to stdout, configured but not started: `start`
// (which listen_and_serve_with calls) makes the channel and the task, so
// building a ServerConfig in a test starts nothing.
pub fn console_logger(json: bool, color: bool, level: LogLevel,
                      requests: bool) -> Logger {
    return Logger {
        events: none,
        level: level,
        requests: requests,
        console: true,
        json: json,
        color: color,
        capacity: default_log_capacity(),
        lock: make_mutex(),
        dropped: 0,
        no_ack: none
    };
}

// A logger whose events go to `ch`, drained by the caller's own task.
pub fn channel_logger(ch: chan[LogEvent], level: LogLevel,
                      requests: bool) -> Logger {
    return Logger {
        events: some(ch),
        level: level,
        requests: requests,
        console: false,
        json: false,
        color: false,
        capacity: 0,
        lock: make_mutex(),
        dropped: 0,
        no_ack: none
    };
}

// The default: pretty and coloured on a terminal, JSON otherwise,
// level LOG, request lines on.
pub fn default_logger() -> Logger {
    let tty = io.is_tty(1);
    let no_color = len(proc.getenv("NO_COLOR") ?? "") > 0;
    return console_logger(!tty, tty && !no_color, LogLevel.LOG, true);
}

// LOG_FORMAT, LOG_LEVEL, LOG_REQUESTS and NO_COLOR over the default. A
// bad value is recorded on `cfg`, so check(cfg) reports it with every
// other problem before the server starts.
pub fn logger_from(cfg: Config) -> Logger {
    let lg = default_logger();
    let tty = io.is_tty(1);
    let no_color = len(str_or(cfg, "NO_COLOR", "")) > 0;
    let fmt = strings.to_lower(str_or(cfg, "LOG_FORMAT", ""));
    if fmt == "json" {
        lg.json = true;
        lg.color = false;
    } else if fmt == "pretty" {
        lg.json = false;
        lg.color = tty && !no_color;
    } else if len(fmt) > 0 {
        record(cfg, "LOG_FORMAT", fmt, "must be pretty or json");
    }
    if no_color {
        lg.color = false;
    }
    let lv = str_or(cfg, "LOG_LEVEL", "");
    if len(lv) > 0 {
        let pl = parse_level(lv);
        if let l = pl {
            lg.level = l;
        } else {
            record(cfg, "LOG_LEVEL", lv, "must be debug, log, warn, error or off");
        }
    }
    let rq = strings.to_lower(str_or(cfg, "LOG_REQUESTS", ""));
    if rq == "false" || rq == "0" || rq == "no" || rq == "off" {
        lg.requests = false;
    } else if rq == "true" || rq == "1" || rq == "yes" || rq == "on" {
        lg.requests = true;
    } else if len(rq) > 0 {
        record(cfg, "LOG_REQUESTS", rq, "must be true or false");
    }
    return lg;
}

impl Logger {
    // Starts the console writer if this is an unstarted console logger;
    // otherwise does nothing. Safe to call more than once.
    pub fn start(self: Logger) {
        if !self.console || level_rank(self.level) >= level_rank(LogLevel.OFF) {
            return;
        }
        mutex_lock(self.lock);
        let started = false;
        if let _ch = self.events {
            started = true;
        }
        if !started {
            let ch: chan[LogEvent] = make_chan(self.capacity);
            self.events = some(ch);
            mutex_unlock(self.lock);
            spawn console_writer(self, ch);
            return;
        }
        mutex_unlock(self.lock);
    }

    // Tasks this logger runs for itself: 1 once the console writer is
    // started. The shutdown drain discounts them.
    pub fn own_tasks(self: Logger) -> int {
        if !self.console {
            return 0;
        }
        guard let _ch = self.events else {
            return 0;
        }
        return 1;
    }

    // Whether an event at `l` would be sent at all: lets a caller skip
    // building one.
    pub fn enabled(self: Logger, l: LogLevel) -> bool {
        guard let _ch = self.events else {
            return false;
        }
        return level_rank(l) >= level_rank(self.level) &&
               level_rank(l) < level_rank(LogLevel.OFF);
    }

    // Offers `ev` without waiting: dropped and counted when the channel is
    // full or below the level.
    pub fn emit(self: Logger, ev: LogEvent) {
        if !self.enabled(ev.level) {
            return;
        }
        guard let ch = self.events else {
            return;
        }
        select {
            case chan_send(ch, ev) { }
            default {
                mutex_lock(self.lock);
                self.dropped = self.dropped + 1;
                mutex_unlock(self.lock);
            }
        }
    }

    // The serve loop's call: one request's record, if requests are logged
    // at its level. 5xx is ERROR and 4xx WARN, so LOG_LEVEL=warn keeps
    // exactly the requests that went wrong.
    pub fn record_request(self: Logger, method: str, route: str, raw_path: str,
                          status: int, duration_ns: int, size: int,
                          request_id: str, client_ip: str) {
        if !logs_requests(self, status) {
            return;
        }
        let ev = request_event(method, route, raw_path, status, duration_ns,
                               size, request_id, client_ip);
        ev.ack = self.no_ack;
        self.emit(ev);
    }

    pub fn debug(self: Logger, context: str, message: str) {
        self.emit(line_event(LogLevel.DEBUG, context, message));
    }
    pub fn log(self: Logger, context: str, message: str) {
        self.emit(line_event(LogLevel.LOG, context, message));
    }
    pub fn warn(self: Logger, context: str, message: str) {
        self.emit(line_event(LogLevel.WARN, context, message));
    }
    pub fn error(self: Logger, context: str, message: str) {
        self.emit(line_event(LogLevel.ERROR, context, message));
    }

    // Events dropped and not yet reported; resets the count.
    pub fn take_dropped(self: Logger) -> int {
        mutex_lock(self.lock);
        let n = self.dropped;
        self.dropped = 0;
        mutex_unlock(self.lock);
        return n;
    }

    // Waits until everything emitted before this call is written, or
    // `timeout_ns` passes. Blocking, unlike emit: for shutdown, so the
    // last lines are not lost when the process exits.
    pub fn flush(self: Logger, timeout_ns: int) {
        guard let ch = self.events else {
            return;
        }
        if !self.console {
            return;
        }
        let ack: chan[int] = make_chan(1);
        let marker = line_event(LogLevel.OFF, "", "");
        marker.ack = some(ack);
        chan_send(ch, marker);
        let deadline = time.mono() + timeout_ns;
        while time.mono() < deadline {
            select {
                case let _v = chan_recv(ack) { return; }
                default { }
            }
            time.sleep(1000000);
        }
    }
}

fn line_event(level: LogLevel, context: str, message: str) -> LogEvent {
    return LogEvent {
        time: time.wall() as int,
        level: level,
        context: context,
        message: message,
        request: false,
        method: "",
        route: "",
        path: "",
        status: 0,
        duration_ns: 0,
        size: 0,
        request_id: "",
        client_ip: "",
        ack: none
    };
}

// A request's record. 5xx is ERROR and 4xx WARN, so LOG_LEVEL=warn keeps
// exactly the requests that went wrong.
pub fn request_event(method: str, route: str, raw_path: str, status: int,
                     duration_ns: int, size: int, request_id: str,
                     client_ip: str) -> LogEvent {
    let lv = LogLevel.LOG;
    if status >= 500 {
        lv = LogLevel.ERROR;
    } else if status >= 400 {
        lv = LogLevel.WARN;
    }
    let p = "";
    if len(route) == 0 {
        p = safe_path(raw_path);
    }
    return LogEvent {
        time: time.wall() as int,
        level: lv,
        context: "HTTP",
        message: "",
        request: true,
        method: safe_method(method),
        route: route,
        path: p,
        status: status,
        duration_ns: duration_ns,
        size: size,
        request_id: request_id,
        client_ip: client_ip,
        ack: none
    };
}

// Whether the serve loop should build a request record at all.
pub fn logs_requests(lg: Logger, status: int) -> bool {
    if !lg.requests {
        return false;
    }
    let lv = LogLevel.LOG;
    if status >= 500 {
        lv = LogLevel.ERROR;
    } else if status >= 400 {
        lv = LogLevel.WARN;
    }
    return lg.enabled(lv);
}

// A client-supplied path made safe to print: the query dropped, at most
// 64 bytes kept, and every byte outside printable ASCII -- and `"` and
// `\` -- percent-encoded, so neither a newline nor a terminal escape
// survives into the log, and the result needs no escaping in JSON.
pub fn safe_path(raw: str) -> str {
    let b = to_bytes(raw);
    if len(b) <= 64 && clean_bytes(b) {
        return raw;
    }
    let out = "";
    let n = 0;
    let i = 0;
    while i < len(b) {
        let c = b[i] as int;
        if c == 63 {
            break;
        }
        if n >= 64 {
            out = out + "...";
            break;
        }
        if c < 32 || c > 126 || c == 92 || c == 34 {
            out = out + "%" + hex2(c);
        } else {
            out = out + strings.slice(raw, i, i + 1);
        }
        n = n + 1;
        i = i + 1;
    }
    return out;
}

// Whether safe_path would leave `b` as it is.
fn clean_bytes(b: bytes) -> bool {
    for c in b {
        let x = c as int;
        if x == 63 || x < 32 || x > 126 || x == 92 || x == 34 {
            return false;
        }
    }
    return true;
}

// The method, made safe to print. slang's parser takes any bytes before
// the first space as the method, so an unusual one is escaped like a
// path; the common ones are compared, which allocates nothing.
fn safe_method(m: str) -> str {
    if m == "GET" || m == "POST" || m == "PUT" || m == "PATCH" ||
       m == "DELETE" || m == "HEAD" || m == "OPTIONS" {
        return m;
    }
    return safe_path(m);
}

// Unix nanoseconds as UTC civil time: [year, month, day, hour, minute,
// second, millisecond]. Days to civil date is Howard Hinnant's
// algorithm, exact for every date a log will carry.
pub fn utc_parts(unix_ns: int) -> [int] {
    let ms_total = unix_ns / 1000000;
    if unix_ns < 0 && unix_ns % 1000000 != 0 {
        ms_total = ms_total - 1;
    }
    let ms = ms_total % 1000;
    let secs = ms_total / 1000;
    if ms < 0 {
        ms = ms + 1000;
        secs = secs - 1;
    }
    let days = secs / 86400;
    let rem = secs % 86400;
    if rem < 0 {
        rem = rem + 86400;
        days = days - 1;
    }
    let z = days + 719468;
    let era = z / 146097;
    if z < 0 && z % 146097 != 0 {
        era = era - 1;
    }
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + 3;
    if mp >= 10 {
        m = mp - 9;
    }
    let y = yoe + era * 400;
    if m <= 2 {
        y = y + 1;
    }
    return [y, m, d, rem / 3600, rem % 3600 / 60, rem % 60, ms];
}

// Formatting state, made once and reused for every line: tables of the
// numbers a line needs (so a status, a size or a millisecond is a
// lookup, not a to_str), the current second's timestamp prefix, and each
// route pattern already quoted. A builder takes the pieces without
// copying them, so a clean request line costs a handful of allocations,
// not dozens.
//
// A package that drains its own channel_logger makes one with
// new_log_format and calls `json` or `pretty` per event.
pub gc struct LogFormat {
    pid: str,
    // "000".."999", and "0".."999".
    three: [str],
    plain: [str],
    // The second `stamp_t` and `stamp_sp` are for, as unix seconds; -1
    // before the first line.
    sec: int,
    // "2026-10-12T18:47:01." and "2026-10-12 18:47:01.".
    stamp_t: str,
    stamp_sp: str,
    quoted: map[str]str,
}

pub fn new_log_format(pid: int) -> LogFormat {
    let three: [str] = [];
    let plain: [str] = [];
    let i = 0;
    while i < 1000 {
        let p = to_str(i);
        push(plain, p);
        if i < 10 {
            push(three, "00" + p);
        } else if i < 100 {
            push(three, "0" + p);
        } else {
            push(three, p);
        }
        i = i + 1;
    }
    return LogFormat {
        pid: to_str(pid),
        three: three,
        plain: plain,
        sec: -1,
        stamp_t: "",
        stamp_sp: "",
        quoted: {}
    };
}

impl LogFormat {
    fn num(self: LogFormat, n: int) -> str {
        if n >= 0 && n < 1000 {
            return self.plain[n];
        }
        return to_str(n);
    }

    fn two(self: LogFormat, n: int) -> str {
        return strings.slice(self.three[n % 100], 1, 3);
    }

    // The timestamp, up to and including the "." before milliseconds,
    // rebuilt only when the second changes.
    fn stamp_prefix(self: LogFormat, unix_ns: int, t: bool) -> str {
        let sec = unix_ns / 1000000000;
        if sec != self.sec {
            let p = utc_parts(unix_ns);
            let date = pad4(p[0]) + "-" + self.two(p[1]) + "-" + self.two(p[2]);
            let clock = self.two(p[3]) + ":" + self.two(p[4]) + ":" +
                        self.two(p[5]) + ".";
            self.stamp_t = date + "T" + clock;
            self.stamp_sp = date + " " + clock;
            self.sec = sec;
        }
        if t {
            return self.stamp_t;
        }
        return self.stamp_sp;
    }

    fn millis(self: LogFormat, unix_ns: int) -> str {
        let ms = (unix_ns / 1000000) % 1000;
        if ms < 0 {
            ms = ms + 1000;
        }
        return self.three[ms];
    }

    // "2026-10-12T18:47:01.123Z" (t) or "2026-10-12 18:47:01.123Z".
    pub fn stamp(self: LogFormat, unix_ns: int, t: bool) -> str {
        return self.stamp_prefix(unix_ns, t) + self.millis(unix_ns) + "Z";
    }

    // A route pattern or a context name as a JSON string, quoted once
    // each: both come from a small fixed set the service wrote.
    fn quoted_route(self: LogFormat, route: str) -> str {
        if has(self.quoted, route) {
            return self.quoted[route];
        }
        let q = quote(route);
        if len(self.quoted) < 4096 {
            self.quoted[route] = q;
        }
        return q;
    }

    // "3.21ms", "0.04ms", "1.25s".
    fn duration_into(self: LogFormat, sb: builder.Str, ns: int) -> builder.Str {
        if ns >= 1000000000 {
            let cs = ns / 10000000;
            return sb.write(self.num(cs / 100)).write(".").write(self.two(cs % 100)).write("s");
        }
        let us10 = ns / 10000;
        return sb.write(self.num(us10 / 100)).write(".").write(self.two(us10 % 100)).write("ms");
    }

    // The readable summary: "GET /users/:id 200 512B 10.0.0.4 req_...".
    // Every piece is JSON-safe by construction (see safe_path, the request
    // id rules, parsed addresses) except the route, which callers quote.
    fn summary_into(self: LogFormat, sb: builder.Str, ev: LogEvent,
                    target: str) -> builder.Str {
        sb.write(ev.method).write(" ").write(target).write(" ")
          .write(self.num(ev.status)).write(" ").write(self.num(ev.size)).write("B");
        if len(ev.client_ip) > 0 {
            sb.write(" ").write(ev.client_ip);
        }
        if len(ev.request_id) > 0 {
            sb.write(" ").write(ev.request_id);
        }
        return sb;
    }

    // One JSON object and a newline, appended to `sb`.
    pub fn json_into(self: LogFormat, sb: builder.Str, ev: LogEvent) -> builder.Str {
        sb.write("{\"time\":\"").write(self.stamp_prefix(ev.time, true))
          .write(self.millis(ev.time)).write("Z\",\"level\":\"")
          .write(level_name(ev.level)).write("\",\"pid\":").write(self.pid)
          .write(",\"context\":").write(self.quoted_route(ev.context));
        if !ev.request {
            sb.write(",\"msg\":");
            quote_into(sb, ev.message);
            return sb.write("}\n");
        }
        // The summary goes inside a JSON string. Its pieces are safe as
        // they are, except a route pattern, which is the service's own
        // text: when it would need escaping, the msg carries the path
        // field's form instead.
        let target = ev.route;
        let qroute = "\"\"";
        if len(target) > 0 {
            qroute = self.quoted_route(target);
            if len(qroute) != len(target) + 2 {
                target = "(route)";
            }
        } else {
            target = ev.path;
        }
        sb.write(",\"msg\":\"");
        self.summary_into(sb, ev, target);
        sb.write("\",\"method\":\"").write(ev.method).write("\",\"route\":").write(qroute);
        if len(ev.path) > 0 {
            sb.write(",\"path\":\"").write(ev.path).write("\"");
        }
        sb.write(",\"status\":").write(self.num(ev.status)).write(",\"duration_ms\":");
        let us = ev.duration_ns / 1000;
        sb.write(self.num(us / 1000)).write(".").write(self.three[us % 1000])
          .write(",\"bytes\":").write(self.num(ev.size));
        if len(ev.request_id) > 0 {
            sb.write(",\"request_id\":\"").write(ev.request_id).write("\"");
        }
        if len(ev.client_ip) > 0 {
            sb.write(",\"client_ip\":\"").write(ev.client_ip).write("\"");
        }
        return sb.write("}\n");
    }

    // The NestJS layout and a newline, appended to `sb`:
    //   [zokor] <pid>  - <utc time>     LOG [Context] message +3.21ms
    // The trailing time is a request's duration, or for any other line
    // the time since the previous one (`since_ns`, 0 for none), as Nest
    // prints.
    pub fn pretty_into(self: LogFormat, sb: builder.Str, ev: LogEvent, color: bool,
                       since_ns: int) -> builder.Str {
        let c = level_color(ev.level);
        if color {
            sb.write(esc_seq(c));
        }
        sb.write("[zokor] ").write(self.pid).write("  - ");
        if color {
            sb.write(esc_seq("39"));
        }
        sb.write(self.stamp_prefix(ev.time, false)).write(self.millis(ev.time)).write("Z ");
        if color {
            sb.write(esc_seq(c));
        }
        sb.write(level_label(ev.level));
        if color {
            sb.write(esc_seq("33"));
        }
        sb.write(" [").write(ev.context).write("] ");
        if color {
            sb.write(esc_seq(c));
        }
        if ev.request {
            let target = ev.route;
            if len(target) == 0 {
                target = ev.path;
            }
            self.summary_into(sb, ev, target);
        } else {
            sb.write(ev.message);
        }
        if color {
            sb.write(esc_seq("33"));
        }
        if ev.request {
            sb.write(" +");
            self.duration_into(sb, ev.duration_ns);
        } else if since_ns > 0 {
            sb.write(" +").write(self.num(since_ns / 1000000)).write("ms");
        }
        if color {
            sb.write(esc_seq("39"));
        }
        return sb.write("\n");
    }

    // The same as single strings, without the newline: for a consumer
    // that wants one line at a time.
    pub fn json(self: LogFormat, ev: LogEvent) -> str {
        let sb = builder.new_str();
        self.json_into(sb, ev);
        let out = sb.finish();
        return strings.slice(out, 0, len(out) - 1);
    }

    pub fn pretty(self: LogFormat, ev: LogEvent, color: bool, since_ns: int) -> str {
        let sb = builder.new_str();
        self.pretty_into(sb, ev, color, since_ns);
        let out = sb.finish();
        return strings.slice(out, 0, len(out) - 1);
    }
}

fn pad4(n: int) -> str {
    let s = to_str(n);
    while len(s) < 4 {
        s = "0" + s;
    }
    return s;
}

// "ESC[<code>m". str literals take no \x escape; a bytes literal does.
fn esc_seq(code: str) -> str {
    if code == "31" { return to_str(b"\x1b[31m"); }
    if code == "32" { return to_str(b"\x1b[32m"); }
    if code == "33" { return to_str(b"\x1b[33m"); }
    if code == "95" { return to_str(b"\x1b[95m"); }
    return to_str(b"\x1b[39m");
}

fn level_color(l: LogLevel) -> str {
    switch l {
        case LogLevel.DEBUG { return "95"; }
        case LogLevel.LOG { return "32"; }
        case LogLevel.WARN { return "33"; }
        case LogLevel.ERROR { return "31"; }
        case LogLevel.OFF { return "39"; }
    }
    return "39";
}

fn level_label(l: LogLevel) -> str {
    switch l {
        case LogLevel.DEBUG { return "  DEBUG"; }
        case LogLevel.LOG { return "    LOG"; }
        case LogLevel.WARN { return "   WARN"; }
        case LogLevel.ERROR { return "  ERROR"; }
        case LogLevel.OFF { return "    OFF"; }
    }
    return "";
}

// The console writer. It blocks for the first event, then takes
// everything already queued and writes it with one print per 256 lines,
// then goes straight back for more. It does not sleep to gather bigger
// batches: an event that waits in the queue across a young collection is
// promoted, so a waiting record costs more than a wake-up. Measured
// against a 1ms and a 10ms pause, no pause had the highest throughput
// and the fewest promotions. When the server is idle it blocks, and
// costs nothing.
fn console_writer(lg: Logger, ch: chan[LogEvent]) {
    let f = new_log_format(os.pid());
    let sb = builder.new_str();
    let last = 0;
    while true {
        let first = chan_recv(ch);
        guard let ev = first else {
            return;
        }
        let acks: [chan[int]] = [];
        let lines = 0;
        last = write_one(lg, f, sb, ev, last, acks);
        lines = lines + 1;
        let more = true;
        while more {
            select {
                case let nx = chan_recv(ch) {
                    guard let e2 = nx else {
                        more = false;
                        continue;
                    }
                    last = write_one(lg, f, sb, e2, last, acks);
                    lines = lines + 1;
                    if lines >= 256 {
                        print(sb.take());
                        lines = 0;
                    }
                }
                default {
                    more = false;
                }
            }
        }
        let dropped = lg.take_dropped();
        if dropped > 0 {
            let w = line_event(LogLevel.WARN, "Logger",
                               to_str(dropped) + " log records dropped: the queue was full");
            last = write_one(lg, f, sb, w, last, acks);
        }
        if !sb.is_empty() {
            print(sb.take());
        }
        for a in acks {
            chan_send(a, 1);
        }
    }
}

// Appends `ev` to `sb` (or collects its ack for a flush marker); returns
// the time of the last non-request line, for Nest's +Nms.
fn write_one(lg: Logger, f: LogFormat, sb: builder.Str, ev: LogEvent, last: int,
             acks: [chan[int]]) -> int {
    if let a = ev.ack {
        push(acks, a);
        return last;
    }
    if lg.json {
        f.json_into(sb, ev);
        return last;
    }
    let since = 0;
    if !ev.request && last > 0 {
        since = ev.time - last;
    }
    f.pretty_into(sb, ev, lg.color, since);
    if ev.request {
        return last;
    }
    return ev.time;
}
