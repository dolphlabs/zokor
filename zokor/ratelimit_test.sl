import "http";

gc struct RlApp {
    limiter: RateLimiter,
}

fn rl_before(c: Ctx[RlApp]) -> opt[http.Response] {
    return rate_limit(c, c.state.limiter, c.header("x-client-id"));
}

fn rl_ping(c: Ctx[RlApp]) -> http.Response {
    return ok_json("{\"pong\":true}");
}

fn rl_router(limit: int, window_ns: int) -> Router[RlApp] {
    let r = new_router(RlApp { limiter: new_rate_limiter(limit, window_ns) });
    r.before(rl_before);
    r.get("/ping", rl_ping);
    return r;
}

fn rl_get(r: Router[RlApp], client: str) -> http.Response {
    let req = request(Method.GET, "/ping");
    if len(client) > 0 {
        req = req.header("X-Client-Id", client);
    }
    return r.serve(req.build());
}

fn test_limit_counts_within_the_window() {
    let l = new_rate_limiter(3, 1000000000);
    assert(l.take_at("a", 0) == 0);
    assert(l.take_at("a", 100) == 0);
    assert(l.take_at("a", 200) == 0);
    // the 4th inside the same second is refused until the 1st leaves
    let wait = l.take_at("a", 300);
    assert(wait == 1000000000 - 300, "wait " + to_str(wait));
}

fn test_the_window_slides_rather_than_resets() {
    let l = new_rate_limiter(2, 1000000000);
    assert(l.take_at("a", 0) == 0);
    assert(l.take_at("a", 600000000) == 0);
    // at 1.0s the first has left; the second (0.6s) still counts
    assert(l.take_at("a", 1000000001) == 0);
    assert(l.take_at("a", 1100000000) > 0);
    // a fixed window would have reset at 1.0s and allowed this one
    assert(l.take_at("a", 1500000000) > 0);
    assert(l.take_at("a", 1600000001) == 0);
}

fn test_refused_requests_are_not_counted() {
    let l = new_rate_limiter(1, 1000000000);
    assert(l.take_at("a", 0) == 0);
    assert(l.take_at("a", 500000000) > 0);
    assert(l.take_at("a", 900000000) > 0);
    // only the allowed request at 0 counts, so 1.0s+ is free again
    assert(l.take_at("a", 1000000001) == 0);
}

fn test_clients_are_independent() {
    let l = new_rate_limiter(1, 1000000000);
    assert(l.take_at("a", 0) == 0);
    assert(l.take_at("a", 1) > 0);
    assert(l.take_at("b", 2) == 0);
}

fn test_retry_after_rounds_up_and_is_at_least_one() {
    assert(retry_after_secs(1) == 1);
    assert(retry_after_secs(0) == 1);
    assert(retry_after_secs(1000000000) == 1);
    assert(retry_after_secs(1000000001) == 2);
    assert(retry_after_secs(2500000000) == 3);
}

fn test_quiet_clients_are_swept() {
    let l = new_rate_limiter(5, 1000);
    l.sweep_every = 4;
    l.take_at("a", 0);
    l.take_at("b", 0);
    l.take_at("c", 0);
    assert(l.tracked() == 3);
    // the 4th call sweeps: a, b, c have nothing inside the window
    l.take_at("d", 5000);
    assert(l.tracked() == 1, "tracked " + to_str(l.tracked()));
}

fn test_middleware_answers_429_in_the_envelope_with_retry_after() {
    let r = rl_router(2, 60000000000);
    assert(resp_status(rl_get(r, "alice")) == 200);
    assert(resp_status(rl_get(r, "alice")) == 200);
    let denied = rl_get(r, "alice");
    assert(resp_status(denied) == 429);
    assert(resp_error_code(denied) == "rate_limited");
    let ra = to_int(resp_header(denied, "retry-after")) ?? 0;
    assert(ra >= 59 && ra <= 60, "retry-after " + to_str(ra));
    // another client is untouched
    assert(resp_status(rl_get(r, "bob")) == 200);
}

fn test_middleware_counts_a_missing_key_as_anonymous() {
    let r = rl_router(1, 60000000000);
    assert(resp_status(rl_get(r, "")) == 200);
    assert(resp_status(rl_get(r, "")) == 429);
    assert(resp_status(rl_get(r, "anonymous")) == 429);
}

fn test_custom_renderer_applies_to_429() {
    let r = rl_router(1, 60000000000);
    set_renderer(r.errors, rl_render);
    rl_get(r, "x");
    let denied = rl_get(r, "x");
    assert(resp_text(denied) == "{\"error\":{\"code\":\"rate_limited\",\"message\":\"too many requests\"}}",
           resp_text(denied));
    assert(len(resp_header(denied, "retry-after")) > 0);
}

fn rl_render(v: ErrorView) -> http.Response {
    return json_response(v.status, "{\"error\":{\"code\":" + quote(v.code) +
                         ",\"message\":" + quote(v.message) + "}}");
}

fn rl_hammer(l: RateLimiter, n: int) -> int {
    let allowed = 0;
    for i in 0..n {
        if l.take_at("shared", 5) == 0 {
            allowed = allowed + 1;
        }
    }
    return allowed;
}

// Many tasks against one limiter: exactly `limit` get through. Without
// the lock the read-modify-write of a client's log loses updates.
fn test_concurrent_takes_never_exceed_the_limit() {
    let l = new_rate_limiter(50, 1000000000);
    let hs: [join[int]] = [];
    for t in 0..8 {
        push(hs, spawn rl_hammer(l, 100));
    }
    let total = 0;
    for h in hs {
        total = total + (join_wait(h) ?? 0);
    }
    assert(total == 50, "allowed " + to_str(total));
}
