// The server edge: the accept loop that turns a Router into a running
// server.
//
// Everything here is deliberately thin. `listen_and_serve` accepts and
// spawns, one task per connection; a connection reads a request, hands
// it to the router, writes what comes back, and goes again if the
// client asked to keep the connection open. HTTP/1.1 pipelining is not
// supported: one request is read, answered, and only then is the next
// one read.
//
// HTTPS is terminated here when ServerConfig.tls is on (TLS_CERT_FILE and
// TLS_KEY_FILE): each connection's task runs the handshake on its own
// link, and the loop below then reads and writes it as it would plain
// TCP. Behind a proxy that terminates TLS itself, leave it off.

import "http";
import "net";
import "proc";
import "strings";
import "time";

// Four deadlines, not one, because "how long should this wait" has
// different honest answers depending on what a connection is doing --
// see http.read_frame's own doc comment, which this mirrors on
// purpose. idle_timeout governs waiting for a request to START
// arriving on a connection that might legitimately sit open for a
// while (keep-alive between a browser's clicks); header_timeout and
// body_timeout govern a request that HAS started and then stalls,
// which is the slow-loris shape a tight window exists to catch;
// write_timeout bounds sending the response, separately, since a
// client that stopped reading is a different failure than one that
// stopped sending.
pub gc struct ServerConfig {
    idle_timeout: int,
    header_timeout: int,
    body_timeout: int,
    write_timeout: int,
    // The read buffer's size: the largest a request (headers and body
    // together, since http.read_frame fills one wire) this server will
    // frame at all. A request that does not fit is refused with 431
    // (headers alone too big) or 413 (a declared body too big), not
    // silently dropped -- see serve_conn's own read_frame error
    // handling for where that distinction is made.
    max_request_bytes: int,
    // How many requests one connection serves before this server
    // closes it (answering the one that hit the limit normally first,
    // then closing rather than reading an (n+1)th). Finite so a
    // connection pinned open for its process's whole lifetime is not
    // an unbounded, never-recycled thing -- generous so it never
    // matters for ordinary keep-alive traffic, including a load test
    // running tens of thousands of requests down one connection.
    max_requests_per_conn: int,
    // How long `listen_and_serve`'s shutdown drain waits for in-flight
    // connections to finish on their own, once the process has been
    // asked to stop, before returning anyway. Bounded rather than
    // unbounded so one slow or stuck connection cannot hang a
    // deployment's shutdown forever -- whatever is still running past
    // this point goes away when the process exits, the same as it
    // would under a hard kill, just later and with everything else
    // given a real chance to finish first.
    shutdown_timeout: int,
    // Whether each dynamic request gets an id: reused from a well-formed
    // X-Request-Id, else generated (request_id_for). It is sent back as
    // X-Request-Id and carried in every error envelope, so a customer
    // quoting it finds the exact request. Static routes are fixed bytes
    // and carry none. On by default; REQUEST_IDS=false turns it off.
    request_ids: bool,
    // Proxies whose forwarding header is believed for the client's
    // address (client.sl): TRUSTED_PROXIES, comma-separated IPv4
    // addresses and CIDRs, and PROXY_HEADER (x-forwarded-for, the
    // default, or forwarded). None by default: the socket's peer is the
    // client.
    trusted_proxies: TrustedProxies,
    // Where request records and the server's own lines go (log.sl). On by
    // default: zokor's console writer, started by listen_and_serve_with.
    // LOG_FORMAT, LOG_LEVEL, LOG_REQUESTS and NO_COLOR configure it;
    // no_logger() turns it off; channel_logger hands records to another
    // package.
    logger: Logger,
    // Open connections, across every acceptor, past which a new one is
    // answered 503 and closed at once instead of served: each connection
    // holds a file descriptor and a read buffer, and a flood of idle ones
    // would otherwise exhaust both. MAX_CONNECTIONS.
    max_connections: int,
    // HTTPS, terminated by this server: off by default (no_tls()), on with
    // a certificate and key (TLS_CERT_FILE, TLS_KEY_FILE). See TlsSettings.
    tls: TlsSettings
}

// A certificate chain and its private key, as PEM files, read once when
// the server starts: a missing or mismatched pair stops it starting
// rather than leaving it serving nothing. Renewing a certificate means
// restarting the process.
pub gc struct TlsSettings {
    on: bool,
    cert_file: str,
    key_file: str,
    // A PEM bundle of the CAs whose client certificates are accepted.
    // Set, every client must present one (mutual TLS); "" asks for none.
    client_ca_file: str,
    // How long a new connection has to finish its handshake. It is the
    // connection's own deadline, in its own task, so a slow client holds
    // its slot (MAX_CONNECTIONS) until then and nobody else's.
    handshake_timeout: int,
}

pub fn no_tls() -> TlsSettings {
    return TlsSettings { on: false, cert_file: "", key_file: "",
                         client_ca_file: "", handshake_timeout: 10000000000 };
}

// HTTPS from these two PEM files, with every other setting at its default.
pub fn tls_files(cert_file: str, key_file: str) -> TlsSettings {
    let t = no_tls();
    t.on = true;
    t.cert_file = cert_file;
    t.key_file = key_file;
    return t;
}

// Safe rather than infinite, per the todo item this answers. 60s idle
// (generous -- nginx's own keepalive_timeout default is 75s, nothing
// here should be stricter than what a real browser expects), 5s to
// finish sending headers once bytes start arriving, 30s for a body
// (uploads are slower than a header block, deliberately more room),
// 10s to write a response (a client that stops reading a response is
// not a client this server owes more time to).
pub fn default_server_config() -> ServerConfig {
    return ServerConfig {
        idle_timeout: 60000000000,
        header_timeout: 5000000000,
        body_timeout: 30000000000,
        write_timeout: 10000000000,
        // 16KB: covers ordinary API traffic (headers, a JSON body) and
        // is small enough that ten thousand idle connections are not a
        // gigabyte -- the number this file's buffer literal always
        // used, now a setting instead of a constant.
        max_request_bytes: 16384,
        // 100,000: high enough that no real keep-alive session (or a
        // load test driving tens of thousands of requests down one
        // connection) ever notices it, low enough that a connection
        // genuinely is recycled eventually rather than living forever.
        max_requests_per_conn: 100000,
        // 30s: the same grace period Kubernetes gives a container by
        // default (terminationGracePeriodSeconds) and a common nginx
        // worker_shutdown_timeout choice -- long enough for an ordinary
        // in-flight request to finish, short enough that a deployment's
        // rollout is not left waiting on this one process indefinitely.
        shutdown_timeout: 30000000000,
        request_ids: true,
        trusted_proxies: no_trusted_proxies(),
        logger: default_logger(),
        // 10,000: above any one instance's honest keep-alive load, and
        // with the default 16KB read buffer about 160MB of buffers at
        // most. Raise the process's open-file limit to match.
        max_connections: 10000,
        tls: no_tls()
    };
}

// The same defaults, overridable per field from config: IDLE_TIMEOUT,
// READ_HEADER_TIMEOUT, READ_BODY_TIMEOUT, WRITE_TIMEOUT, SHUTDOWN_TIMEOUT
// (durations, config.duration_or's format, e.g. "30s"), MAX_REQUEST_BYTES,
// MAX_REQUESTS_PER_CONN (plain integers), REQUEST_IDS (true/false),
// TRUSTED_PROXIES and PROXY_HEADER (see trusted_proxies_from), LOG_FORMAT,
// LOG_LEVEL, LOG_REQUESTS and NO_COLOR (see logger_from), MAX_CONNECTIONS
// (a positive integer), and TLS_CERT_FILE, TLS_KEY_FILE,
// TLS_CLIENT_CA_FILE and TLS_HANDSHAKE_TIMEOUT (see tls_from).
pub fn server_config_from(cfg: Config) -> ServerConfig {
    let d = default_server_config();
    return ServerConfig {
        idle_timeout: duration_or(cfg, "IDLE_TIMEOUT", d.idle_timeout),
        header_timeout: duration_or(cfg, "READ_HEADER_TIMEOUT",
                                    d.header_timeout),
        body_timeout: duration_or(cfg, "READ_BODY_TIMEOUT", d.body_timeout),
        write_timeout: duration_or(cfg, "WRITE_TIMEOUT", d.write_timeout),
        max_request_bytes: int_or(cfg, "MAX_REQUEST_BYTES",
                                  d.max_request_bytes),
        max_requests_per_conn: int_or(cfg, "MAX_REQUESTS_PER_CONN",
                                      d.max_requests_per_conn),
        shutdown_timeout: duration_or(cfg, "SHUTDOWN_TIMEOUT",
                                      d.shutdown_timeout),
        request_ids: bool_or(cfg, "REQUEST_IDS", d.request_ids),
        trusted_proxies: trusted_proxies_from(cfg),
        logger: logger_from(cfg),
        max_connections: max_connections_from(cfg, d.max_connections),
        tls: tls_from(cfg, d.tls)
    };
}

// TLS_CERT_FILE and TLS_KEY_FILE together turn HTTPS on; one without the
// other is recorded for check(cfg), as is a client CA with no certificate
// to go with it. The files are opened when the server starts, not here.
fn tls_from(cfg: Config, d: TlsSettings) -> TlsSettings {
    let t = no_tls();
    t.cert_file = str_or(cfg, "TLS_CERT_FILE", d.cert_file);
    t.key_file = str_or(cfg, "TLS_KEY_FILE", d.key_file);
    t.client_ca_file = str_or(cfg, "TLS_CLIENT_CA_FILE", d.client_ca_file);
    t.handshake_timeout = duration_or(cfg, "TLS_HANDSHAKE_TIMEOUT",
                                      d.handshake_timeout);
    let has_cert = len(t.cert_file) > 0;
    let has_key = len(t.key_file) > 0;
    if has_cert && !has_key {
        record(cfg, "TLS_KEY_FILE", "", "is required when TLS_CERT_FILE is set");
    } else if has_key && !has_cert {
        record(cfg, "TLS_CERT_FILE", "", "is required when TLS_KEY_FILE is set");
    } else if len(t.client_ca_file) > 0 && !has_cert {
        record(cfg, "TLS_CLIENT_CA_FILE", t.client_ca_file,
               "needs TLS_CERT_FILE and TLS_KEY_FILE: mutual TLS is TLS first");
    }
    t.on = has_cert && has_key;
    return t;
}

// The server context for `t`, made once and shared by every connection.
// none when TLS is off.
fn load_tls(t: TlsSettings) -> result[opt[rawptr], str] {
    let off: opt[rawptr] = none;
    if !t.on {
        return ok(off);
    }
    let cr: result[rawptr, str] = net.tls_server_ctx(t.cert_file, t.key_file);
    guard let ctx = cr else let e = err_of(cr) {
        return err("cannot load TLS_CERT_FILE/TLS_KEY_FILE: " + e);
    }
    if len(t.client_ca_file) > 0 {
        let rr: result[bool, str] = net.tls_ctx_require_client(ctx, t.client_ca_file);
        guard let _r = rr else let e2 = err_of(rr) {
            return err("cannot load TLS_CLIENT_CA_FILE: " + e2);
        }
    }
    return ok(some(ctx));
}

// MAX_CONNECTIONS, a positive integer. Anything else is recorded for
// check(cfg) rather than silently replaced by the default.
fn max_connections_from(cfg: Config, fallback: int) -> int {
    let raw = str_or(cfg, "MAX_CONNECTIONS", "");
    if len(raw) == 0 {
        return fallback;
    }
    let pr = to_int(raw);
    if let n = pr {
        if n >= 1 {
            return n;
        }
    }
    record(cfg, "MAX_CONNECTIONS", raw, "must be a positive integer");
    return fallback;
}

// TRUSTED_PROXIES and PROXY_HEADER, read into a TrustedProxies. A bad
// entry is recorded on `cfg` like any other configuration problem, so
// check(cfg) reports it with everything else before the server starts.
fn trusted_proxies_from(cfg: Config) -> TrustedProxies {
    let tp = no_trusted_proxies();
    let list = str_or(cfg, "TRUSTED_PROXIES", "");
    if len(list) > 0 {
        let r = parse_trusted_proxies(list);
        if let parsed = r {
            tp = parsed;
        } else let e = err_of(r) {
            // recorded, then carry on: PROXY_HEADER is checked too, so
            // check() reports every problem at once
            record(cfg, "TRUSTED_PROXIES", list, e);
        }
    }
    let header = strings.to_lower(str_or(cfg, "PROXY_HEADER", tp.header));
    if header != "x-forwarded-for" && header != "forwarded" {
        record(cfg, "PROXY_HEADER", header,
               "must be x-forwarded-for or forwarded");
        return tp;
    }
    tp.header = header;
    return tp;
}

// The three read deadlines start together, so they share one clock
// read (`now`, from time.mono()) instead of taking one each: a clock
// read is a measurable share of a request on some hosts (~0.17 us in a
// Linux VM, per docs/benchmarks.md).
fn idle_deadline(sc: ServerConfig, now: duration) -> until {
    return until_of(now + sc.idle_timeout);
}
fn header_deadline(sc: ServerConfig, now: duration) -> until {
    return until_of(now + sc.header_timeout);
}
fn body_deadline(sc: ServerConfig, now: duration) -> until {
    return until_of(now + sc.body_timeout);
}
fn write_deadline(sc: ServerConfig) -> until {
    return until_of(time.mono() + sc.write_timeout);
}

// The send arena's size, still a literal: it holds one response at a
// time (reset after every write), and unlike the read side there is
// no "declared but oversized" shape to refuse -- an oversized dynamic
// response already falls back to http.write's own slower GC path
// (see stdlib/http's own emit/write split) rather than needing a
// limit here.
fn response_bytes() -> int {
    return 16384;
}

// http.read_frame's two too-large messages, exactly -- matched by
// text because that is the interface read_frame offers (see its own
// doc comment on why the two are distinguished at all: RFC 9110's
// 431 for headers vs 413 for a body/payload are different problems
// with different meanings to a client, not the same failure twice).
// Matching by text rather than a richer error type is only safe
// because this package is read_frame's one caller, coordinated in
// the same repo; a second consumer would be reason to give read_frame
// a real error enum instead.
fn is_headers_too_large(e: str) -> bool {
    return e == "request headers too large for buffer";
}
fn is_body_too_large(e: str) -> bool {
    return e == "request too large for buffer";
}

fn too_large_response(reg: Registry, status_text: str, code: str) -> http.Response {
    return closing(respond_with(reg, code, status_text, ""));
}

// Framing failures have no trustworthy request headers to inherit.
fn trace_edge_registry[S](r: Router[S]) -> Registry {
    if let driver = r.tracer {
        let made = trace_context(driver, b"");
        if let ctx = made { return trace_registry(r.errors, ctx); }
    }
    return r.errors;
}

// A response this connection is closed after must say so (RFC 9112
// 9.6): a client told keep-alive may already be sending its next request
// on it, and a POST sent there cannot safely be retried. http.write
// writes one Connection header, from the last `connection` line, so
// this overrides a handler's own keep-alive rather than adding a second.
fn closing(r: http.Response) -> http.Response {
    return http.with_header(r, "connection", "close");
}

// The dynamic path's handler call, run in its own task so a panic in
// it surfaces as `join_wait`'s own `err` -- see serve_conn's use of
// this -- instead of ending the whole connection's task silently.
// `spawn`'s target has to be a plain function, not a method, which is
// the only reason this exists rather than serve_conn calling
// `r.serve_frame(f, "")` directly.
fn dispatch[S](r: Router[S], f: http.WireFrame, request_id: str,
               client_ip: str) -> Served {
    return r.serve_frame_core(f, request_id, client_ip);
}

// Whether this connection writes request records: decided once per
// connection, so a server with logging off pays nothing per request.
fn logs_any_request(lg: Logger) -> bool {
    return lg.requests && lg.enabled(LogLevel.ERROR);
}

fn log_request(lg: Logger, method: str, route: str, raw_path: str,
               status: int, t0: duration, size: int, rid: str, client: str,
               trace_id: str) {
    if !logs_requests(lg, status) { return; }
    let ev = request_event(method, route, raw_path, status,
                          (time.mono() - t0) as int, size, rid, client);
    ev.trace_id = trace_id;
    ev.ack = lg.no_ack;
    lg.emit(ev);
}

// One connection, until the client goes away or asks to close.
//
// A read error closes the connection rather than answering: it means
// this server could not tell where the request ended, so it cannot tell
// where the next one begins either. That is the framing rule slang's
// own http package documents, and it is a security boundary (request
// smuggling), not a convenience.
//
// Two dispatch paths, chosen per route at registration, not per
// request: a static route (exact GET, no middleware, fixed body --
// `GET /` is the shape) answers from its snapshot via
// `match_static` with NO Request, NO maps, NO Ctx, NO handler call,
// and -- since none of that ran -- nothing that could panic, so this
// path costs no isolation either; everything else goes through
// `dispatch` (a plain-function wrapper around `serve_frame`, which
// builds the Request once for the route that runs), spawned and
// joined so a panic in application handler code answers `500`
// instead of silently ending the connection. `serve_id` stays for
// callers that already hold a Request.
pub fn serve_conn[S](r: Router[S], c: link, sc: ServerConfig) {
    // Once per connection: a connection's peer does not change.
    let peer_ip = peer_ip_of(inspect(c.peer()));
    let ids = request_ids();
    let lg = sc.logger;
    let logging = logs_any_request(lg);
    let ra = arena_new(sc.max_request_bytes);
    let sa = arena_new(response_bytes());
    let buf = ra.wire(sc.max_request_bytes);
    let filled = 0;
    let served = 0;
    while true {
        // Fresh deadlines every request, not one computed at connect
        // time: a connection that has already served ten requests
        // still gets the full idle window before an eleventh, the
        // same as its first ever request did.
        let now = time.mono();
        let rr = http.read_frame(&mut c, buf, filled, idle_deadline(sc, now),
                                 header_deadline(sc, now),
                                 body_deadline(sc, now));
        guard let wf = rr else let e = err_of(rr) {
            // A read error other than "too large" closes the
            // connection rather than answering: it means this server
            // could not tell where the request ended, so it cannot
            // tell where the next one begins either -- the framing
            // rule slang's own http package documents, and a security
            // boundary (request smuggling), not a convenience. "Too
            // large" is different: read_frame already knows exactly
            // where THIS request would have ended (its declared
            // Content-Length, or the fact that its headers alone
            // never terminated), so answering before closing cannot
            // desync anything -- there is no next request on this
            // connection either way, since it closes right after.
            let edge = r.errors;
            if is_headers_too_large(e) || is_body_too_large(e) {
                edge = trace_edge_registry(r);
            }
            if logging && (is_headers_too_large(e) || is_body_too_large(e)) {
                let st = 413;
                if is_headers_too_large(e) {
                    st = 431;
                }
                log_request(lg, "-", "", "-", st, time.mono(), 0, "", peer_ip, edge.trace_id);
            }
            if is_headers_too_large(e) {
                if let m = r.observations { m.enter(); m.leave("OTHER", "", 431, (time.mono() - now) as int); }
                let resp431 = r.security.apply(too_large_response(edge,
                    "Request Header Fields Too Large", "headers_too_large"));
                let _w = http.write(&mut c, resp431, &mut sa,
                                    write_deadline(sc));
            } else if is_body_too_large(e) {
                if let m = r.observations { m.enter(); m.leave("OTHER", "", 413, (time.mono() - now) as int); }
                let resp413 = r.security.apply(too_large_response(edge,
                    "Content Too Large", "payload_too_large"));
                let _w = http.write(&mut c, resp413, &mut sa,
                                    write_deadline(sc));
            }
            return;
        }
        served = served + 1;
        // Only read when logging: a clock read is a measurable share of a
        // request on some hosts (see idle_deadline).
        let t0 = now;
        if logging {
            t0 = time.mono();
        }
        let measured = false;
        if let m = r.observations {
            if !metrics_scrape(wf.method, wf.path, m) {
                m.enter();
                measured = true;
                if !logging { t0 = time.mono(); }
            }
        }
        let context = empty_trace();
        if let driver = r.tracer {
            let made = trace_context(driver, wf.headers);
            guard let ctx = made else {
                let failure = respond(r.errors, "internal", "");
                if r.cors.on {
                    let origins = header_list(wf.headers, "origin");
                    let origin = "";
                    if len(origins) > 0 { origin = origins[0]; }
                    failure = r.cors.apply(failure, origin);
                }
                failure = closing(r.security.apply(failure));
                let _w = http.write(&mut c, failure, &mut sa, write_deadline(sc));
                if let m = r.observations {
                    if measured { m.leave(wf.method, r.metrics_pattern(wf.method, wf.path), 500, (time.mono() - t0) as int); }
                }
                if logging { log_request(lg, wf.method, "", wf.path, 500, t0, len(failure.body), "", peer_ip, ""); }
                return;
            }
            context = ctx;
        }
        // The request that HITS max_requests_per_conn is still
        // answered normally -- only the one after it would not be.
        // Folded into the same close the client's own request can
        // already ask for, so both paths below need exactly one
        // check, not two.
        let must_close = wf.close || served >= sc.max_requests_per_conn;
        let si = r.static_index(wf);
        if si < 0 {
            // Not a static route: the handler runs here, isolated in
            // its own task -- see `dispatch`'s own doc comment. Its id
            // is made here, not in the router, so the 500 below carries
            // the same one if the handler panics.
            let rid = "";
            if sc.request_ids {
                rid = request_id_with(wf.headers, ids);
            }
            let client = peer_ip;
            if !sc.trusted_proxies.is_empty() {
                client = client_ip_of(peer_ip, wf.headers, sc.trusted_proxies);
            }
            let scope = r;
            if len(context.trace_id) > 0 { scope = trace_router(r, context); }
            let h = spawn dispatch(scope, wf, rid, client);
            let jr = join_wait(h);
            guard let routed = jr else let pe = err_of(jr) {
                // The handler panicked. spawn/join_wait already
                // isolated it -- this task, and the process, are
                // both still fine -- but the client is still owed an
                // answer, under the request's id, in the envelope and
                // the X-Request-Id header alike. Closed afterward rather
                // than trusted to keep serving more requests on whatever
                // state the panic left behind.
                let resp500 = closing(respond(scope.errors, "internal", rid));
                if len(rid) > 0 {
                    resp500 = http.with_header(resp500, "x-request-id", rid);
                }
                if r.cors.on {
                    // Built here, not by the router, so CORS is applied
                    // here: without it the page sees a CORS error, not
                    // the 500.
                    let origins = header_list(wf.headers, "origin");
                    let origin = "";
                    if len(origins) > 0 {
                        origin = origins[0];
                    }
                    resp500 = r.cors.apply(resp500, origin);
                }
                resp500 = r.security.apply(resp500);
                let _w5 = http.write(&mut c, resp500, &mut sa,
                                     write_deadline(sc));
                if let m = r.observations {
                    if measured {
                        m.leave(wf.method, r.metrics_pattern(wf.method, wf.path), 500, (time.mono() - t0) as int);
                    }
                }
                if logging {
                    let bound = traced_logger(lg, context);
                    bound.request_id = rid;
                    bound.error("HTTP", "handler panicked: " + pe +
                             request_suffix(rid));
                    log_request(lg, wf.method, "", wf.path, 500, t0,
                                len(resp500.body), rid, client, context.trace_id);
                }
                return;
            }
            if let sock = routed.upgrade {
                if routed.resp.status == 101 && wf.method == "GET" {
                    // A WebSocket route accepted: the 101, then the
                    // connection is the socket's until it ends.
                    let uw = http.write(&mut c, routed.resp, &mut sa, write_deadline(sc));
                    if logging {
                        log_request(lg, wf.method, routed.route, wf.path, 101, t0, 0,
                                    rid, client, context.trace_id);
                    }
                    if let m = r.observations {
                        if measured {
                            m.leave(wf.method, routed.route, 101, (time.mono() - t0) as int);
                        }
                    }
                    guard let _u = uw else {
                        sock.finish("handshake write failed");
                        leave_hubs(sock);
                        return;
                    }
                    ws_session(r, &mut c, buf, wf.filled, sc, sock);
                    return;
                }
            }
            let dyn_resp = routed.resp;
            let out = dyn_resp;
            if must_close {
                out = closing(dyn_resp);
            }
            // A HEAD answer keeps the body GET would have had until here:
            // write_head frames its length and sends none of it.
            let wr: result[int, fault] = ok(0);
            if wf.method == "HEAD" {
                wr = http.write_head(&mut c, out, &mut sa, write_deadline(sc));
            } else {
                wr = http.write(&mut c, out, &mut sa, write_deadline(sc));
            }
            if logging {
                log_request(lg, wf.method, routed.route, wf.path,
                            out.status as int, t0, len(out.body), rid, client, context.trace_id);
            }
            if let m = r.observations {
                if measured {
                    m.leave(wf.method, routed.route, out.status as int, (time.mono() - t0) as int);
                }
            }
            guard let _n = wr else {
                return;
            }
            sa.reset();
            if must_close {
                return;
            }
            filled = wf.filled;
            continue;
        }
        // Static send still needs a wire to copy into, and wires
        // come from arenas -- but a 16KB send arena per static-only
        // connection is 16KB of mmap per keep-alive conn for a
        // 130-byte memcpy. The send arena stays (dynamic responses
        // size into it); shrinking the static-only case is a
        // follow-up, not this diff.
        // Both variants are prebuilt with the security headers in them,
        // and either is sent as written: `false` here means "send the
        // prebuilt bytes", not "keep the connection open".
        let hit = r.routes[si].static_hit;
        if must_close {
            hit = r.routes[si].static_close_hit;
        }
        guard let resp = hit else {
            if let m = r.observations {
                if measured {
                    m.leave(wf.method, r.routes[si].pattern, 500, (time.mono() - t0) as int);
                }
            }
            return;
        }
        let sw = http.write_static(&mut c, resp, &mut sa, false, write_deadline(sc));
        if let m = r.observations {
            if measured {
                m.leave(wf.method, r.routes[si].pattern, resp.status as int, (time.mono() - t0) as int);
            }
        }
        if logging {
            let sclient = peer_ip;
            if !sc.trusted_proxies.is_empty() {
                sclient = client_ip_of(peer_ip, wf.headers, sc.trusted_proxies);
            }
            log_request(lg, wf.method, r.routes[si].pattern, wf.path,
                        resp.status as int, t0, len(resp.body), "", sclient, context.trace_id);
        }
        guard let _n = sw else {
            return;
        }
        sa.reset();
        if must_close {
            return;
        }
        filled = wf.filled;
    }
}

// " (req_...)" for a line about one request, "" without an id.
fn request_suffix(rid: str) -> str {
    if len(rid) == 0 {
        return "";
    }
    return " (" + rid + ")";
}

// The server-wide connection count, shared by every acceptor.
pub gc struct ConnGate {
    lock: mutex,
    open: int,
    max: int,
    // Connections refused since the last report, and when that was
    // (time.mono nanoseconds).
    refused: int,
    reported_at: int,
}

pub fn new_conn_gate(max: int) -> ConnGate {
    let m = max;
    if m < 1 {
        m = 1;
    }
    return ConnGate { lock: make_mutex(), open: 0, max: m, refused: 0,
                      reported_at: 0 };
}

impl ConnGate {
    // Takes a slot for a new connection; false (and counted as refused)
    // when every slot is taken.
    pub fn enter(self: ConnGate) -> bool {
        mutex_lock(self.lock);
        let ok_now = self.open < self.max;
        if ok_now {
            self.open = self.open + 1;
        } else {
            self.refused = self.refused + 1;
        }
        mutex_unlock(self.lock);
        return ok_now;
    }

    pub fn leave(self: ConnGate) {
        mutex_lock(self.lock);
        if self.open > 0 {
            self.open = self.open - 1;
        }
        mutex_unlock(self.lock);
    }

    pub fn open_now(self: ConnGate) -> int {
        mutex_lock(self.lock);
        let n = self.open;
        mutex_unlock(self.lock);
        return n;
    }

    // The refusals to report, at most once per second of `now`: 0 when
    // there are none or the last report was under a second ago. A flood
    // is one log line a second, not one per connection.
    pub fn refusals_to_report(self: ConnGate, now: int) -> int {
        mutex_lock(self.lock);
        let n = 0;
        if self.refused > 0 && now - self.reported_at >= 1000000000 {
            n = self.refused;
            self.refused = 0;
            self.reported_at = now;
        }
        mutex_unlock(self.lock);
        return n;
    }
}

// serve_conn, then the connection's slot back -- the one place a
// connection ends, so the count cannot drift.
fn serve_counted[S](r: Router[S], c: link, sc: ServerConfig, gate: ConnGate,
                    tls: opt[rawptr]) {
    if let ctx = tls {
        serve_tls_conn(r, c, sc, ctx);
    } else {
        serve_conn(r, c, sc);
    }
    gate.leave();
}

// serve_conn over TLS: the handshake first, under its own deadline, then
// the same loop. A failed handshake has no request to answer -- a port
// scanner, a plaintext client, a browser's dropped preconnect -- so it is
// logged at debug and the connection closed.
pub fn serve_tls_conn[S](r: Router[S], c: link, sc: ServerConfig, ctx: rawptr) {
    let hr = c.tls_accept(ctx, until_of(time.mono() + sc.tls.handshake_timeout));
    guard let _h = hr else let e = err_of(hr) {
        if sc.logger.enabled(LogLevel.DEBUG) {
            sc.logger.debug("TLS", "handshake with " + peer_ip_of(inspect(c.peer())) +
                            " failed: " + to_str(e));
        }
        return;
    }
    serve_conn(r, c, sc);
}

// The answer to a connection over the cap: a 503 the client can act on
// (a load balancer retries elsewhere) instead of a reset or a stall in
// the accept backlog. Nothing is read, so the connection closes right
// after; the short deadline keeps a client that is not reading from
// holding up the accept loop.
fn refuse_conn(c: link, sec: Security, reg: Registry) {
    let a = arena_new(512);
    let mut_c = c;
    let resp = http.with_header(closing(respond_with(reg, "unavailable",
        "the server is at its connection limit", "")), "retry-after", "1");
    resp = sec.apply(resp);
    let _w = http.write(&mut mut_c, resp, &mut a, until_of(time.mono() + 100000000));
}

// One accept. Returns "" or, when accept itself failed, why.
fn accept_one[S](r: Router[S], ln: &mut link, sc: ServerConfig,
                 gate: ConnGate, tls: opt[rawptr]) -> str {
    let ar = ln.accept(until_never());
    guard let c = ar else let e = err_of(ar) {
        return to_str(e);
    }
    // if/else rather than an early return: slang's move check is not
    // path-sensitive, so a move in a returning branch still counts after it.
    if gate.enter() {
        spawn serve_counted(r, c, sc, gate, tls);
    } else if sc.tls.on {
        // A 503 would be plaintext to a client expecting a handshake, and
        // a handshake is the work the cap exists to refuse: close it.
        drop_conn(c);
    } else {
        refuse_conn(c, r.security, trace_edge_registry(r));
        let n = gate.refusals_to_report(time.mono() as int);
        if n > 0 {
            sc.logger.warn("Server", to_str(n) + " connections refused: at MAX_CONNECTIONS (" +
                           to_str(gate.max) + ")");
        }
    }
    return "";
}

// Closes `c`: a link closes when its last owner returns.
fn drop_conn(c: link) {
    let _p = c.port();
}

// The pause after a failed accept: 5ms, doubling to 1s while it keeps
// failing. Accept fails when the process is out of file descriptors,
// and then it fails at once, every time: without a pause the loop
// spins a core at exactly the moment the server can least afford it.
pub fn accept_backoff(prev_ns: int) -> int {
    if prev_ns <= 0 {
        return 5000000;
    }
    let next = prev_ns * 2;
    if next > 1000000000 {
        return 1000000000;
    }
    return next;
}

// One acceptor's loop: accept until the process is asked to stop.
// Stopping is SIGTERM/SIGINT, which `proc.shutdown_requested()`
// reports: slang blocks both in every spawned thread's signal mask,
// so only the main thread can run the handler, which is what lets a
// blocked `accept` observe it. Once this loop exits, `accept_first`
// drains in-flight connections up to `sc.shutdown_timeout` -- see
// `drain` below.
fn accept_loop[S](r: Router[S], ln: link, sc: ServerConfig, gate: ConnGate,
                  tls: opt[rawptr]) {
    let mut_ln = ln;
    let backoff = 0;
    while !proc.shutdown_requested() {
        let why = accept_one(r, &mut mut_ln, sc, gate, tls);
        if len(why) == 0 {
            if backoff > 0 {
                sc.logger.log("Server", "accepting again");
                backoff = 0;
            }
            continue;
        }
        if backoff == 0 {
            sc.logger.error("Server", "accept failed: " + why +
                            " (backing off; at the open-file limit, raise it or MAX_CONNECTIONS)");
        }
        backoff = accept_backoff(backoff);
        time.sleep(backoff);
    }
}

// How many accept loops to run: `ZOKOR_ACCEPTORS` when set and
// positive, else 1 (measured: extra acceptors add nothing on this
// machine -- see listen_and_serve). A separate function so tests
// pin it without binding a port.
fn acceptor_count() -> int {
    let e = proc.getenv("ZOKOR_ACCEPTORS");
    guard let s = e else {
        return 1;
    }
    let pr = to_int(s);
    guard let n = pr else {
        return 1;
    }
    if n < 1 {
        return 1;
    }
    return n;
}

// A SO_REUSEPORT listener, wrapped so the error names the port the
// same way `listen_and_serve` always has.
fn listen_reuse(port: int) -> result[link, fault] {
    return link_listen(port, 1);
}

// Bind, then accept until the process is asked to stop.
//
// There is no host parameter because slang's `link_listen` has none: it
// binds every interface. Returns `err` when the port cannot be bound --
// the common one is "already in use" -- and `ok` once the loop has
// stopped and in-flight connections have either finished or run out
// their `sc.shutdown_timeout`.
//
// Acceptors: one accept loop per worker, each on its own SO_REUSEPORT
// listener (`link_listen(port, 1)`), the same shape slang's own
// bench/http_opt and bench/http/realserver use.
//
// Measured before keeping it: on the static `/` path (no Request,
// no handler, prebuilt bytes) acceptors make NO difference --
// ZOKOR_ACCEPTORS=1 and 8 both do ~72k rps on `GET /`, because the
// bottleneck is per-request work, not accepts. So the default stays
// 1: extra acceptors are extra tasks contending on the same cores for
// no gain, and the knob remains for machines where accepts ARE the
// bottleneck. `ZOKOR_ACCEPTORS` overrides; default 1.
//
// The dynamic `/users/:id` path's timeouts this comment used to
// mention here (at both 1 and 8 acceptors) are NOT an acceptor-count
// finding -- root-caused since: it is queueing-delay collapse from
// driving more concurrent connections than this benchmark machine's
// real capacity for that path, not a bug in the accept loop, the
// router, or the GC (SLANG_GC_STAT during the same load: pauses topped
// out under 8ms; nowhere near the hundreds-of-ms tail observed).
// `wrk -c{8,16,32,50}` on the same box+binary: p99 1.2ms / 2.5ms /
// 30ms / ~900ms -- a saturation cliff, not a step function, and Go's
// net/http and Fiber stay clean at this repo's usual c=50 on the same
// machine because their own per-request cost is lower, giving them
// more headroom before the same cliff. See docs/benchmarks.md's
// "Where the tail actually comes from" for the full bisection.
pub fn listen_and_serve[S](r: Router[S], port: int) -> result[int, str] {
    return listen_and_serve_with(r, port, default_server_config());
}

// Same, with timeouts, limits, and the shutdown drain window under the
// caller's control -- built from config with server_config_from, or by
// hand for a test that wants a deliberately short one.
pub fn listen_and_serve_with[S](r: Router[S], port: int,
                                sc: ServerConfig) -> result[int, str] {
    sc.logger.start();
    let lt = load_tls(sc.tls);
    guard let tls = lt else let te = err_of(lt) {
        sc.logger.error("Server", te);
        sc.logger.flush(1000000000);
        return err(te);
    }
    r.ready.logger = sc.logger;
    log_routes(r, sc.logger);
    let gate = new_conn_gate(sc.max_connections);
    let n = acceptor_count();
    if n < 1 {
        n = 1;
    }
    let i = 1;
    while i < n {
        spawn acceptor_task(r, port, sc, gate, tls);
        i = i + 1;
    }
    return accept_first(r, port, sc, gate, tls);
}

// "Mapped {/users/:id, GET} route" per route, as Nest prints at startup,
// and the health paths when mounted.
fn log_routes[S](r: Router[S], lg: Logger) {
    if !lg.enabled(LogLevel.LOG) {
        return;
    }
    for rt in r.routes {
        lg.log("Router", "Mapped {" + rt.pattern + ", " +
               to_str(rt.method) + "} route");
    }
    if len(r.ready.live_path) > 0 {
        lg.log("Router", "Mapped {" + r.ready.live_path + ", GET} liveness");
        lg.log("Router", "Mapped {" + r.ready.ready_path + ", GET} readiness");
    }
}

// A spawned acceptor: its own SO_REUSEPORT listener, its own loop.
// Binding happens INSIDE the task (not before the spawn) because a
// link moved across a spawn boundary is a use-after-move: the
// spawner keeps the variable, the task gets the value, and the
// runtime kills the task. Each acceptor therefore owns its listener
// from bind to accept, and nothing crosses the boundary but the
// router (a gc struct, shared, never moved).
fn acceptor_task[S](r: Router[S], port: int, sc: ServerConfig, gate: ConnGate,
                    tls: opt[rawptr]) {
    let lr = link_listen(port, 1);
    guard let ln = lr else {
        return;
    }
    accept_loop(r, ln, sc, gate, tls);
}

// Waits for every in-flight `spawn`ed task to finish, same as
// `proc.wait_idle()` would, but bounded: gives up once `deadline`
// (a `time.mono()`-scale instant, built the same way every other
// deadline in this file is: `time.mono() + <a ServerConfig field>`)
// has passed, however many tasks are still running.
// `proc.active_tasks()` counts every spawned task in the process, not
// only this server's connections -- the same thing `listen_and_serve`'s
// pre-Limits drain already relied on unbounded, so this changes nothing
// about what is counted, only how long counting it is allowed to take.
// Polled rather than a park, matching the loop this replaces: there is
// no "wake me when idle, or after N nanoseconds, whichever first"
// primitive to park on instead.
fn drain(deadline: duration) {
    drain_to(deadline, 0);
}

// The same wait, down to `others` tasks instead of none. A caller that
// is itself a spawned task -- every test under `slangc test`, which
// runs each test in its own task -- counts in `proc.active_tasks()`,
// so waiting for zero from there would wait for itself forever.
fn drain_to(deadline: duration, others: int) {
    while proc.active_tasks() > others && time.mono() < deadline {
        time.sleep(20000000);
    }
}

// The main task's own acceptor: binds here (so a bad port returns
// err instead of silently serving nothing) and loops here.
//
// Once accepting stops, in-flight connections get up to
// `sc.shutdown_timeout` to finish on their own before this returns
// regardless -- long enough for ordinary work to complete, bounded so
// one stuck connection cannot hang a deployment's shutdown forever.
fn accept_first[S](r: Router[S], port: int, sc: ServerConfig,
                   gate: ConnGate, tls: opt[rawptr]) -> result[int, str] {
    let first = listen_reuse(port);
    guard let ln0 = first else let e = err_of(first) {
        let why = "cannot listen on port " + to_str(port) + ": " + to_str(e);
        sc.logger.error("Server", why);
        sc.logger.flush(1000000000);
        return err(why);
    }
    let scheme = "";
    if sc.tls.on {
        scheme = " (HTTPS)";
    }
    sc.logger.log("Server", "Listening on :" + to_str(port) + scheme);
    accept_loop(r, ln0, sc, gate, tls);
    sc.logger.log("Server", "Shutting down: draining in-flight requests");
    // The console writer is a task too, and outlives every connection:
    // waiting for zero would always run out the whole timeout.
    drain_to(time.mono() + sc.shutdown_timeout, sc.logger.own_tasks());
    sc.logger.log("Server", "Stopped");
    sc.logger.flush(1000000000);
    return ok(0);
}
