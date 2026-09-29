// Allocations per operation on zokor's request path, one operation per
// run: `OP=<name>` picks it, the loop runs it N times, and the runtime's
// own counter (SLANG_GC_STAT=1, printed at exit) divided by N is the
// cost. bench/allocs/run.sh drives every op and prints the table.
//
// Why a count and not a time: on this path the price of an allocation is
// mostly paid later, by the collector and by every other task waiting
// out its stop-the-world pause, so allocations per request is the number
// that moves throughput under load (see docs/benchmarks.md).
import "builder";
import "json";
import "proc";
import "strings";
import "../../src" as zokor;
import "../../src/internal/path" as path;

gc struct User {
    id: str,
    name: str,
}

gc struct EchoBody {
    message: str,
}

let op = proc.getenv("OP") ?? "noop";
let n = 100000;
let body = "{\"message\":\"hello from the load generator, a realistically small JSON body\"}";
let camel = "{\"userId\":\"42\",\"displayName\":\"Ada\"}";
let sink = 0;
let i = 0;
while i < n {
    if op == "strip_query" {
        sink = sink + len(path.strip_query("/users/42"));
    } else if op == "id_via_bytes" {
        // what the :id fast path did before: copy the path to bytes first
        let pb = to_bytes("/users/42");
        sink = sink + len(to_str(pb[7..len(pb)]));
    } else if op == "id_via_slice" {
        sink = sink + len(strings.slice("/users/42", 7, 9));
    } else if op == "user_json" {
        sink = sink + len(zokor.user_json("42"));
    } else if op == "json_encode_user" {
        sink = sink + len(json.encode(User { id: "42", name: "user 42" }));
    } else if op == "message_json" {
        sink = sink + len(zokor.message_json("hello from the load generator"));
    } else if op == "builder_new" {
        let bb = builder.new_bytes();
        sink = sink + bb.size();
    } else if op == "snake_keys" {
        sink = sink + len(zokor.snake_keys(body));
    } else if op == "snake_keys_camel" {
        sink = sink + len(zokor.snake_keys(camel));
    } else if op == "json_decode_echo" {
        let r: result[EchoBody, str] = json.decode(body);
        guard let b = r else { exit(1); }
        sink = sink + len(b.message);
    }
    i = i + 1;
}
println(to_str(sink));
