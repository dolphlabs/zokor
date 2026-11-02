// What `r.etags()` costs per request, in process (r.serve, no socket):
// a GET of a SIZE-byte body through a router without it, with it, and
// with it answering a matching If-None-Match. MODE=plain|etag|hit,
// SIZE=bytes. Prints ns per request; SLANG_GC_STAT=1 adds allocations.
//
//     for m in plain etag hit; do MODE=$m SIZE=1024 ./conditional_bench; done
import "http";
import "proc";
import "strings";
import "time";
import "../../zokor" as zokor;

gc struct BState {
    body: str,
}

fn b_body(c: zokor.Ctx[BState]) -> http.Response {
    return zokor.ok_json(c.state.body);
}

let mode = proc.getenv("MODE") ?? "plain";
let size = to_int(proc.getenv("SIZE") ?? "1024") ?? 1024;
let n = to_int(proc.getenv("N") ?? "200000") ?? 200000;

let r = zokor.new_router(BState { body: strings.repeat("x", size) });
r.get("/body", b_body);
if mode != "plain" {
    r.etags();
}
let rq = zokor.get_request("/body");
if mode == "hit" {
    let first = r.serve(rq.build());
    rq = rq.header("If-None-Match", zokor.resp_header(first, "etag"));
}
let req = rq.build();
// warm up
let i = 0;
while i < n / 10 {
    let _w = r.serve(req);
    i = i + 1;
}
let sink = 0;
let t0 = time.mono();
i = 0;
while i < n {
    let resp = r.serve(req);
    sink = sink + (resp.status as int);
    i = i + 1;
}
let ns = (time.mono() - t0) as int;
println(mode + " size=" + to_str(size) + " " + to_str(ns / n) + " ns/req (status sum " +
        to_str(sink / n) + ")");
