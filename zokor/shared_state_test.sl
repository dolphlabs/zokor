import "http";
import "redis";
import "strings";
import "time";

fn sh_url() -> str {
    return "redis://127.0.0.1:6379/0";
}

// A live Redis, or none: redis_test's rule.
fn sh_pool(test: str) -> opt[redis.Pool] {
    let pr = redis.new_pool(sh_url(), 4);
    guard let p = pr else {
        println("skip " + test + " (no pool)");
        return none;
    }
    let ping = redis.pool_do(p, [to_bytes("PING")], until_of(time.mono() + 300000000));
    guard let _pong = ping else {
        println("skip " + test + " (no Redis on 127.0.0.1:6379)");
        return none;
    }
    return some(p);
}

fn sh_unique(what: str) -> str {
    return what + "-" + to_str(time.mono() as int);
}

fn sh_dead_pool() -> redis.Pool {
    let pr = redis.new_pool("redis://127.0.0.1:1/0", 1);
    guard let p = pr else let e = err_of(pr) {
        panic(e);
    }
    return p;
}

// ---- rate limiter --------------------------------------------------------

// The reason this exists: three instances, one limit.
fn test_shared_limit_is_one_limit_across_instances() {
    guard let p = sh_pool("test_shared_limit_is_one_limit_across_instances") else { return; }
    let name = sh_unique("rl");
    let a = rate_limiter_redis(p, name, 5, 10000000000);
    let b = rate_limiter_redis(p, name, 5, 10000000000);
    let c = rate_limiter_redis(p, name, 5, 10000000000);
    let allowed = 0;
    let i = 0;
    while i < 15 {
        let l = a;
        if i % 3 == 1 { l = b; }
        if i % 3 == 2 { l = c; }
        if l.take("ada") == 0 {
            allowed = allowed + 1;
        }
        i = i + 1;
    }
    assert(allowed == 5);
    assert(a.fallbacks == 0 && b.fallbacks == 0 && c.fallbacks == 0);
}

fn test_shared_limit_counts_clients_apart() {
    guard let p = sh_pool("test_shared_limit_counts_clients_apart") else { return; }
    let l = rate_limiter_redis(p, sh_unique("rl"), 1, 10000000000);
    assert(l.take("ada") == 0);
    assert(l.take("ada") > 0);
    assert(l.take("grace") == 0);
}

fn test_shared_limits_with_different_names_do_not_mix() {
    guard let p = sh_pool("test_shared_limits_with_different_names_do_not_mix") else { return; }
    let a = rate_limiter_redis(p, sh_unique("a"), 1, 10000000000);
    let b = rate_limiter_redis(p, sh_unique("b"), 1, 10000000000);
    assert(a.take("ada") == 0);
    assert(b.take("ada") == 0);
}

fn test_shared_limit_reports_what_the_headers_need() {
    guard let p = sh_pool("test_shared_limit_reports_what_the_headers_need") else { return; }
    let l = rate_limiter_redis(p, sh_unique("rl"), 2, 10000000000);
    let one = l.check("ada");
    assert(one.wait == 0 && one.remaining == 1);
    assert(one.reset > 9000000000 && one.reset <= 10000000000);
    let two = l.check("ada");
    assert(two.wait == 0 && two.remaining == 0);
    let three = l.check("ada");
    assert(three.remaining == 0);
    assert(three.wait > 9000000000 && three.wait <= 10000000000);
}

// A refused request is not counted, or a client hammering a limit would
// push its own recovery further away for ever.
fn test_shared_limit_recovers_once_the_window_passes() {
    guard let p = sh_pool("test_shared_limit_recovers_once_the_window_passes") else { return; }
    let l = rate_limiter_redis(p, sh_unique("rl"), 1, 60000000);
    assert(l.take("ada") == 0);
    assert(l.take("ada") > 0);
    time.sleep(40000000);
    assert(l.take("ada") > 0);
    time.sleep(40000000);
    assert(l.take("ada") == 0);
}

// Two entries of different ages: the newer keeps the key alive, so only
// trimming lets the older leave. With a limit of 1 the key's own expiry
// hides a window that is never trimmed, and a refusal that counts.
fn test_shared_limit_is_a_sliding_log_not_a_key_expiry() {
    guard let p = sh_pool("test_shared_limit_is_a_sliding_log_not_a_key_expiry") else { return; }
    let l = rate_limiter_redis(p, sh_unique("rl"), 2, 200000000);
    assert(l.take("ada") == 0);
    time.sleep(120000000);
    assert(l.take("ada") == 0);
    assert(l.take("ada") > 0);          // refused, and must not count
    time.sleep(110000000);
    let again = l.check("ada");         // the first has left the window
    assert(again.wait == 0);
    assert(again.remaining == 0);
    assert(l.fallbacks == 0);
}

fn test_shared_limit_key_expires_from_redis() {
    guard let p = sh_pool("test_shared_limit_key_expires_from_redis") else { return; }
    let name = sh_unique("rl");
    let l = rate_limiter_redis(p, name, 1, 20000000);
    assert(l.take("ada") == 0);
    time.sleep(60000000);
    let r = redis.pool_do(p, [to_bytes("EXISTS"), to_bytes("zokor:rate:" + name + ":ada")],
                          until_of(time.mono() + 1000000000));
    guard let e = r else { assert(false); return; }
    assert(e.num == 0);
}

// Neither no limit nor no service: this process's own count.
fn test_shared_limit_falls_back_to_a_local_count_when_redis_is_gone() {
    let l = rate_limiter_redis(sh_dead_pool(), "rl", 2, 10000000000);
    l.timeout = 50000000;
    assert(l.take("ada") == 0);
    assert(l.take("ada") == 0);
    assert(l.take("ada") > 0);
    assert(l.fallbacks == 3);
}

gc struct ShApp {
    limiter: RateLimiter,
}

fn sh_before(c: Ctx[ShApp]) -> opt[http.Response] {
    return rate_limit(c, c.state.limiter, "ada");
}

fn sh_ok(c: Ctx[ShApp]) -> http.Response {
    return ok_json("{}");
}

fn test_shared_limit_answers_429_through_the_router() {
    guard let p = sh_pool("test_shared_limit_answers_429_through_the_router") else { return; }
    let r = new_router(ShApp { limiter: rate_limiter_redis(p, sh_unique("rl"), 1, 10000000000) });
    r.before(sh_before);
    r.get("/x", sh_ok);
    assert(resp_status(r.serve(get_request("/x").build())) == 200);
    let refused = r.serve(get_request("/x").build());
    assert(resp_status(refused) == 429);
    assert(resp_error_code(refused) == "rate_limited");
    assert(resp_header(refused, "retry-after") == "10");
}

// ---- token store ---------------------------------------------------------

fn test_shared_tokens_are_known_to_every_instance() {
    guard let p = sh_pool("test_shared_tokens_are_known_to_every_instance") else { return; }
    let a = token_store_redis(p, 0);
    let b = token_store_redis(p, 0);
    let user = sh_unique("user");
    let tok = a.issue(user) ?? "";
    assert((b.lookup(tok) ?? "") == user);
    assert(b.revoke(tok));
    assert(!b.revoke(tok));
    let gone = a.lookup(tok);
    guard let _x = gone else { return; }
    assert(false);
}

fn test_shared_tokens_keep_only_a_hash_in_redis() {
    guard let p = sh_pool("test_shared_tokens_keep_only_a_hash_in_redis") else { return; }
    let s = token_store_redis(p, 0);
    let user = sh_unique("user");
    let tok = s.issue(user) ?? "";
    let dl = until_of(time.mono() + 1000000000);
    let raw = redis.pool_do(p, [to_bytes("EXISTS"), to_bytes("zokor:token:" + tok)], dl);
    guard let plain = raw else { assert(false); return; }
    assert(plain.num == 0);
    let m = redis.pool_do(p, [to_bytes("SMEMBERS"), token_index(user)], dl);
    guard let members = m else { assert(false); return; }
    assert(len(members.items) == 1);
    let held = to_str(members.items[0].bulk ?? b"");
    assert(!contains(held, tok));
    s.revoke_subject(user);
}

fn test_shared_tokens_expire_after_the_ttl() {
    guard let p = sh_pool("test_shared_tokens_expire_after_the_ttl") else { return; }
    let s = token_store_redis(p, 20000000);
    let tok = s.issue(sh_unique("user")) ?? "";
    assert(len(s.lookup(tok) ?? "") > 0);
    time.sleep(60000000);
    let gone = s.lookup(tok);
    guard let _x = gone else { return; }
    assert(false);
}

fn test_shared_tokens_revoke_every_token_of_a_subject() {
    guard let p = sh_pool("test_shared_tokens_revoke_every_token_of_a_subject") else { return; }
    let s = token_store_redis(p, 0);
    let user = sh_unique("user");
    let keep = sh_unique("other");
    let one = s.issue(user) ?? "";
    let two = s.issue(user) ?? "";
    let other = s.issue(keep) ?? "";
    assert(s.revoke_subject(user) == 2);
    assert(len(s.lookup(one) ?? "") == 0);
    assert(len(s.lookup(two) ?? "") == 0);
    assert((s.lookup(other) ?? "") == keep);
    assert(s.revoke_subject(keep) == 1);
}

// A store it cannot reach must not read as a pass.
fn test_shared_tokens_refuse_when_redis_is_gone() {
    let s = token_store_redis(sh_dead_pool(), 0);
    s.timeout = 50000000;
    let r = s.issue("ada");
    guard let _t = r else {
        let found = s.lookup("anything");
        guard let _w = found else {
            assert(!s.revoke("anything"));
            return;
        }
        assert(false);
        return;
    }
    assert(false);
}

// ---- hub -----------------------------------------------------------------

fn sh_socket(id: str) -> Socket {
    let no: map[str]str = {};
    return new_socket(id, "/t", "", "", no, 64, 0, text(101, ""));
}

fn sh_sio_socket(id: str) -> Socket {
    let s = sh_socket(id);
    s.sio = true;
    return s;
}

// The next thing queued on `s` within `ms`, or none.
fn sh_next(s: Socket, ms: int) -> opt[Out] {
    let end = time.mono() + ms * 1000000;
    while time.mono() < end {
        select {
            case let m = chan_recv(s.out) {
                return m;
            }
            default { }
        }
        time.sleep(1000000);
    }
    return none;
}

fn sh_text(s: Socket) -> str {
    guard let o = sh_next(s, 2000) else {
        return "<nothing>";
    }
    return o.text;
}

fn sh_silent(s: Socket) -> bool {
    guard let _o = sh_next(s, 60) else {
        return true;
    }
    return false;
}

fn sh_pair(test: str) -> opt[[Hub]] {
    guard let _p = sh_pool(test) else { return none; }
    let channel = sh_unique("hub");
    let a = new_hub();
    let b = new_hub();
    assert((a.share(sh_url(), channel) ?? -1) == 0);
    assert((b.share(sh_url(), channel) ?? -1) == 0);
    return some([a, b]);
}

fn test_hub_shared_broadcast_reaches_the_other_instance_once() {
    guard let hs = sh_pair("test_hub_shared_broadcast_reaches_the_other_instance_once") else { return; }
    let on_a = sh_socket("a");
    let on_b = sh_socket("b");
    hs[0].add(on_a);
    hs[1].add(on_b);
    assert(hs[0].broadcast("hello", "") == 1);
    assert(sh_text(on_a) == "hello");
    assert(sh_text(on_b) == "hello");
    assert(sh_silent(on_a));     // not echoed back to its sender's instance
    assert(sh_silent(on_b));
    hs[0].unshare();
    hs[1].unshare();
}

fn test_hub_shared_rooms_reach_only_their_members() {
    guard let hs = sh_pair("test_hub_shared_rooms_reach_only_their_members") else { return; }
    let in_room = sh_socket("in");
    let out_of_room = sh_socket("out");
    hs[1].join_room(in_room, "lobby");
    hs[1].add(out_of_room);
    hs[0].to_room("lobby", "hi", "");
    assert(sh_text(in_room) == "hi");
    assert(sh_silent(out_of_room));
    hs[0].unshare();
    hs[1].unshare();
}

fn test_hub_shared_except_applies_on_the_other_instance() {
    guard let hs = sh_pair("test_hub_shared_except_applies_on_the_other_instance") else { return; }
    let skipped = sh_socket("skip");
    let reached = sh_socket("reach");
    hs[1].add(skipped);
    hs[1].add(reached);
    hs[0].broadcast("hi", "skip");
    assert(sh_text(reached) == "hi");
    assert(sh_silent(skipped));
    hs[0].unshare();
    hs[1].unshare();
}

fn test_hub_shared_binary_keeps_its_bytes() {
    guard let hs = sh_pair("test_hub_shared_binary_keeps_its_bytes") else { return; }
    let s = sh_socket("s");
    hs[1].add(s);
    hs[0].to_room_binary("", b"\x00\xff\x7f", "");
    guard let o = sh_next(s, 2000) else { assert(false); return; }
    assert(o.kind == 1);
    assert(o.data == b"\x00\xff\x7f");
    hs[0].unshare();
    hs[1].unshare();
}

fn test_hub_shared_socketio_events_cross_instances() {
    guard let hs = sh_pair("test_hub_shared_socketio_events_cross_instances") else { return; }
    let s = sh_sio_socket("s");
    let plain = sh_socket("plain");
    hs[1].join_room(s, "lobby");
    hs[1].join_room(plain, "lobby");
    hs[0].emit_to_room("lobby", "/", "chat", "[\"hi\"]", "");
    assert(contains(sh_text(s), "chat"));
    assert(sh_silent(plain));
    hs[0].emit_all("/", "all", "[1]", "");
    assert(contains(sh_text(s), "all"));
    hs[0].unshare();
    hs[1].unshare();
}

fn test_hub_shared_binary_events_keep_every_attachment() {
    guard let hs = sh_pair("test_hub_shared_binary_events_keep_every_attachment") else { return; }
    let s = sh_sio_socket("s");
    hs[1].add(s);
    hs[0].emit_binary_to_room("", "/", "file", "[]", [b"one", b"\x00two"], "");
    guard let head = sh_next(s, 2000) else { assert(false); return; }
    assert(contains(head.text, "file"));
    guard let first = sh_next(s, 2000) else { assert(false); return; }
    guard let second = sh_next(s, 2000) else { assert(false); return; }
    assert(first.data == b"one" && second.data == b"\x00two");
    hs[0].unshare();
    hs[1].unshare();
}

// A channel is shared, so a hub must survive whatever appears on it.
fn test_hub_shared_ignores_and_counts_what_it_cannot_read() {
    guard let p = sh_pool("test_hub_shared_ignores_and_counts_what_it_cannot_read") else { return; }
    let channel = sh_unique("hub");
    let h = new_hub();
    assert((h.share(sh_url(), channel) ?? -1) == 0);
    let s = sh_socket("s");
    h.add(s);
    let dl = until_of(time.mono() + 1000000000);
    let _a = redis.pool_do(p, [to_bytes("PUBLISH"), to_bytes(channel), to_bytes("{not json")], dl);
    let _b = redis.pool_do(p, [to_bytes("PUBLISH"), to_bytes(channel),
        to_bytes("{\"from\":\"x\",\"kind\":\"nonsense\",\"room\":\"\",\"text\":\"\",\"except\":\"\",\"namespace\":\"\",\"name\":\"\",\"data\":[]}")], dl);
    let tries = 0;
    while h.relay_losses().malformed < 2 && tries < 2000 {
        time.sleep(1000000);
        tries = tries + 1;
    }
    assert(h.relay_losses().malformed == 2);
    assert(sh_silent(s));
    h.unshare();
}

// Redis drops subscribers; the hub has to find its way back alone.
fn test_hub_shared_comes_back_after_losing_its_subscription() {
    guard let p = sh_pool("test_hub_shared_comes_back_after_losing_its_subscription") else { return; }
    guard let hs = sh_pair("test_hub_shared_comes_back_after_losing_its_subscription") else { return; }
    let s = sh_socket("s");
    hs[1].add(s);
    let kill = redis.pool_do(p, [to_bytes("CLIENT"), to_bytes("KILL"), to_bytes("TYPE"),
                                 to_bytes("pubsub")], until_of(time.mono() + 1000000000));
    guard let _k = kill else { assert(false); return; }
    let tries = 0;
    while hs[1].relay_losses().reconnects == 0 && tries < 3000 {
        time.sleep(1000000);
        tries = tries + 1;
    }
    assert(hs[1].relay_losses().reconnects >= 1);
    // Subscribed again a moment after that counter moves.
    let got = false;
    tries = 0;
    while !got && tries < 40 {
        hs[0].broadcast("back", "");
        guard let o = sh_next(s, 100) else {
            tries = tries + 1;
            continue;
        }
        got = o.text == "back";
    }
    assert(got);
    hs[0].unshare();
    hs[1].unshare();
}

// The promise a send makes: it never waits, whatever Redis is doing.
fn test_hub_shared_send_never_waits_and_counts_what_it_drops() {
    let pr = redis.new_pool("redis://127.0.0.1:1/0", 1);
    guard let p = pr else { assert(false); return; }
    let box: chan[str] = make_chan(2);
    let rl = HubRelay {
        pool: p, url: "redis://127.0.0.1:1/0", channel: "x", outbox: box, lock: make_mutex(),
        stopped: false, dropped: 0, lost: 0, malformed: 0, reconnects: 0
    };
    let h = new_hub();
    h.relay = some(rl);
    let s = sh_socket("s");
    h.add(s);
    let t0 = time.mono();
    assert(h.broadcast("one", "") == 1);
    assert(h.broadcast("two", "") == 1);
    assert(h.broadcast("three", "") == 1);
    assert(((time.mono() - t0) as int) < 100000000);
    assert(h.relay_losses().dropped == 1);
    assert(sh_text(s) == "one");
}

fn test_hub_share_refuses_what_cannot_work() {
    let h = new_hub();
    let bad = h.share("redis://127.0.0.1:1/0", "x");
    guard let _a = bad else {
        let empty = h.share(sh_url(), "");
        guard let _b = empty else { return; }
        assert(false);
        return;
    }
    assert(false);
}

fn test_hub_unshared_keeps_working_after_unshare() {
    guard let hs = sh_pair("test_hub_unshared_keeps_working_after_unshare") else { return; }
    let on_a = sh_socket("a");
    let on_b = sh_socket("b");
    hs[0].add(on_a);
    hs[1].add(on_b);
    hs[0].unshare();
    assert(hs[0].broadcast("local", "") == 1);
    assert(sh_text(on_a) == "local");
    assert(sh_silent(on_b));
    hs[1].unshare();
}

fn test_hub_unshared_is_all_zero_losses() {
    let l = new_hub().relay_losses();
    assert(l.dropped == 0 && l.lost == 0 && l.malformed == 0 && l.reconnects == 0);
}
