// What scales badly on a request path, measured.
//
// Each case runs at doubling input sizes and prints the time and the
// growth from the previous size. A linear algorithm roughly doubles;
// a quadratic one roughly quadruples, and the last column says which.
//
//     slangc bench/audit/main.sl --run
//
// Sizes are chosen so a linear case finishes in milliseconds and a
// quadratic one is unmistakable long before it becomes a hang.
import "builder";
import "time";
import "../../src" as zokor;
import "../../src/internal/multipart" as multipart;
import "../../src/internal/path" as path;
import "../../src/internal/ws" as ws;
import "http";

fn ms(t0: duration) -> int {
    return ((time.mono() - t0) / 1000) as int;
}

// microseconds, so a fast case is not printed as 0
fn report(label: str, sizes: [int], times: [int]) {
    let line = "  " + label;
    while len(line) < 34 {
        line = line + " ";
    }
    let i = 0;
    while i < len(sizes) {
        let t = times[i];
        let cell = to_str(t) + "us";
        if i > 0 && times[i - 1] > 200 {
            let g = (t * 10) / times[i - 1];
            cell = cell + " (x" + to_str(g / 10) + "." + to_str(g % 10) + ")";
        }
        line = line + cell + "  ";
        i = i + 1;
    }
    println(line);
}

fn repeat(s: str, n: int) -> str {
    let b = builder.new_str();
    let i = 0;
    while i < n {
        b.write(s);
        i = i + 1;
    }
    return b.finish();
}

// ---------------------------------------------------------------- //
// inputs                                                             //
// ---------------------------------------------------------------- //

fn json_long_string(n: int) -> str {
    return "{\"s\":\"" + repeat("a", n) + "\"}";
}

fn json_escaped_string(n: int) -> str {
    return "{\"s\":\"" + repeat("a\\n", n / 3) + "\"}";
}

fn json_int_array(n: int) -> str {
    let b = builder.new_str();
    b.write("[");
    let i = 0;
    while i < n / 4 {
        if i > 0 {
            b.write(",");
        }
        b.write_int(i % 1000);
        i = i + 1;
    }
    b.write("]");
    return b.finish();
}

fn json_many_keys(n: int) -> str {
    let b = builder.new_str();
    b.write("{");
    let i = 0;
    while i < n / 16 {
        if i > 0 {
            b.write(",");
        }
        b.write("\"key").write_int(i).write("\":1");
        i = i + 1;
    }
    b.write("}");
    return b.finish();
}

fn multipart_one_file(n: int) -> bytes {
    let b = builder.new_bytes();
    b.write_str("--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n");
    b.write_str(repeat("x", n));
    b.write_str("\r\n--B--\r\n");
    return b.finish();
}

fn multipart_many_fields(n: int) -> bytes {
    let b = builder.new_bytes();
    let i = 0;
    while i < n / 64 {
        b.write_str("--B\r\nContent-Disposition: form-data; name=\"f").write_str(to_str(i));
        b.write_str("\"\r\n\r\nvalue\r\n");
        i = i + 1;
    }
    b.write_str("--B--\r\n");
    return b.finish();
}

// a client frame, masked, as RFC 6455 requires
fn client_frame(op: int, payload: bytes, fin: bool) -> bytes {
    let n = len(payload);
    let b = builder.new_bytes();
    let b0 = op;
    if fin {
        b0 = b0 | 128;
    }
    b.write_byte(b0);
    if n < 126 {
        b.write_byte(128 | n);
    } else if n < 65536 {
        b.write_byte(128 | 126);
        b.write_byte((n >> 8) & 255);
        b.write_byte(n & 255);
    } else {
        b.write_byte(128 | 127);
        let k = 7;
        while k >= 0 {
            b.write_byte((n >> (k * 8)) & 255);
            k = k - 1;
        }
    }
    let key = [1, 2, 3, 4];
    b.write_byte(1).write_byte(2).write_byte(3).write_byte(4);
    let i = 0;
    while i < n {
        b.write_byte(payload[i] ^ key[i % 4]);
        i = i + 1;
    }
    return b.finish();
}

// ---------------------------------------------------------------- //
// cases                                                              //
// ---------------------------------------------------------------- //

fn sizes() -> [int] {
    return [16384, 32768, 65536, 131072];
}

fn run_json(label: str, make: fn(int) -> str, render: bool) {
    let times: [int] = [];
    for n in sizes() {
        let doc = make(n);
        let t0 = time.mono();
        let r = zokor.parse(doc);
        guard let j = r else {
            push(times, -1);
            continue;
        }
        if render {
            let out = j.render();
            let _n = len(out);
        }
        push(times, ms(t0));
    }
    report(label, sizes(), times);
}

println("sizes: 16KB 32KB 64KB 128KB   (growth from the previous size in brackets)");
println("");
println("json.parse");
run_json("long string", json_long_string, false);
run_json("string with escapes", json_escaped_string, false);
run_json("array of ints", json_int_array, false);
run_json("object with many keys", json_many_keys, false);
println("json.parse + render");
run_json("long string", json_long_string, true);
run_json("array of ints", json_int_array, true);
run_json("object with many keys", json_many_keys, true);

fn run_keys() {
    let times: [int] = [];
    for n in sizes() {
        let doc = json_many_keys(n);
        let t0 = time.mono();
        let out = zokor.snake_keys(doc);
        let _n = len(out);
        push(times, ms(t0));
    }
    report("snake_keys (parse+rekey+render)", sizes(), times);
}
println("key rewriting");
run_keys();

fn run_quote() {
    let times: [int] = [];
    for n in sizes() {
        let s = repeat("a", n);
        let t0 = time.mono();
        let q = zokor.quote(s);
        let _n = len(q);
        push(times, ms(t0));
    }
    report("errors.quote (a long detail)", sizes(), times);
}
println("error envelope");
run_quote();

fn run_multipart(label: str, make: fn(int) -> bytes) {
    let times: [int] = [];
    for n in sizes() {
        let body = make(n);
        let t0 = time.mono();
        let r = multipart.parse(body, "B", multipart.Limits {
            max_parts: 100000, max_files: 100000,
            max_file_bytes: 100000000, max_field_bytes: 100000000,
            max_total_bytes: 100000000, max_headers_bytes: 8192,
            max_filename_bytes: 255
        });
        guard let _p = r else {
            push(times, -1);
            continue;
        }
        push(times, ms(t0));
    }
    report(label, sizes(), times);
}
println("multipart");
run_multipart("one big file", multipart_one_file);
run_multipart("many small fields", multipart_many_fields);

fn run_path() {
    let times: [int] = [];
    for n in sizes() {
        let s = repeat("ab%20", n / 5);
        let t0 = time.mono();
        let d = path.percent_decode(s);
        let _n = len(d);
        push(times, ms(t0));
    }
    report("percent_decode (all escapes)", sizes(), times);
    let times2: [int] = [];
    for n in sizes() {
        let qs = repeat("k=v&", n / 4);
        let t0 = time.mono();
        let v = path.query_get(qs, "missing");
        let _n = len(v);
        push(times2, ms(t0));
    }
    report("query_get (name not present)", sizes(), times2);
}
println("path");
run_path();

// a message arriving in 4 KB reads, and one split into 1 KB fragments
fn run_ws_reads() {
    let times: [int] = [];
    for n in sizes() {
        let payload = to_bytes(repeat("m", n));
        let wire = client_frame(1, payload, true);
        let rules = zokor.default_ws();
        rules.max_frame_bytes = 100000000;
        rules.max_message_bytes = 100000000;
        let c = zokor.new_conn(rules);
        let t0 = time.mono();
        let at = 0;
        let total = len(wire);
        while at < total {
            let end = at + 4096;
            if end > total {
                end = total;
            }
            let r = zokor.receive(c, wire[at..end]);
            guard let _m = r else {
                break;
            }
            at = end;
        }
        push(times, ms(t0));
    }
    report("one message, arriving in 4KB reads", sizes(), times);
}

fn run_ws_fragments() {
    let times: [int] = [];
    for n in sizes() {
        let wb = builder.new_bytes();
        let piece = to_bytes(repeat("m", 1024));
        let count = n / 1024;
        let k = 0;
        while k < count {
            let op = 0;
            if k == 0 {
                op = 1;
            }
            wb.write(client_frame(op, piece, k == count - 1));
            k = k + 1;
        }
        let wire = wb.finish();
        let rules = zokor.default_ws();
        rules.max_frame_bytes = 100000000;
        rules.max_message_bytes = 100000000;
        let c = zokor.new_conn(rules);
        let t0 = time.mono();
        let r = zokor.receive(c, wire);
        guard let _m = r else {
            push(times, -1);
            continue;
        }
        push(times, ms(t0));
    }
    report("one message, 1KB fragments", sizes(), times);
}
println("websocket");
run_ws_reads();
run_ws_fragments();

// route count, not input size: how the router scales as routes are added
gc struct BS { n: int }
fn hit(c: zokor.Ctx[BS]) -> http.Response {
    return zokor.text(200, "x");
}

fn run_router() {
    let counts = [64, 128, 256, 512];
    let times: [int] = [];
    for n in counts {
        let st = BS { n: 0 };
        let r = zokor.Router[BS] {
            routes: [], befores: [], afters: [], state: st,
            errors: zokor.new_registry(), auto_options: true, auto_head: true
        };
        let i = 0;
        while i < n {
            r.get("/route" + to_str(i) + "/:id", hit);
            i = i + 1;
        }
        // the LAST route registered is the worst case for a linear scan
        let req = zokor.get_request("/route" + to_str(n - 1) + "/7").build();
        let t0 = time.mono();
        let reps = 0;
        while reps < 200 {
            r.serve(req);
            reps = reps + 1;
        }
        push(times, ms(t0));
    }
    report("200 requests to the last route", counts, times);
}
println("router (columns are 64 128 256 512 ROUTES, not bytes)");
run_router();
