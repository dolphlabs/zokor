import "http";

gc struct TokApp {
    tokens: TokenStore,
}

fn tok_me(c: Ctx[TokApp]) -> http.Response {
    guard let who = bearer_subject(c, c.state.tokens) else {
        return respond(c.errors, "unauthorized", c.request_id);
    }
    return ok_json("{\"user\":" + quote(who) + "}");
}

fn tok_must_issue(s: TokenStore, subject: str) -> str {
    let r = s.issue(subject);
    guard let t = r else let e = err_of(r) {
        panic("issue: " + e);
    }
    return t;
}

fn test_tokens_are_long_random_and_hex() {
    let s = new_token_store(0);
    let a = tok_must_issue(s, "u1");
    let b = tok_must_issue(s, "u1");
    assert(len(a) == 64, "len " + to_str(len(a)));
    assert(a != b);
    let raw = encoding.hex_decode(a);
    guard let bs = raw else {
        panic("not hex: " + a);
    }
    assert(len(bs) == 32);
}

fn test_issue_lookup_revoke() {
    let s = new_token_store(0);
    let t = tok_must_issue(s, "user_7");
    assert((s.lookup(t) ?? "") == "user_7");
    assert(s.count() == 1);
    assert(s.revoke(t));
    assert(!s.revoke(t));
    assert(tok_gone(s.lookup(t)));
    assert(tok_gone(s.lookup("")));
    assert(tok_gone(s.lookup("deadbeef")));
}

fn test_tokens_expire_after_the_ttl() {
    let s = new_token_store(1000);
    let r = s.issue_at("u", 0);
    guard let t = r else {
        panic("issue failed");
    }
    assert((s.lookup_at(t, 999) ?? "") == "u");
    assert(tok_gone(s.lookup_at(t, 1000)));
    // an expired token is dropped on lookup
    assert(s.count() == 0);
}

fn test_zero_ttl_means_until_revoked() {
    let s = new_token_store(0);
    let r = s.issue_at("u", 0);
    guard let t = r else {
        panic("issue failed");
    }
    assert((s.lookup_at(t, 9000000000000000000) ?? "") == "u");
}

fn test_revoke_subject_ends_every_session() {
    let s = new_token_store(0);
    let a = tok_must_issue(s, "ada");
    let b = tok_must_issue(s, "ada");
    let c = tok_must_issue(s, "bob");
    assert(s.revoke_subject("ada") == 2);
    assert(tok_gone(s.lookup(a)));
    assert(tok_gone(s.lookup(b)));
    assert((s.lookup(c) ?? "") == "bob");
}

fn test_bearer_subject_reads_the_authorization_header() {
    let store = new_token_store(0);
    let r = new_router(TokApp { tokens: store });
    r.get("/me", tok_me);
    let t = tok_must_issue(store, "user_9");
    let ok_resp = r.serve(request(Method.GET, "/me").bearer(t).build());
    assert(resp_status(ok_resp) == 200);
    assert(resp_json(ok_resp).get("user").str_or("") == "user_9");
    let none_resp = r.serve(request(Method.GET, "/me").build());
    assert(resp_error_code(none_resp) == "unauthorized");
    store.revoke(t);
    let revoked = r.serve(request(Method.GET, "/me").bearer(t).build());
    assert(resp_status(revoked) == 401);
}

fn tok_issue_many(s: TokenStore, n: int) -> int {
    let ok_n = 0;
    for i in 0..n {
        let r = s.issue("u");
        if let t = r {
            if (s.lookup(t) ?? "") == "u" {
                ok_n = ok_n + 1;
            }
        }
    }
    return ok_n;
}

// Concurrent issue and lookup from many tasks: nothing lost, nothing
// shared between tokens.
fn test_concurrent_issue_is_safe() {
    let s = new_token_store(0);
    let hs: [join[int]] = [];
    for t in 0..8 {
        push(hs, spawn tok_issue_many(s, 50));
    }
    let total = 0;
    for h in hs {
        total = total + (join_wait(h) ?? 0);
    }
    assert(total == 400, "ok " + to_str(total));
    assert(s.count() == 400, "count " + to_str(s.count()));
}

fn tok_gone(o: opt[str]) -> bool {
    guard let _v = o else {
        return true;
    }
    return false;
}
