import "http";
import "redis";
import "strings";
import "time";

gc struct IdState {
    calls: int,
    lock: mutex,
    fail_with: int,
    gate: chan[int],
    big: bool,
}

fn id_state() -> IdState {
    let g: chan[int] = make_chan(4);
    return IdState { calls: 0, lock: make_mutex(), fail_with: 0, gate: g, big: false };
}

fn id_count(c: Ctx[IdState]) -> int {
    mutex_lock(c.state.lock);
    c.state.calls = c.state.calls + 1;
    let n = c.state.calls;
    mutex_unlock(c.state.lock);
    return n;
}

fn id_create(c: Ctx[IdState]) -> http.Response {
    let n = id_count(c);
    if c.state.fail_with > 0 {
        return respond(c.errors, "unavailable", c.request_id);
    }
    if c.state.big {
        return created(strings.repeat("x", 2000), "/orders/" + to_str(n));
    }
    return created("{\"order\":" + to_str(n) + "}", "/orders/" + to_str(n));
}

fn id_slow(c: Ctx[IdState]) -> http.Response {
    id_count(c);
    let _g = chan_recv(c.state.gate);
    return created("{\"slow\":true}", "/slow");
}

fn id_user(c: Ctx[IdState]) -> opt[http.Response] {
    c.set_local("user", c.header("x-user"));
    return none;
}

fn id_router(store: Idempotency) -> Router[IdState] {
    let r = new_router(id_state());
    r.before(id_user);
    r.post("/orders", id_create);
    r.get("/orders", id_create);
    r.post("/slow", id_slow);
    store.scope_local = "user";
    r.idempotency(store);
    return r;
}

fn id_post(r: Router[IdState], p: str, key: str, user: str, body: str) -> http.Response {
    let rq = request(Method.POST, p).body_str(body);
    if len(key) > 0 {
        rq = rq.header("Idempotency-Key", key);
    }
    if len(user) > 0 {
        rq = rq.header("X-User", user);
    }
    return r.serve(rq.build());
}

fn test_a_retried_post_gets_the_first_answer_and_runs_once() {
    let r = id_router(idempotency_in_memory());
    let first = id_post(r, "/orders", "k-1", "ada", "{\"sku\":7}");
    assert(resp_status(first) == 201);
    assert(resp_text(first) == "{\"order\":1}");
    assert(resp_header(first, "idempotent-replayed") == "");
    let again = id_post(r, "/orders", "k-1", "ada", "{\"sku\":7}");
    assert(resp_status(again) == 201);
    assert(resp_text(again) == "{\"order\":1}");
    assert(resp_header(again, "location") == "/orders/1");
    assert(resp_header(again, "idempotent-replayed") == "true");
    // a fresh request id, not the first one's
    assert(resp_header(again, "x-request-id") != resp_header(first, "x-request-id") ||
           len(resp_header(first, "x-request-id")) == 0);
    assert(r.state.calls == 1);
    // no key: runs every time
    id_post(r, "/orders", "", "ada", "{}");
    assert(r.state.calls == 2);
}

fn test_a_key_reused_for_another_request_is_refused() {
    let r = id_router(idempotency_in_memory());
    id_post(r, "/orders", "k-2", "ada", "{\"sku\":7}");
    let other = id_post(r, "/orders", "k-2", "ada", "{\"sku\":8}");
    assert(resp_status(other) == 422);
    assert(strings.contains(resp_text(other), "used for a different request"), resp_text(other));
    assert(r.state.calls == 1);
}

fn test_keys_are_scoped_to_the_caller() {
    let r = id_router(idempotency_in_memory());
    id_post(r, "/orders", "same", "ada", "{}");
    let bob = id_post(r, "/orders", "same", "bob", "{}");
    assert(resp_text(bob) == "{\"order\":2}", resp_text(bob));
    assert(resp_header(bob, "idempotent-replayed") == "");
}

fn test_answers_that_are_not_final_are_not_kept() {
    let r = id_router(idempotency_in_memory());
    r.state.fail_with = 503;
    let down = id_post(r, "/orders", "k-3", "ada", "{}");
    assert(resp_status(down) == 503);
    r.state.fail_with = 0;
    let retry = id_post(r, "/orders", "k-3", "ada", "{}");
    assert(resp_status(retry) == 201);
    assert(r.state.calls == 2);
}

fn test_a_big_answer_is_sent_but_not_kept() {
    let store = idempotency_in_memory();
    store.max_body = 1000;
    let r = id_router(store);
    r.state.big = true;
    id_post(r, "/orders", "k-4", "ada", "{}");
    id_post(r, "/orders", "k-4", "ada", "{}");
    assert(r.state.calls == 2);
}

fn id_serve_slow(r: Router[IdState]) -> int {
    return resp_status(id_post(r, "/slow", "k-5", "ada", "{}"));
}

fn test_a_retry_while_the_first_runs_is_a_conflict() {
    let r = id_router(idempotency_in_memory());
    let h = spawn id_serve_slow(r);
    let waited = 0;
    while r.state.calls == 0 && waited < 2000 {
        time.sleep(1000000);
        waited = waited + 1;
    }
    let second = id_post(r, "/slow", "k-5", "ada", "{}");
    assert(resp_status(second) == 409);
    assert(strings.contains(resp_text(second), "still being processed"), resp_text(second));
    chan_send(r.state.gate, 1);
    assert((join_wait(h) ?? 0) == 201);
    let third = id_post(r, "/slow", "k-5", "ada", "{}");
    assert(resp_header(third, "idempotent-replayed") == "true");
    assert(r.state.calls == 1);
}

fn test_bad_or_missing_keys_are_400() {
    let store = idempotency_in_memory();
    store.required = true;
    let r = id_router(store);
    let missing = id_post(r, "/orders", "", "ada", "{}");
    assert(resp_status(missing) == 400);
    assert(strings.contains(resp_text(missing), "needs an Idempotency-Key"), resp_text(missing));
    let spaced = id_post(r, "/orders", "has space", "ada", "{}");
    assert(resp_status(spaced) == 400);
    assert(r.state.calls == 0);
    // reads are never held to it
    let read = r.serve(get_request("/orders").header("Idempotency-Key", "k").build());
    assert(resp_status(read) == 201);
    assert(r.state.calls == 1);
}

fn test_live_redis_store_replays_across_routers() {
    let c = cfg_of("REDIS_URL=redis://127.0.0.1:6379/15\n");
    let pr = redis_from_config(c);
    guard let pool = pr else {
        println("skip live_redis_store (bad REDIS_URL)");
        return;
    }
    let dl = until_of(time.mono() + 1000000000);
    let cr = redis.acquire(pool, dl);
    guard let conn = cr else {
        println("skip live_redis_store (no Redis reachable on 127.0.0.1:6379)");
        return;
    }
    redis.release(pool, conn);
    // two routers, as two instances behind a balancer, one store
    // a short ttl: this may run against a developer's own Redis (db 15),
    // and leaves nothing behind for long
    let sa = idempotency_redis(pool);
    sa.ttl = 5000000000;
    let sb = idempotency_redis(pool);
    sb.ttl = 5000000000;
    let a = id_router(sa);
    let b = id_router(sb);
    let key = "live-" + to_str(time.mono() as int);
    let first = id_post(a, "/orders", key, "ada", "{\"sku\":1}");
    assert(resp_status(first) == 201, resp_text(first));
    let again = id_post(b, "/orders", key, "ada", "{\"sku\":1}");
    assert(resp_text(again) == resp_text(first), resp_text(again));
    assert(resp_header(again, "idempotent-replayed") == "true");
    assert(b.state.calls == 0);
    let other = id_post(b, "/orders", key, "ada", "{\"sku\":2}");
    assert(resp_status(other) == 422);
}

