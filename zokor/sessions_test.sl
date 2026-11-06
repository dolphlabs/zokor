import "http";
import "redis";
import "strings";
import "time";
import "timez";

gc struct SsApp {
    sessions: Sessions,
}

fn ss_clock() -> timez.Clock {
    return timez.fixed_clock(timez.unix(1700000000));
}

fn ss_memory() -> Sessions {
    let ss = sessions_in_memory();
    ss.clock = ss_clock();
    return ss;
}

// A live Redis on 6379, or none: redis_test's rule.
fn ss_redis(test: str) -> opt[Sessions] {
    let pr = redis.new_pool("redis://127.0.0.1:6379/0", 2);
    guard let p = pr else {
        println("skip " + test + " (no pool)");
        return none;
    }
    let ping = redis.pool_do(p, [to_bytes("PING")], until_of(time.mono() + 300000000));
    guard let _pong = ping else {
        println("skip " + test + " (no Redis on 127.0.0.1:6379)");
        return none;
    }
    let ss = sessions_redis(p);
    ss.clock = ss_clock();
    return some(ss);
}

fn ss_repeat(ch: str, n: int) -> str {
    let out = "";
    let i = 0;
    while i < n {
        out = out + ch;
        i = i + 1;
    }
    return out;
}

fn ss_subject(test: str) -> str {
    return "user-" + test + "-" + to_str(time.mono() as int);
}

fn ss_login(c: Ctx[SsApp]) -> http.Response {
    let sr = session_start(c, c.state.sessions, c.header("x-user"));
    guard let s = sr else let e = err_of(sr) {
        panic(e);
    }
    let r = session_cookie(ok_json("{}"), c.state.sessions, s);
    guard let resp = r else let e = err_of(r) {
        panic(e);
    }
    return resp;
}

fn ss_me(c: Ctx[SsApp]) -> http.Response {
    let r = session_require(c, c.state.sessions);
    guard let s = r else let denied = err_of(r) {
        return denied;
    }
    return text(200, s.subject);
}

fn ss_logout(c: Ctx[SsApp]) -> http.Response {
    let r = session_end(c, c.state.sessions, ok_json("{}"));
    guard let resp = r else let e = err_of(r) {
        panic(e);
    }
    return resp;
}

fn ss_router(ss: Sessions) -> Router[SsApp] {
    let r = new_router(SsApp { sessions: ss });
    r.post("/login", ss_login);
    r.post("/logout", ss_logout);
    r.get("/me", ss_me);
    return r;
}

// The cookie's value from a Set-Cookie header, as a browser keeps it.
fn ss_cookie_value(resp: http.Response) -> str {
    let raw = resp_header(resp, "set-cookie");
    let start = strings.find(raw, "=") + 1;
    let rest = strings.slice(raw, start, len(raw));
    let end = strings.find(rest, ";");
    if end < 0 {
        return rest;
    }
    return strings.slice(rest, 0, end);
}

fn ss_get_me(r: Router[SsApp], name: str, token: str) -> http.Response {
    return r.serve(get_request("/me").header("cookie", name + "=" + token).build());
}

fn ss_login_as(r: Router[SsApp], user: str, cookie: str) -> str {
    let req = request(Method.POST, "/login").header("x-user", user);
    if len(cookie) > 0 {
        req = req.header("cookie", cookie);
    }
    return ss_cookie_value(r.serve(req.build()));
}

// Each scenario runs on both stores: they share a code path, and a test
// on one alone would let the other drift.
fn ss_round_trip(ss: Sessions, user: str) {
    let r = ss_router(ss);
    let token = ss_login_as(r, user, "");
    assert(session_token_ok(token));
    let resp = ss_get_me(r, "__Host-sid", token);
    assert(resp_status(resp) == 200);
    assert(resp_text(resp) == user);
    assert(resp_status(r.serve(get_request("/me").build())) == 401);
}

fn test_session_round_trip_in_memory() {
    ss_round_trip(ss_memory(), "ada");
}

fn test_session_round_trip_on_redis() {
    guard let ss = ss_redis("test_session_round_trip_on_redis") else { return; }
    ss_round_trip(ss, ss_subject("rt"));
}

fn test_session_cookie_is_locked_down_by_default() {
    let r = ss_router(ss_memory());
    let raw = resp_header(r.serve(request(Method.POST, "/login").header("x-user", "ada").build()),
                          "set-cookie");
    assert(strings.has_prefix(raw, "__Host-sid="));
    assert(contains(raw, "HttpOnly"));
    assert(contains(raw, "Secure"));
    assert(contains(raw, "SameSite=Lax"));
    assert(contains(raw, "Path=/"));
    assert(!contains(raw, "Domain"));
}

fn test_session_store_holds_a_hash_never_the_token() {
    let ss = ss_memory();
    let r = ss_router(ss);
    let token = ss_login_as(r, "ada", "");
    assert(!has(ss.local, token));
    assert(has(ss.local, session_key(token)));
    assert(!contains(ss.local[session_key(token)].text, token));
}

fn test_session_on_redis_stores_a_hash_never_the_token() {
    guard let ss = ss_redis("test_session_on_redis_stores_a_hash_never_the_token") else { return; }
    let r = ss_router(ss);
    let token = ss_login_as(r, ss_subject("hash"), "");
    guard let p = ss.remote else { return; }
    let dl = until_of(time.mono() + 2000000000);
    let plain = redis.pool_do(p, [to_bytes("EXISTS"), remote_slot(token)], dl);
    guard let a = plain else { assert(false); return; }
    assert(a.num == 0);
    let hashed = redis.pool_do(p, [to_bytes("EXISTS"), remote_slot(session_key(token))], dl);
    guard let b = hashed else { assert(false); return; }
    assert(b.num == 1);
}

// A token planted in the victim's browser before login must die at login.
fn ss_fixation(ss: Sessions, user: str) {
    let r = ss_router(ss);
    let planted = ss_login_as(r, "attacker", "");
    let victim = ss_login_as(r, user, "__Host-sid=" + planted);
    assert(victim != planted);
    assert(resp_status(ss_get_me(r, "__Host-sid", planted)) == 401);
    assert(resp_text(ss_get_me(r, "__Host-sid", victim)) == user);
}

fn test_session_start_ends_the_session_it_replaces_in_memory() {
    ss_fixation(ss_memory(), "ada");
}

fn test_session_start_ends_the_session_it_replaces_on_redis() {
    guard let ss = ss_redis("test_session_start_ends_the_session_it_replaces_on_redis") else { return; }
    ss_fixation(ss, ss_subject("fix"));
}

fn ss_idle(ss: Sessions, user: str) {
    let r = ss_router(ss);
    let token = ss_login_as(r, user, "");
    ss.clock.advance(ss.idle_ttl - timez.SECOND);
    assert(resp_status(ss_get_me(r, "__Host-sid", token)) == 200);  // touches it
    ss.clock.advance(ss.idle_ttl - timez.SECOND);
    assert(resp_status(ss_get_me(r, "__Host-sid", token)) == 200);  // activity keeps it
    ss.clock.advance(ss.idle_ttl + timez.SECOND);
    assert(resp_status(ss_get_me(r, "__Host-sid", token)) == 401);
}

fn test_session_ends_after_idle_ttl_in_memory() {
    ss_idle(ss_memory(), "ada");
}

fn test_session_ends_after_idle_ttl_on_redis() {
    guard let ss = ss_redis("test_session_ends_after_idle_ttl_on_redis") else { return; }
    ss_idle(ss, ss_subject("idle"));
}

// However active: a stolen token must not live forever.
fn test_session_ends_at_absolute_ttl_despite_activity() {
    let ss = ss_memory();
    ss.idle_ttl = timez.HOUR;
    ss.absolute_ttl = 3 * timez.HOUR;
    let r = ss_router(ss);
    let token = ss_login_as(r, "ada", "");
    let i = 0;
    while i < 2 {
        ss.clock.advance(59 * timez.MINUTE);
        assert(resp_status(ss_get_me(r, "__Host-sid", token)) == 200);
        i = i + 1;
    }
    ss.clock.advance(59 * timez.MINUTE);
    assert(resp_status(ss_get_me(r, "__Host-sid", token)) == 200);
    ss.clock.advance(4 * timez.MINUTE);
    assert(resp_status(ss_get_me(r, "__Host-sid", token)) == 401);
}

fn ss_logout_scenario(ss: Sessions, user: str) {
    let r = ss_router(ss);
    let token = ss_login_as(r, user, "");
    let out = r.serve(request(Method.POST, "/logout").header("cookie", "__Host-sid=" + token).build());
    assert(resp_status(out) == 200);
    let cleared = resp_header(out, "set-cookie");
    assert(contains(cleared, "Max-Age=0"));
    assert(contains(cleared, "Path=/") && contains(cleared, "Secure"));
    assert(resp_status(ss_get_me(r, "__Host-sid", token)) == 401);
}

fn test_session_end_works_at_once_in_memory() {
    ss_logout_scenario(ss_memory(), "ada");
}

fn test_session_end_works_at_once_on_redis() {
    guard let ss = ss_redis("test_session_end_works_at_once_on_redis") else { return; }
    ss_logout_scenario(ss, ss_subject("out"));
}

fn ss_end_all(ss: Sessions, user: str) {
    let r = ss_router(ss);
    let laptop = ss_login_as(r, user, "");
    let phone = ss_login_as(r, user, "");
    let other = ss_login_as(r, user + "-other", "");
    assert((ss.end_all(user) ?? -1) == 2);
    assert(resp_status(ss_get_me(r, "__Host-sid", laptop)) == 401);
    assert(resp_status(ss_get_me(r, "__Host-sid", phone)) == 401);
    assert(resp_status(ss_get_me(r, "__Host-sid", other)) == 200);
    assert((ss.end_all(user) ?? -1) == 0);
}

fn test_session_end_all_covers_every_device_in_memory() {
    ss_end_all(ss_memory(), "ada");
}

fn test_session_end_all_covers_every_device_on_redis() {
    guard let ss = ss_redis("test_session_end_all_covers_every_device_on_redis") else { return; }
    ss_end_all(ss, ss_subject("all"));
}

fn test_session_refuses_a_token_of_the_wrong_shape() {
    let r = ss_router(ss_memory());
    assert(resp_status(ss_get_me(r, "__Host-sid", "short")) == 401);
    assert(!session_token_ok(ss_repeat("A", 64)));
    assert(!session_token_ok(ss_repeat("g", 64)));
    assert(!session_token_ok(ss_repeat("a", 65)));
    assert(session_token_ok(ss_repeat("a", 64)));
}

fn test_session_refuses_a_stored_value_it_cannot_read() {
    let ss = ss_memory();
    let r = ss_router(ss);
    let token = ss_login_as(r, "ada", "");
    ss.local[session_key(token)].text = "{not json";
    assert(resp_status(ss_get_me(r, "__Host-sid", token)) == 401);
}

fn ss_data(ss: Sessions, user: str) {
    let r = ss_router(ss);
    let token = ss_login_as(r, user, "");
    let first = ss.load(token) ?? none;
    guard let s = first else { assert(false); return; }
    s.set("cart", "42");
    assert((ss.save(s) ?? -1) == 0);
    let second = ss.load(token) ?? none;
    guard let again = second else { assert(false); return; }
    assert(again.get("cart") == "42");
    assert(again.get("missing") == "");
    assert(again.csrf == s.csrf && len(again.csrf) == 64);
    assert(again.remove("cart"));
    assert(!again.remove("cart"));
}

fn test_session_data_is_saved_in_memory() {
    ss_data(ss_memory(), "ada");
}

fn test_session_data_is_saved_on_redis() {
    guard let ss = ss_redis("test_session_data_is_saved_on_redis") else { return; }
    ss_data(ss, ss_subject("data"));
}

// A handler's unsaved change must not leak into the next request.
fn test_session_changes_need_a_save() {
    let ss = ss_memory();
    let r = ss_router(ss);
    let token = ss_login_as(r, "ada", "");
    let first = ss.load(token) ?? none;
    guard let s = first else { assert(false); return; }
    s.set("cart", "42");
    let second = ss.load(token) ?? none;
    guard let again = second else { assert(false); return; }
    assert(again.get("cart") == "");
}

fn test_session_csrf_token_is_compared_exactly() {
    let ss = ss_memory();
    let r = ss_router(ss);
    let token = ss_login_as(r, "ada", "");
    let got = ss.load(token) ?? none;
    guard let s = got else { assert(false); return; }
    assert(s.csrf_matches(s.csrf));
    assert(!s.csrf_matches(""));
    assert(!s.csrf_matches(s.csrf + "0"));
    assert(!s.csrf_matches(ss_repeat("0", 64)));
}

fn test_session_cookie_needs_the_request_that_started_it() {
    let ss = ss_memory();
    let token = ss_login_as(ss_router(ss), "ada", "");
    let got = ss.load(token) ?? none;
    guard let s = got else { assert(false); return; }
    let r = session_cookie(ok_json("{}"), ss, s);
    guard let _c = r else {
        return;
    }
    panic("a loaded session has no token to send");
}

fn ss_nobody(c: Ctx[SsApp]) -> http.Response {
    let r = session_start(c, c.state.sessions, "");
    guard let _s = r else {
        return ok_json("{}");
    }
    panic("a session needs a subject");
}

// A login as nobody must not exist.
fn test_session_start_needs_a_subject() {
    let r = new_router(SsApp { sessions: ss_memory() });
    r.post("/nobody", ss_nobody);
    assert(resp_status(r.serve(request(Method.POST, "/nobody").build())) == 200);
}

fn test_session_store_down_answers_503_not_401_and_not_ok() {
    let pr = redis.new_pool("redis://127.0.0.1:1/0", 1);
    guard let p = pr else { assert(false); return; }
    let ss = sessions_redis(p);
    ss.timeout = 200 * timez.MILLISECOND;
    let r = ss_router(ss);
    let token = ss_repeat("a", 64);
    let resp = ss_get_me(r, "__Host-sid", token);
    assert(resp_status(resp) == 503);
    assert(resp_error_code(resp) == "unavailable");
    assert(!contains(resp_text(resp), "127.0.0.1"));
}

fn test_session_expired_entries_are_swept_from_memory() {
    let ss = ss_memory();
    let r = ss_router(ss);
    let i = 0;
    while i < 10 {
        let _t = ss_login_as(r, "u" + to_str(i), "");
        i = i + 1;
    }
    ss.clock.advance(ss.absolute_ttl + timez.SECOND);
    while i < sweep_every() + 5 {
        let _t = ss_login_as(r, "u" + to_str(i), "");
        i = i + 1;
    }
    assert(len(ss.local) < sweep_every());
    assert(len(ss.by_subject) == len(ss.local));
}

fn test_session_development_cookie_works_over_http() {
    let ss = ss_memory();
    ss.cookie.name = "sid";
    ss.cookie.secure = false;
    let r = ss_router(ss);
    let token = ss_login_as(r, "ada", "");
    assert(resp_status(ss_get_me(r, "sid", token)) == 200);
}
