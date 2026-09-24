// zokor's side of the "benchmarks against Go" todo item: the same three
// endpoints, over the wire, measured the same way as the Go net/http and
// Go Fiber servers next to this one.
//
// This used to carry a hand-rolled accept loop, because zokor had none.
// It now calls `zokor.listen_and_serve`, so what is measured is the
// framework's own server edge rather than a benchmark's stand-in for it.

import "builder";
import "http";
import "json";
import "proc";
import "../../../src" as zokor;

gc struct Bench {
    started: int,
}

// 1. hello-world: no parsing, no encoding, the floor for request/response
// overhead alone. The body is bytes so the str->bytes copy never happens.
fn hello(c: zokor.Ctx[Bench]) -> http.Response {
    return zokor.text_bytes(200, b"Hello, World!");
}

// 2. a parameterised route: path-segment matching plus building a small
// JSON body. `render_bytes` hands bytes straight to the socket -- no
// str, no `to_bytes`, no copy in between.
fn get_user(c: zokor.Ctx[Bench]) -> http.Response {
    let id = c.param("id");
    let bb = builder.new_bytes();
    bb.write_str("{\"id\":\"");
    bb.write(http.escape_json_bytes(to_bytes(id)));
    bb.write_str("\",\"name\":\"user ");
    bb.write(http.escape_json_bytes(to_bytes(id)));
    bb.write_str("\"}");
    return zokor.ok_json_bytes(bb.finish());
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
    let bb = builder.new_bytes();
    bb.write_str("{\"message\":\"");
    bb.write(http.escape_json_bytes(to_bytes(dto.message)));
    bb.write_str("\"}");
    return zokor.ok_json_bytes(bb.finish());
}

let rt = zokor.new_router(Bench { started: 1 });
rt.get("/", hello);
rt.get("/users/:id", get_user);
rt.post("/echo", echo);

let port_str = proc.getenv("PORT") ?? "8081";
let pr = to_int(port_str);
guard let port = pr else {
    println("bad PORT: " + port_str);
    exit(1);
}
println("zokor bench listening on :" + to_str(port));
let sr = zokor.listen_and_serve(rt, port);
guard let _n = sr else let e = err_of(sr) {
    println(e);
    exit(1);
}
