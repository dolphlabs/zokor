import "http";
import "strings";

gc struct RxState {
    n: int,
}

fn rx_echo(c: Ctx[RxState]) -> http.Response {
    return text(200, c.route);
}

// A small deterministic generator (LCG), so a failure reproduces.
gc struct Lcg {
    s: int,
}

impl Lcg {
    fn next(self: Lcg, n: int) -> int {
        self.s = (self.s * 6364136223846793005 + 1442695040888963407);
        let v = (self.s >> 33) % n;
        if v < 0 {
            v = -v;
        }
        return v;
    }
}

fn rx_pattern(g: Lcg) -> str {
    let vocab = ["a", "b", "c", ":x", ":y"];
    let depth = g.next(4) + 1;
    let out: [str] = [];
    let k = 0;
    while k < depth {
        if k == depth - 1 && g.next(6) == 0 {
            push(out, "*rest");
        } else {
            push(out, vocab[g.next(len(vocab))]);
        }
        k = k + 1;
    }
    return "/" + strings.join(out, "/");
}

fn rx_path(g: Lcg) -> str {
    let vocab = ["a", "b", "c", "d", "7"];
    let depth = g.next(6);
    let out: [str] = [];
    let k = 0;
    while k < depth {
        push(out, vocab[g.next(len(vocab))]);
        k = k + 1;
    }
    return "/" + strings.join(out, "/");
}

// What a scan of the routes in registration order answers: the first
// matching route whose method fits (HEAD served by GET), else 405 when
// some route matches the path, else 404.
fn rx_expected(r: Router[RxState], p: str, m: Method) -> str {
    let segs = path.split(p);
    let seen = false;
    for rt in r.routes {
        if !r.match_only(rt, segs) {
            continue;
        }
        seen = true;
        if rt.method == m || (m == Method.HEAD && rt.method == Method.GET) {
            return "200 " + rt.pattern;
        }
    }
    if seen {
        return "405";
    }
    return "404";
}

fn rx_got(resp: http.Response) -> str {
    let s = resp_status(resp);
    if s == 200 {
        return "200 " + resp_text(resp);
    }
    return to_str(s);
}

fn test_the_index_answers_what_a_scan_answers() {
    let g = Lcg { s: 20261013 };
    let methods = [Method.GET, Method.POST, Method.PUT];
    let rounds = 0;
    let checked = 0;
    while rounds < 8 {
        let r = new_router(RxState { n: 0 });
        r.auto_options = false;
        let i = 0;
        while i < 60 {
            r.handle(methods[g.next(3)], rx_pattern(g), rx_echo);
            i = i + 1;
        }
        assert(len(r.rindex) == 1, "a 60-route router is indexed");
        let q = 0;
        while q < 400 {
            let p = rx_path(g);
            let m = [Method.GET, Method.POST, Method.PUT, Method.HEAD, Method.DELETE][g.next(5)];
            let want = rx_expected(r, p, m);
            let got = rx_got(r.serve(request(m, p).build()));
            // HEAD answers carry no body: compare the status alone
            if m == Method.HEAD && strings.has_prefix(want, "200") {
                want = "200";
                got = strings.slice(got, 0, 3);
            }
            assert(got == want, to_str(m) + " " + p + ": index says " + got + ", a scan says " + want);
            checked = checked + 1;
            q = q + 1;
        }
        rounds = rounds + 1;
    }
    assert(checked == 3200);
}

fn test_small_routers_are_not_indexed() {
    let r = new_router(RxState { n: 0 });
    let i = 0;
    while i < 16 {
        r.get("/r" + to_str(i), rx_echo);
        i = i + 1;
    }
    assert(len(r.rindex) == 0);
    r.get("/r16", rx_echo);
    assert(len(r.rindex) == 1);
    // routes added after the index exists are found too
    r.get("/late/:id", rx_echo);
    assert(resp_text(r.serve(get_request("/late/9").build())) == "/late/:id");
    assert(resp_text(r.serve(get_request("/r3").build())) == "/r3");
}

fn test_first_registered_wins_through_the_index() {
    let r = new_router(RxState { n: 0 });
    r.get("/files/*rest", rx_echo);
    r.get("/files/:name", rx_echo);
    r.get("/files/readme", rx_echo);
    let i = 0;
    while i < 20 {
        r.get("/pad" + to_str(i), rx_echo);
        i = i + 1;
    }
    assert(len(r.rindex) == 1);
    // the wildcard came first, so it answers even the exact path
    assert(resp_text(r.serve(get_request("/files/readme").build())) == "/files/*rest");
    assert(resp_text(r.serve(get_request("/files").build())) == "/files/*rest");
    // the frame path agrees with the general one
    assert(resp_text(r.serve_frame(frame_req("GET", "/files/readme"), "")) == "/files/*rest");
}
