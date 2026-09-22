// zokor's side of the "benchmarks against Go" todo item: the same three
// endpoints, over the wire, measured the same way as the Go net/http and
// Go Fiber servers next to this one.
//
// zokor has no `listen_and_serve` yet -- it is still on the todo list,
// blocked on nothing now that generic functions have landed, but not
// written. Everything below the "the service" section is a minimal
// accept loop built from slang's `net` and `http` packages so this
// benchmark can run a REAL server over a REAL socket: `net.listen` /
// `net.accept`, buffering until a full request is framed (by
// Content-Length; these three endpoints never send chunked bodies),
// `http.parse` / `http.serialize` for the wire format, and one task per
// connection with keep-alive, so the comparison is fair against Go's
// (also keep-alive) default. None of this is zokor's API -- when
// `listen_and_serve` lands, this file shrinks to the service section
// plus one call.

import "net";
import "http";
import "json";
import "strings";
import "proc";
import "../../../src" as zokor;

// ---------------------------------------------------------------- //
// the service                                                        //
// ---------------------------------------------------------------- //

gc struct Bench {
    started: int,
}

// 1. hello-world: no parsing, no encoding, the floor for request/response
// overhead alone.
fn hello(c: zokor.Ctx[Bench]) -> http.Response {
    return zokor.text(200, "Hello, World!");
}

// 2. a parameterised route: path-segment matching plus building a small
// JSON body.
fn get_user(c: zokor.Ctx[Bench]) -> http.Response {
    let id = c.param("id");
    return zokor.ok_json(zokor.jobj()
        .set_str("id", id)
        .set_str("name", "user " + id)
        .render());
}

// 3. JSON echo: decode a small body into a declared shape, re-encode it.
// The same DTO path a real service uses, not a hand-rolled parse.
gc struct EchoBody {
    message: str,
}

fn echo(c: zokor.Ctx[Bench]) -> http.Response {
    let r: result[EchoBody, str] = json.decode(c.body_str());
    guard let dto = r else let e = err_of(r) {
        return zokor.text(400, "bad json: " + e);
    }
    return zokor.ok_json(zokor.jobj().set_str("message", dto.message).render());
}

let bench = Bench { started: 1 };
let rt = zokor.Router[Bench] {
    routes: [],
    befores: [],
    afters: [],
    state: bench,
    errors: zokor.new_registry(),
    auto_options: true,
    auto_head: true
};
rt.get("/", hello);
rt.get("/users/:id", get_user);
rt.post("/echo", echo);

// ---------------------------------------------------------------- //
// bench-only accept loop -- not part of zokor's API, see the header //
// ---------------------------------------------------------------- //

fn find_head_end(b: bytes) -> int {
    let i = 0;
    while i + 3 < len(b) {
        if b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn content_length_of(head: str) -> int {
    let lower = strings.to_lower(head);
    let at = strings.find(lower, "\r\ncontent-length:");
    if at < 0 {
        return 0;
    }
    let after = strings.slice(head, at + 18, len(head));
    let eol = strings.find(after, "\r");
    if eol < 0 {
        eol = len(after);
    }
    let r = to_int(strings.trim(strings.slice(after, 0, eol)));
    guard let n = r else {
        return 0;
    }
    return n;
}

// One framed request, plus whatever came after it in the same read: a
// pipelined keep-alive client (ab included, under load) can have its
// NEXT request's bytes already sitting in the kernel buffer by the time
// `net.recv` returns this one's tail, and a `net.recv` per request would
// silently drop them.
gc struct Framed {
    req: bytes,
    rest: bytes,
}

// Reads one HTTP/1.1 request out of `start` (bytes already in hand, left
// over from framing the previous request on this connection -- `b""` for
// the first) plus however much more `fd` gives up: headers, then a body
// of Content-Length bytes (0 when absent). `none` on a closed or reset
// connection.
fn frame_one(start: bytes, fd: i32) -> opt[Framed] {
    let buf = start;
    let head_end = find_head_end(buf);
    while head_end < 0 {
        let rr = net.recv(fd, 65536);
        guard let got = rr else { return none; }
        if len(got) == 0 {
            return none;
        }
        buf = buf + got;
        head_end = find_head_end(buf);
    }
    let head = to_str(buf[0..head_end]);
    let need = head_end + 4 + content_length_of(head);
    while len(buf) < need {
        let rr = net.recv(fd, 65536);
        guard let got = rr else { return none; }
        if len(got) == 0 {
            return none;
        }
        buf = buf + got;
    }
    return some(Framed { req: buf[0..need], rest: buf[need..len(buf)] });
}

fn conn_loop(fd: i32, rt: zokor.Router[Bench]) {
    let pending = b"";
    while true {
        let fr = frame_one(pending, fd);
        guard let f = fr else {
            net.close(fd);
            return;
        }
        pending = f.rest;
        let pr = http.parse(f.req);
        guard let req = pr else {
            net.send(fd, b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
            net.close(fd);
            return;
        }
        let resp = rt.serve(req);
        net.send(fd, http.serialize(resp));
        if http.wants_close(req) {
            net.close(fd);
            return;
        }
    }
}

fn accept_loop(lfd: i32, rt: zokor.Router[Bench]) {
    while true {
        let ar = net.accept(lfd);
        guard let fd = ar else { return; }
        spawn conn_loop(fd, rt);
    }
}

let port_str = proc.getenv("PORT") ?? "8081";
let pr = to_int(port_str);
guard let port = pr else {
    println("bad PORT: " + port_str);
    exit(1);
}
let lr = net.listen(port);
guard let lfd = lr else {
    println("listen failed on port " + to_str(port));
    exit(1);
}
println("zokor bench listening on :" + to_str(port));
accept_loop(lfd, rt);
