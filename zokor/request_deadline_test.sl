import "context";
import "http";
import "net";
import "redis";
import "time";

gc struct RdState {
    held: [context.Context],
    saw_cx: bool,
    waited_ns: int,
    port: int,
}

fn rd_state() -> RdState {
    let held: [context.Context] = [];
    return RdState { held: held, saw_cx: false, waited_ns: 0, port: 0 };
}

fn rd_req(p: str) -> http.Request {
    let h: map[str]str = {};
    let rr = http.request("GET", p, "HTTP/1.1", h, to_bytes(""));
    guard let r = rr else {
        panic("rd_req: bad test request");
    }
    return r;
}

fn rd_remaining(c: Ctx[RdState]) -> http.Response {
    return text(200, to_str(c.remaining()));
}

fn rd_never(c: Ctx[RdState]) -> http.Response {
    if until_hit(c.deadline()) {
        return text(500, "a request with no timeout is past its deadline");
    }
    return text(200, "never");
}

// deadline_within(1ms) under a 10s request: the shorter one wins.
fn rd_within_short(c: Ctx[RdState]) -> http.Response {
    let dl = c.deadline_within(1000000);
    time.sleep(3000000);
    if !until_hit(dl) {
        return text(500, "1ms did not pass in 3ms");
    }
    return text(200, "short");
}

// deadline_within(10s) under a 1ms request: the request's wins.
fn rd_within_long(c: Ctx[RdState]) -> http.Response {
    let dl = c.deadline_within(10000000000);
    time.sleep(3000000);
    if !until_hit(dl) {
        return text(500, "the request's 1ms did not cap a 10s wait");
    }
    return text(200, "capped");
}

fn rd_keep_context(c: Ctx[RdState]) -> http.Response {
    let k = c.context();
    // The same context on every call within one request.
    let again = c.context();
    context.cancel(again, "probe");
    if (context.cause(k) ?? "") != "probe" {
        return text(500, "context() made a second context");
    }
    return text(200, "kept");
}

fn rd_hold_context(c: Ctx[RdState]) -> http.Response {
    let k = c.context();
    push(c.state.held, k);
    if context.is_done(k) {
        return text(500, "the request's context was done while it ran");
    }
    return text(200, to_str(context.remaining(k)));
}

fn rd_plain(c: Ctx[RdState]) -> http.Response {
    return text(200, "plain");
}

fn rd_after(c: Ctx[RdState], resp: http.Response) -> http.Response {
    if let _k = c.cx {
        c.state.saw_cx = true;
    }
    return resp;
}

// Two waits on a peer that never answers, each given c.deadline(): they
// share the request's budget instead of getting one each.
fn rd_two_waits(c: Ctx[RdState]) -> http.Response {
    let dr = net.dial_until("127.0.0.1", c.state.port, c.deadline());
    guard let fd = dr else let e = err_of(dr) {
        return text(500, "dial: " + e);
    }
    let start = time.mono() as int;
    let first = net.recv_until(fd as int, 16, c.deadline());
    let second = net.recv_until(fd as int, 16, c.deadline());
    c.state.waited_ns = (time.mono() as int) - start;
    net.close(fd as int);
    if let _b = first {
        return text(500, "the silent peer sent something");
    }
    if let _b2 = second {
        return text(500, "the silent peer sent something");
    }
    return text(504, "timed out");
}

fn test_request_deadline_is_off_by_default() {
    let r = new_router(rd_state());
    r.get("/left", rd_remaining);
    r.get("/never", rd_never);
    assert(r.serve(rd_req("/left")).body == to_bytes("-1"));
    let nv = r.serve(rd_req("/never"));
    assert(nv.status == 200);
}

fn test_request_timeout_sets_each_requests_deadline() {
    let r = new_router(rd_state());
    assert(r.request_timeout(5000000000) == 0);
    r.get("/left", rd_remaining);
    let left = to_int(to_str(r.serve(rd_req("/left")).body)) ?? -2;
    assert(left > 0);
    assert(left <= 5000000000);
}

fn test_request_timeout_refuses_a_negative_value() {
    let r = new_router(rd_state());
    assert(r.request_timeout(2000000000) == 0);
    assert(r.request_timeout(-1) == -1);
    r.get("/left", rd_remaining);
    // Unchanged by the refused call.
    let left = to_int(to_str(r.serve(rd_req("/left")).body)) ?? -2;
    assert(left > 0);
}

fn test_deadline_within_takes_the_earlier_of_the_two() {
    let r = new_router(rd_state());
    assert(r.request_timeout(10000000000) == 0);
    r.get("/short", rd_within_short);
    assert(r.serve(rd_req("/short")).status == 200);
    let r2 = new_router(rd_state());
    assert(r2.request_timeout(1000000) == 0);
    r2.get("/long", rd_within_long);
    assert(r2.serve(rd_req("/long")).status == 200);
}

fn test_deadline_within_without_a_request_timeout_is_just_ns() {
    let r = new_router(rd_state());
    r.get("/short", rd_within_short);
    assert(r.serve(rd_req("/short")).status == 200);
}

fn test_context_is_one_per_request() {
    let r = new_router(rd_state());
    r.get("/k", rd_keep_context);
    assert(r.serve(rd_req("/k")).status == 200);
}

fn test_context_carries_the_deadline_and_is_released_after() {
    let st = rd_state();
    let r = new_router(st);
    assert(r.request_timeout(5000000000) == 0);
    r.get("/hold", rd_hold_context);
    let resp = r.serve(rd_req("/hold"));
    assert(resp.status == 200);
    let left = to_int(to_str(resp.body)) ?? -2;
    assert(left > 0);
    assert(left <= 5000000000);
    assert(len(st.held) == 1);
    assert((context.cause(st.held[0]) ?? "") == "released");
}

fn test_context_without_a_timeout_has_no_deadline() {
    let st = rd_state();
    let r = new_router(st);
    r.get("/hold", rd_hold_context);
    assert(r.serve(rd_req("/hold")).body == to_bytes("-1"));
    assert((context.cause(st.held[0]) ?? "") == "released");
}

fn test_a_request_that_never_asks_makes_no_context() {
    let st = rd_state();
    let r = new_router(st);
    r.after(rd_after);
    r.get("/plain", rd_plain);
    r.get("/hold", rd_hold_context);
    assert(r.serve(rd_req("/plain")).status == 200);
    assert(!st.saw_cx);
    assert(r.serve(rd_req("/hold")).status == 200);
    assert(st.saw_cx);
}

fn test_waits_share_one_request_budget() {
    let lr = net.listen(0);
    guard let ln = lr else let e = err_of(lr) {
        panic("listen: " + e);
    }
    let pr = net.port(ln as int);
    guard let port = pr else let e = err_of(pr) {
        panic("port: " + e);
    }
    let st = rd_state();
    st.port = port as int;
    let r = new_router(st);
    assert(r.request_timeout(200000000) == 0);
    r.get("/wait", rd_two_waits);
    let resp = r.serve(rd_req("/wait"));
    net.close(ln as int);
    assert(resp.status == 504);
    // One 200ms budget, not 200ms for each wait. Generous above, for a
    // loaded CI machine; a second full wait would be 400ms.
    assert(st.waited_ns >= 150000000);
    assert(st.waited_ns < 380000000);
}

// A store that never answers: a listener nobody accepts on. A wait on it
// lasts exactly as long as the deadline it was given.
gc struct RdStores {
    sessions: Sessions,
    tokens: TokenStore,
    took_ns: int,
}

fn rd_silent_redis() -> redis.Pool {
    let lr = net.listen(0);
    guard let ln = lr else let e = err_of(lr) {
        panic("listen: " + e);
    }
    let pr = net.port(ln as int);
    guard let port = pr else let e = err_of(pr) {
        panic("port: " + e);
    }
    let rp = redis.new_pool("redis://127.0.0.1:" + to_str(port as int) + "/0", 2);
    guard let p = rp else let e = err_of(rp) {
        panic("pool: " + e);
    }
    return p;
}

fn rd_stores() -> RdStores {
    let p = rd_silent_redis();
    return RdStores { sessions: sessions_redis(p), tokens: token_store_redis(p, 0), took_ns: 0 };
}

fn rd_rq_cookie(p: str, cookie: str, bearer: str) -> http.Request {
    let h: map[str]str = {};
    if len(cookie) > 0 {
        h["cookie"] = cookie;
    }
    if len(bearer) > 0 {
        h["authorization"] = "Bearer " + bearer;
    }
    let rr = http.request("GET", p, "HTTP/1.1", h, to_bytes(""));
    guard let r = rr else {
        panic("rd_rq_cookie: bad test request");
    }
    return r;
}

fn rd_hex64() -> str {
    let out = "";
    let i = 0;
    while i < 64 {
        out = out + "a";
        i = i + 1;
    }
    return out;
}

fn rd_session(c: Ctx[RdStores]) -> http.Response {
    let start = time.mono() as int;
    let r = session_require(c, c.state.sessions);
    c.state.took_ns = (time.mono() as int) - start;
    guard let _s = r else let resp = err_of(r) {
        return resp;
    }
    return text(200, "in");
}

fn rd_bearer(c: Ctx[RdStores]) -> http.Response {
    let start = time.mono() as int;
    let who = bearer_subject(c, c.state.tokens);
    c.state.took_ns = (time.mono() as int) - start;
    if let _w = who {
        return text(200, "in");
    }
    return text(401, "out");
}

fn test_session_store_stops_at_the_request_deadline() {
    let st = rd_stores();
    let r = new_router(st);
    assert(r.request_timeout(100000000) == 0);
    r.get("/me", rd_session);
    let resp = r.serve(rd_rq_cookie("/me", "__Host-sid=" + rd_hex64(), ""));
    // The store is down, not the user logged out: 503, not 401.
    assert(resp.status == 503);
    // The request's 100ms, not the store's own 2s.
    assert(st.took_ns < 1000000000);
}

fn test_token_store_stops_at_the_request_deadline() {
    let st = rd_stores();
    let r = new_router(st);
    assert(r.request_timeout(100000000) == 0);
    r.get("/me", rd_bearer);
    let resp = r.serve(rd_rq_cookie("/me", "", "tok"));
    assert(resp.status == 401);
    assert(st.took_ns < 1000000000);
}
