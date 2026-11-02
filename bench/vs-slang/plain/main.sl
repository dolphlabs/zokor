// The ruler zokor is measured against: the same three routes as
// bench/vs-go/zokor-server, written the way slang's own API benchmark
// server is (bench/suite/api/slang in the slang repo) -- stdlib `http`
// read/write over arenas, routing by hand, no framework. The responses
// are byte-identical to zokor's, so any difference is the framework's.

import "http";
import "json";
import "proc";
import "strings";

gc struct UserOut {
    id: str,
    name: str,
}

gc struct EchoBody {
    message: str,
}

gc struct MessageOut {
    message: str,
}

fn json_ok(body: str) -> http.Response {
    return http.text_response_bytes(200, "OK",
                                    "application/json; charset=utf-8",
                                    to_bytes(body));
}

fn route(req: http.Request) -> http.Response {
    if req.method == "GET" && req.path == "/" {
        return http.text_response_bytes(200, "OK",
                                        "text/plain; charset=utf-8",
                                        b"Hello, World!");
    }
    if req.method == "GET" && strings.has_prefix(req.path, "/users/") {
        let id = strings.slice(req.path, 7, len(req.path));
        if len(id) > 0 && strings.find(id, "/") < 0 {
            return json_ok(json.encode(UserOut { id: id, name: "user " + id }));
        }
    }
    if req.method == "POST" && req.path == "/echo" {
        let r: result[EchoBody, str] = json.decode(to_str(req.body));
        guard let body = r else {
            return http.bad_request("invalid body");
        }
        return json_ok(json.encode(MessageOut { message: body.message }));
    }
    return http.not_found();
}

fn serve(c: link) {
    let ra = arena_new(16384);
    let sa = arena_new(16384);
    let buf = ra.wire(16384);
    let filled = 0;
    while true {
        let rr = http.read(&mut c, buf, filled, until_never());
        guard let got = rr else { return; }
        let wr = http.write(&mut c, route(got.req), &mut sa, until_never());
        guard let _n = wr else { return; }
        sa.reset();
        if http.wants_close(got.req) {
            return;
        }
        filled = got.filled;
    }
}

let port = to_int(proc.getenv("PORT") ?? "8080") ?? 8080;
let lr = link_listen(port, 1);
guard let ln = lr else {
    println("listen failed on " + to_str(port));
    exit(1);
}
println("plain slang listening on :" + to_str(port));
// Stops on SIGTERM/SIGINT like zokor's accept loop, so both exit through
// the same path (and SLANG_GC_STAT prints at exit for either).
while !proc.shutdown_requested() {
    let ar = ln.accept(until_never());
    guard let c = ar else { continue; }
    spawn serve(c);
}
