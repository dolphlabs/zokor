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
// What is NOT here yet, each its own item on the todo list: max
// concurrent connections, and TLS.

import "http";
import "proc";
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
    shutdown_timeout: int
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
        shutdown_timeout: 30000000000
    };
}

// The same defaults, overridable per field from config: IDLE_TIMEOUT,
// READ_HEADER_TIMEOUT, READ_BODY_TIMEOUT, WRITE_TIMEOUT, SHUTDOWN_TIMEOUT
// (durations, config.duration_or's format, e.g. "30s"), MAX_REQUEST_BYTES,
// MAX_REQUESTS_PER_CONN (plain integers).
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
                                      d.shutdown_timeout)
    };
}

fn idle_deadline(sc: ServerConfig) -> until {
    return until_of(time.mono() + sc.idle_timeout);
}
fn header_deadline(sc: ServerConfig) -> until {
    return until_of(time.mono() + sc.header_timeout);
}
fn body_deadline(sc: ServerConfig) -> until {
    return until_of(time.mono() + sc.body_timeout);
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

fn too_large_response(status: i32, status_text: str, code: str) -> http.Response {
    let body = "{\"error\":{\"code\":\"" + code + "\",\"message\":\"" +
               status_text + "\",\"status\":" + to_str(status) + "}}";
    return http.text_response(status, status_text,
                              "application/json; charset=utf-8", body);
}

// The dynamic path's handler call, run in its own task so a panic in
// it surfaces as `join_wait`'s own `err` -- see serve_conn's use of
// this -- instead of ending the whole connection's task silently.
// `spawn`'s target has to be a plain function, not a method, which is
// the only reason this exists rather than serve_conn calling
// `r.serve_frame(f, "")` directly.
fn dispatch[S](r: Router[S], f: http.WireFrame) -> http.Response {
    return r.serve_frame(f, "");
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
        let rr = http.read_frame(&mut c, buf, filled, idle_deadline(sc),
                                 header_deadline(sc), body_deadline(sc));
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
            if is_headers_too_large(e) {
                let resp431 = too_large_response(431,
                    "Request Header Fields Too Large", "headers_too_large");
                let _w = http.write(&mut c, resp431, &mut sa,
                                    write_deadline(sc));
            } else if is_body_too_large(e) {
                let resp413 = too_large_response(413, "Content Too Large",
                                                 "payload_too_large");
                let _w = http.write(&mut c, resp413, &mut sa,
                                    write_deadline(sc));
            }
            return;
        }
        // No request id yet, and not because one is unwanted: slang's
        // crypto.rand is unsafe from a task that also parks on socket
        // I/O -- a serve loop calling it dies under two concurrent
        // connections, in slang's own httpd shape as much as this one
        // (slang PR #189 fixes the CPU-bound half; the parking half is
        // still open). `serve_id` takes "" for exactly this case, and
        // wiring ids in is its own todo item anyway.
        served = served + 1;
        // The request that HITS max_requests_per_conn is still
        // answered normally -- only the one after it would not be.
        // Folded into the same close the client's own request can
        // already ask for, so both paths below need exactly one
        // check, not two.
        let must_close = wf.close || served >= sc.max_requests_per_conn;
        let m = r.match_static(wf);
        guard let resp = m else {
            // Not a static route: the handler runs here, isolated in
            // its own task -- see `dispatch`'s own doc comment.
            let h = spawn dispatch(r, wf);
            let jr = join_wait(h);
            guard let dyn_resp = jr else {
                // The handler panicked. spawn/join_wait already
                // isolated it -- this task, and the process, are
                // both still fine -- but the client is still owed an
                // answer. "" for the request id, the same placeholder
                // every response on this path uses today (wiring a
                // real one is a separate, already-tracked item).
                // Closed afterward rather than trusted to keep
                // serving more requests on whatever state the panic
                // left behind.
                let resp500 = respond(r.errors, "internal", "");
                let _w5 = http.write(&mut c, resp500, &mut sa,
                                     write_deadline(sc));
                return;
            }
            let wr = http.write(&mut c, dyn_resp, &mut sa,
                                write_deadline(sc));
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
        let sw = http.write_static(&mut c, resp, &mut sa, must_close,
                                   write_deadline(sc));
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

// Split out so the accept and the spawn are one step the loop below
// repeats, matching slang's own examples/httpd.
fn accept_one[S](r: Router[S], ln: &mut link, sc: ServerConfig) {
    let ar = ln.accept(until_never());
    guard let c = ar else {
        return;
    }
    spawn serve_conn(r, c, sc);
}

// One acceptor's loop: accept until the process is asked to stop.
// Stopping is SIGTERM/SIGINT, which `proc.shutdown_requested()`
// reports: slang blocks both in every spawned thread's signal mask,
// so only the main thread can run the handler, which is what lets a
// blocked `accept` observe it. Once this loop exits, `accept_first`
// drains in-flight connections up to `sc.shutdown_timeout` -- see
// `drain` below.
fn accept_loop[S](r: Router[S], ln: link, sc: ServerConfig) {
    let mut_ln = ln;
    while !proc.shutdown_requested() {
        accept_one(r, &mut mut_ln, sc);
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
    let n = acceptor_count();
    if n < 1 {
        n = 1;
    }
    let i = 1;
    while i < n {
        spawn acceptor_task(r, port, sc);
        i = i + 1;
    }
    return accept_first(r, port, sc);
}

// A spawned acceptor: its own SO_REUSEPORT listener, its own loop.
// Binding happens INSIDE the task (not before the spawn) because a
// link moved across a spawn boundary is a use-after-move: the
// spawner keeps the variable, the task gets the value, and the
// runtime kills the task. Each acceptor therefore owns its listener
// from bind to accept, and nothing crosses the boundary but the
// router (a gc struct, shared, never moved).
fn acceptor_task[S](r: Router[S], port: int, sc: ServerConfig) {
    let lr = link_listen(port, 1);
    guard let ln = lr else {
        return;
    }
    accept_loop(r, ln, sc);
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
    while proc.active_tasks() > 0 && time.mono() < deadline {
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
fn accept_first[S](r: Router[S], port: int,
                   sc: ServerConfig) -> result[int, str] {
    let first = listen_reuse(port);
    guard let ln0 = first else let e = err_of(first) {
        return err("cannot listen on port " + to_str(port) + ": " + to_str(e));
    }
    accept_loop(r, ln0, sc);
    drain(time.mono() + sc.shutdown_timeout);
    return ok(0);
}
