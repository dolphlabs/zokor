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
// What is NOT here yet, each its own item on the todo list: timeouts
// (every deadline below is `until_never()`), limits (the request buffer
// is one fixed size, and a request larger than it fails the read rather
// than answering 413), graceful draining with a deadline, per-request
// panic recovery, and TLS.

import "http";
import "proc";
import "time";

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
pub fn serve_conn[S](r: Router[S], c: link) {
    let ra = arena_new(request_bytes());
    let sa = arena_new(response_bytes());
    let buf = ra.wire(request_bytes());
    let filled = 0;
    while true {
        let rr = http.read_frame(&mut c, buf, filled, until_never());
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
                                until_never());
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
                                   until_never());
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
fn accept_one[S](r: Router[S], ln: &mut link) {
    let ar = ln.accept(until_never());
    guard let c = ar else {
        return;
    }
    spawn serve_conn(r, c);
}

// One acceptor's loop: accept until the process is asked to stop.
// Stopping is SIGTERM/SIGINT, which `proc.shutdown_requested()`
// reports: slang blocks both in every spawned thread's signal mask,
// so only the main thread can run the handler, which is what lets a
// blocked `accept` observe it. The drain in `listen_and_serve` waits
// for in-flight tasks with no deadline; bounding it is the
// graceful-shutdown item.
fn accept_loop[S](r: Router[S], ln: link) {
    let mut_ln = ln;
    while !proc.shutdown_requested() {
        accept_one(r, &mut mut_ln);
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
// bottleneck is per-request work, not accepts. The dynamic
// `/users/:id` path is identical either way too (~27-28k, with
// timeouts at 8). So the default stays 1: extra acceptors are extra
// tasks contending on the same cores for no gain, and the knob
// remains for machines where accepts ARE the bottleneck.
// `ZOKOR_ACCEPTORS` overrides; default 1.
pub fn listen_and_serve[S](r: Router[S], port: int) -> result[int, str] {
    let n = acceptor_count();
    if n < 1 {
        n = 1;
    }
    let i = 1;
    while i < n {
        spawn acceptor_task(r, port);
        i = i + 1;
    }
    return accept_first(r, port);
}

// A spawned acceptor: its own SO_REUSEPORT listener, its own loop.
// Binding happens INSIDE the task (not before the spawn) because a
// link moved across a spawn boundary is a use-after-move: the
// spawner keeps the variable, the task gets the value, and the
// runtime kills the task. Each acceptor therefore owns its listener
// from bind to accept, and nothing crosses the boundary but the
// router (a gc struct, shared, never moved).
fn acceptor_task[S](r: Router[S], port: int) {
    let lr = link_listen(port, 1);
    guard let ln = lr else {
        return;
    }
    accept_loop(r, ln);
}

// The main task's own acceptor: binds here (so a bad port returns
// err instead of silently serving nothing) and loops here.
fn accept_first[S](r: Router[S], port: int) -> result[int, str] {
    let first = listen_reuse(port);
    guard let ln0 = first else let e = err_of(first) {
        return err("cannot listen on port " + to_str(port) + ": " + to_str(e));
    }
    accept_loop(r, ln0);
    while proc.active_tasks() > 0 {
        time.sleep(20000000);
    }
    return ok(0);
}
