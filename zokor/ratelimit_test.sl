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

// Keys that land in the same shard as `first`: a shard sweeps on its own
// count of requests.
fn same_shard_keys(first: str, n: int) -> [str] {
    let want = key_hash(first) & (rate_shard_count() - 1);
    let out: [str] = [first];
    let i = 0;
    while len(out) < n {
        let k = "k" + to_str(i);
        if (key_hash(k) & (rate_shard_count() - 1)) == want {
            push(out, k);
        }
        i = i + 1;
    }
    return out;
}

fn test_quiet_clients_are_swept() {
    let l = new_rate_limiter(5, 1000);
    l.sweep_every = 4;
    let ks = same_shard_keys("a", 4);
    l.take_at(ks[0], 0);
    l.take_at(ks[1], 0);
    l.take_at(ks[2], 0);
    assert(l.tracked() == 3);
    // the shard's 4th call sweeps: the first three have nothing inside
    // the window
    l.take_at(ks[3], 5000);
    assert(l.tracked() == 1, "tracked " + to_str(l.tracked()));
}

fn test_keys_spread_across_shards() {
    let used: map[int]bool = {};
    let i = 0;
    while i < 256 {
        used[key_hash("10.0.0." + to_str(i)) & (rate_shard_count() - 1)] = true;
        i = i + 1;
    }
    assert(len(used) == rate_shard_count(), "neighbouring addresses must not share one shard");
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

fn test_allowed_requests_carry_ratelimit_headers() {
    let r = rl_router(3, 60000000000);
    let first = rl_get(r, "alice");
    assert(resp_status(first) == 200);
    assert(resp_header(first, "ratelimit-limit") == "3");
    assert(resp_header(first, "ratelimit-remaining") == "2");
    assert(resp_header(first, "ratelimit-reset") == "60", resp_header(first, "ratelimit-reset"));
    assert(resp_header(rl_get(r, "alice"), "ratelimit-remaining") == "1");
    assert(resp_header(rl_get(r, "alice"), "ratelimit-remaining") == "0");
    let refused = rl_get(r, "alice");
    assert(resp_status(refused) == 429);
    assert(resp_header(refused, "ratelimit-remaining") == "0");
    assert(resp_header(refused, "ratelimit-limit") == "3");
    assert(resp_header(refused, "retry-after") == resp_header(refused, "ratelimit-reset"));
}

fn test_check_at_reports_remaining_and_reset() {
    let l = new_rate_limiter(2, 1000);
    let a = l.check_at("k", 100);
    assert(a.wait == 0 && a.remaining == 1 && a.reset == 1000);
    let b = l.check_at("k", 400);
    assert(b.wait == 0 && b.remaining == 0 && b.reset == 700, to_str(b.reset));
    let c = l.check_at("k", 500);
    assert(c.wait == 600 && c.remaining == 0);
}

fn rl_client_before(c: Ctx[RlApp]) -> opt[http.Response] {
    return rate_limit_client(c, c.state.limiter);
}

fn test_rate_limit_client_keys_on_the_resolved_address() {
    let r = new_router(RlApp { limiter: new_rate_limiter(1, 60000000000) });
    r.before(rl_client_before);
    r.get("/ping", rl_ping);
    let req = request(Method.GET, "/ping").header("X-Client-Id", "spoofed").build();
    assert(resp_status(r.serve_id_for(req, "", "10.0.0.1")) == 200);
    assert(resp_status(r.serve_id_for(req, "", "10.0.0.1")) == 429,
           "the same address, whatever headers it sends");
    assert(resp_status(r.serve_id_for(req, "", "10.0.0.2")) == 200, "another address has its own limit");
}

fn rl_add_two(c: Ctx[RlApp]) -> opt[http.Response] {
    c.add_header("X-One", "1");
    c.add_header("x-two", "2");
    return none;
}

fn rl_add_and_stop(c: Ctx[RlApp]) -> opt[http.Response] {
    c.add_header("x-from-before", "yes");
    return some(respond(c.errors, "forbidden", c.request_id));
}

fn test_add_header_reaches_the_final_response() {
    let r = new_router(RlApp { limiter: new_rate_limiter(10, 1000) });
    r.before(rl_add_two);
    r.get("/ping", rl_ping);
    let resp = r.serve(get_request("/ping").build());
    assert(resp_header(resp, "x-one") == "1" && resp_header(resp, "x-two") == "2");
    let r2 = new_router(RlApp { limiter: new_rate_limiter(10, 1000) });
    r2.before(rl_add_and_stop);
    r2.get("/ping", rl_ping);
    let stopped = r2.serve(get_request("/ping").build());
    assert(resp_status(stopped) == 403);
    assert(resp_header(stopped, "x-from-before") == "yes", "a short-circuit carries it too");
    let plain = new_router(RlApp { limiter: new_rate_limiter(10, 1000) });
    plain.get("/ping", rl_ping);
    assert(resp_header(plain.serve(get_request("/ping").build()), "x-one") == "");
}
