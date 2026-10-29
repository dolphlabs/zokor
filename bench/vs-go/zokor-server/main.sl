// zokor's side of the "benchmarks against Go" todo item: the same three
// endpoints, over the wire, measured the same way as the Go net/http and
// Go Fiber servers next to this one.
//
// This used to carry a hand-rolled accept loop, because zokor had none.
// It now calls `zokor.listen_and_serve`, so what is measured is the
// framework's own server edge rather than a benchmark's stand-in for it.

import "http";
import "json";
import "proc";
import "../../../zokor" as zokor;

gc struct Bench {
    started: int,
}

// 1. hello-world: no parsing, no encoding, the floor for request/response
// overhead alone. Static bytes: the body is fixed, so no Request, no
// maps, no Ctx, no handler call per request -- the snapshot serves
// straight from registration. The handler is still stored (tests and
// fixtures keep working); it just never runs on the static path.
fn hello(c: zokor.Ctx[Bench]) -> http.Response {
    return zokor.text_bytes(200, b"Hello, World!");
}

// 2. a parameterised route: path-segment matching plus building a small
// JSON body. `user_json` renders straight to bytes -- no str, no
// `to_bytes`, no copy between the renderer and the socket. (The id
// still crosses str once inside the handler via c.param; the
// bytes-native router path is the follow-up, not this diff.)
fn get_user(c: zokor.Ctx[Bench]) -> http.Response {
    return zokor.ok_json_bytes(zokor.user_json(c.param("id")));
}

// 3. JSON echo: decode a small body into a declared shape, re-encode it.
// The same DTO path a real service uses, not a hand-rolled parse.
gc struct EchoBody {
    message: str,
}

fn echo(c: zokor.Ctx[Bench]) -> http.Response {
    let r: result[EchoBody, http.Response] = zokor.dto(c);
    guard let dto = r else let resp = err_of(r) {
        return resp;
    }
    return zokor.ok_json_bytes(zokor.message_json(dto.message));
}

let rt = zokor.new_router(Bench { started: 1 });
rt.static_bytes("/", 200, "text/plain; charset=utf-8", b"Hello, World!",
                hello);
rt.get("/users/:id", get_user);
rt.post("/echo", echo);

let port_str = proc.getenv("PORT") ?? "8081";
let pr = to_int(port_str);
guard let port = pr else {
    println("bad PORT: " + port_str);
    exit(1);
}
println("zokor bench listening on :" + to_str(port));
// The Go servers it is compared with log nothing (Fiber's logger is
// opt-in middleware), so zokor's request log is off here too: this
// measures the framework, not log I/O. The log's own cost is measured
// on its own (README, "Logging").
let sc = zokor.default_server_config();
sc.logger = zokor.no_logger();
// BENCH_MINIMAL=1 also drops the request id and the security headers,
// which zokor sends by default and the other servers do not: its
// responses are then byte-identical to bench/vs-slang/plain's, so the
// difference is the framework's path alone. bench/vs-go/run.sh measures
// it as `zokor-min`, beside the defaults as `zokor`.
if (proc.getenv("BENCH_MINIMAL") ?? "") == "1" {
    sc.request_ids = false;
    rt.security_headers(zokor.no_security_headers());
}
let sr = zokor.listen_and_serve_with(rt, port, sc);
guard let _n = sr else let e = err_of(sr) {
    println(e);
    exit(1);
}
