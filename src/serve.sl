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
// What is NOT here yet, each its own item on the todo list: limits
// (the request buffer is one fixed size, and a request larger than it
// fails the read rather than answering 413), graceful draining with a
// deadline, per-request panic recovery, and TLS.

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
    write_timeout: int
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
        write_timeout: 10000000000
    };
}

// The same defaults, overridable per field from config: IDLE_TIMEOUT,
// READ_HEADER_TIMEOUT, READ_BODY_TIMEOUT, WRITE_TIMEOUT, each a
// duration string (config.duration_or's own format, e.g. "30s").
pub fn server_config_from(cfg: Config) -> ServerConfig {
    let d = default_server_config();
    return ServerConfig {
        idle_timeout: duration_or(cfg, "IDLE_TIMEOUT", d.idle_timeout),
        header_timeout: duration_or(cfg, "READ_HEADER_TIMEOUT",
                                    d.header_timeout),
        body_timeout: duration_or(cfg, "READ_BODY_TIMEOUT", d.body_timeout),
        write_timeout: duration_or(cfg, "WRITE_TIMEOUT", d.write_timeout)
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

// The read buffer is the largest request this server will frame --
// headers and body together, since http.read fills one wire. 16 KB
// covers ordinary API traffic (headers, a JSON body) and is small
// enough that ten thousand idle connections are not a gigabyte. The
// send arena is reset after every response, so it only ever has to
// hold one.
//
// Both are literals rather than settings because making them settings
// is the Limits item, which also owes a 413 instead of the dropped
// connection an oversized request gets today. A service that needs
// more before then raises these two numbers.
fn request_bytes() -> int {
    return 16384;
}

fn response_bytes() -> int {
    return 16384;
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
// `serve_static` with NO Request, NO maps, NO Ctx, NO handler call
// (see Route.has_static); everything else goes through
// `serve_frame`, which builds the Request once for the route that
// runs. `serve_id` stays for callers that already hold a Request.
pub fn serve_conn[S](r: Router[S], c: link, sc: ServerConfig) {
    let ra = arena_new(request_bytes());
    let sa = arena_new(response_bytes());
    let buf = ra.wire(request_bytes());
    let filled = 0;
    while true {
        // Fresh deadlines every request, not one computed at connect
        // time: a connection that has already served ten requests
        // still gets the full idle window before an eleventh, the
        // same as its first ever request did.
        let rr = http.read_frame(&mut c, buf, filled, idle_deadline(sc),
                                 header_deadline(sc), body_deadline(sc));
        guard let wf = rr else {
            return;
        }
        // No request id yet, and not because one is unwanted: slang's
        // crypto.rand is unsafe from a task that also parks on socket
        // I/O -- a serve loop calling it dies under two concurrent
        // connections, in slang's own httpd shape as much as this one
        // (slang PR #189 fixes the CPU-bound half; the parking half is
        // still open). `serve_id` takes "" for exactly this case, and
        // wiring ids in is its own todo item anyway.
        let sr = r.serve_static(wf);
        guard let resp = sr else let dyn_resp = err_of(sr) {
            let wr = http.write(&mut c, dyn_resp, &mut sa,
                                write_deadline(sc));
            guard let _n = wr else {
                return;
            }
            sa.reset();
            if wf.close {
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
        let sw = http.write_static(&mut c, resp, &mut sa, wf.close,
                                   write_deadline(sc));
        guard let _n = sw else {
            return;
        }
        sa.reset();
        if wf.close {
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
// blocked `accept` observe it. The drain in `listen_and_serve` waits
// for in-flight tasks with no deadline; bounding it is the
// graceful-shutdown item.
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
// stopped, after in-flight connections have finished.
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

// Same, with timeouts (and whatever else Limits/#2 on the todo list
// adds to ServerConfig later) under the caller's control -- built from
// config with server_config_from, or by hand for a test that wants a
// deliberately short one.
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

// The main task's own acceptor: binds here (so a bad port returns
// err instead of silently serving nothing) and loops here.
fn accept_first[S](r: Router[S], port: int,
                   sc: ServerConfig) -> result[int, str] {
    let first = listen_reuse(port);
    guard let ln0 = first else let e = err_of(first) {
        return err("cannot listen on port " + to_str(port) + ": " + to_str(e));
    }
    accept_loop(r, ln0, sc);
    while proc.active_tasks() > 0 {
        time.sleep(20000000);
    }
    return ok(0);
}
