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
pub fn serve_conn[S](r: Router[S], c: link) {
    let ra = arena_new(request_bytes());
    let sa = arena_new(response_bytes());
    let buf = ra.wire(request_bytes());
    let filled = 0;
    while true {
        let rr = http.read(&mut c, buf, filled, until_never());
        guard let got = rr else {
            return;
        }
        // No request id yet, and not because one is unwanted: slang's
        // crypto.rand is unsafe from a task that also parks on socket
        // I/O -- a serve loop calling it dies under two concurrent
        // connections, in slang's own httpd shape as much as this one
        // (slang PR #189 fixes the CPU-bound half; the parking half is
        // still open). `serve_id` takes "" for exactly this case, and
        // wiring ids in is its own todo item anyway.
        let resp = r.serve_id(got.req, "");
        let wr = http.write(&mut c, resp, &mut sa, until_never());
        guard let _n = wr else {
            return;
        }
        sa.reset();
        if http.wants_close(got.req) {
            return;
        }
        filled = got.filled;
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

// Bind, then accept until the process is asked to stop.
//
// There is no host parameter because slang's `link_listen` has none: it
// binds every interface. Returns `err` when the port cannot be bound --
// the common one is "already in use" -- and `ok` once the loop has
// stopped, after in-flight connections have finished.
//
// Stopping is SIGTERM/SIGINT, which `proc.shutdown_requested()` reports:
// slang blocks both in every spawned thread's signal mask, so only the
// main thread can run the handler, which is what lets this loop's own
// blocked `accept` observe it. The drain below waits for in-flight
// tasks with no deadline; bounding it is the graceful-shutdown item.
pub fn listen_and_serve[S](r: Router[S], port: int) -> result[int, str] {
    let lr = link_listen(port);
    guard let ln = lr else let e = err_of(lr) {
        return err("cannot listen on port " + to_str(port) + ": " + to_str(e));
    }
    while !proc.shutdown_requested() {
        accept_one(r, &mut ln);
    }
    while proc.active_tasks() > 0 {
        time.sleep(20000000);
    }
    return ok(0);
}
