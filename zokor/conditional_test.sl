import "http";
import "strings";
import "timez";

gc struct CdState {
    version: int,
    updated: timez.Time,
}

// Wed, 14 Oct 2026 17:46:40 GMT
fn cd_updated() -> int {
    return 1792000000;
}

fn cd_tag(c: Ctx[CdState]) -> str {
    return etag_of(to_bytes("doc-" + to_str(c.state.version)));
}

fn cd_read(c: Ctx[CdState]) -> http.Response {
    let tag = cd_tag(c);
    if let stop = preconditions(c, tag, some(c.state.updated)) {
        return stop;
    }
    return with_validators(text(200, "v" + to_str(c.state.version)), tag,
                           some(c.state.updated));
}

fn cd_write(c: Ctx[CdState]) -> http.Response {
    if let stop = preconditions(c, cd_tag(c), some(c.state.updated)) {
        return stop;
    }
    c.state.version = c.state.version + 1;
    c.state.updated = c.state.updated.add(timez.SECOND);
    return with_validators(text(200, "v" + to_str(c.state.version)), cd_tag(c),
                           some(c.state.updated));
}

fn cd_body(c: Ctx[CdState]) -> http.Response {
    return cache_for(text(200, "hello"), 60);
}

fn cd_own(c: Ctx[CdState]) -> http.Response {
    return with_header(text(200, "mine"), "etag", "\"own\"");
}

fn cd_router() -> Router[CdState] {
    let r = new_router(CdState { version: 1, updated: timez.unix(cd_updated()) });
    r.get("/doc", cd_read);
    r.put("/doc", cd_write);
    r.get("/body", cd_body);
    r.post("/body", cd_body);
    r.get("/own", cd_own);
    return r;
}

fn cd_send(r: Router[CdState], m: Method, p: str, name: str, value: str) -> http.Response {
    let rq = request(m, p);
    if len(name) > 0 {
        rq = rq.header(name, value);
    }
    return r.serve(rq.build());
}

fn cd_status(resp: http.Response) -> int {
    return resp.status as int;
}

fn test_a_plain_read_carries_its_validators() {
    let r = cd_router();
    let resp = cd_send(r, Method.GET, "/doc", "", "");
    assert(cd_status(resp) == 200);
    assert(strings.has_prefix(resp_header(resp, "etag"), "\""));
    assert(resp_header(resp, "last-modified") == "Wed, 14 Oct 2026 17:46:40 GMT");
}

fn test_if_none_match_answers_304_without_a_body() {
    let r = cd_router();
    let tag = resp_header(cd_send(r, Method.GET, "/doc", "", ""), "etag");
    let same = cd_send(r, Method.GET, "/doc", "If-None-Match", tag);
    assert(cd_status(same) == 304);
    assert(len(same.body) == 0);
    assert(resp_header(same, "etag") == tag);
    // weak comparison: W/ on the client's copy still matches
    assert(cd_status(cd_send(r, Method.GET, "/doc", "If-None-Match", "W/" + tag)) == 304);
    // one of a list, a comma inside another tag's quotes notwithstanding
    assert(cd_status(cd_send(r, Method.GET, "/doc", "If-None-Match",
                             "\"a,b\", W/\"x\" ,  " + tag)) == 304);
    assert(cd_status(cd_send(r, Method.GET, "/doc", "If-None-Match", "*")) == 304);
    assert(cd_status(cd_send(r, Method.GET, "/doc", "If-None-Match", "\"stale\"")) == 200);
}

fn test_malformed_tag_lists_never_match() {
    let r = cd_router();
    let tag = resp_header(cd_send(r, Method.GET, "/doc", "", ""), "etag");
    let bare = strings.slice(tag, 1, len(tag) - 1);
    assert(cd_status(cd_send(r, Method.GET, "/doc", "If-None-Match", bare)) == 200);
    assert(cd_status(cd_send(r, Method.GET, "/doc", "If-None-Match",
                             strings.slice(tag, 0, len(tag) - 1))) == 200);
    // what follows a malformed member is not guessed at
    assert(cd_status(cd_send(r, Method.GET, "/doc", "If-None-Match", "junk, " + tag)) == 200);
}

fn test_if_modified_since_compares_to_the_second() {
    let r = cd_router();
    assert(cd_status(cd_send(r, Method.GET, "/doc", "If-Modified-Since",
                             "Wed, 14 Oct 2026 17:46:40 GMT")) == 304);
    assert(cd_status(cd_send(r, Method.GET, "/doc", "If-Modified-Since",
                             "Thu, 15 Oct 2026 00:00:00 GMT")) == 304);
    assert(cd_status(cd_send(r, Method.GET, "/doc", "If-Modified-Since",
                             "Wed, 14 Oct 2026 17:46:39 GMT")) == 200);
    // the obsolete forms RFC 9110 has servers accept
    assert(cd_status(cd_send(r, Method.GET, "/doc", "If-Modified-Since",
                             "Wednesday, 14-Oct-26 17:46:40 GMT")) == 304);
    // not a date: ignored, as the RFC requires
    assert(cd_status(cd_send(r, Method.GET, "/doc", "If-Modified-Since", "yesterday")) == 200);
}

fn test_if_none_match_takes_precedence_over_if_modified_since() {
    let r = cd_router();
    let rq = get_request("/doc")
        .header("If-None-Match", "\"stale\"")
        .header("If-Modified-Since", "Thu, 15 Oct 2026 00:00:00 GMT");
    assert(cd_status(r.serve(rq.build())) == 200);
}

fn test_if_match_guards_a_write_against_a_lost_update() {
    let r = cd_router();
    let tag = resp_header(cd_send(r, Method.GET, "/doc", "", ""), "etag");
    let first = cd_send(r, Method.PUT, "/doc", "If-Match", tag);
    assert(cd_status(first) == 200);
    assert(to_str(first.body) == "v2");
    // the same stale tag again: someone else's change would be lost
    let second = cd_send(r, Method.PUT, "/doc", "If-Match", tag);
    assert(cd_status(second) == 412);
    assert(strings.contains(to_str(second.body), "precondition_failed"));
    // If-Match compares strongly: a weak tag never matches
    let now_tag = resp_header(first, "etag");
    assert(cd_status(cd_send(r, Method.PUT, "/doc", "If-Match", "W/" + now_tag)) == 412);
    assert(cd_status(cd_send(r, Method.PUT, "/doc", "If-Match", "*")) == 200);
}

fn test_if_unmodified_since_and_if_none_match_on_writes() {
    let r = cd_router();
    assert(cd_status(cd_send(r, Method.PUT, "/doc", "If-Unmodified-Since",
                             "Wed, 14 Oct 2026 17:00:00 GMT")) == 412);
    assert(cd_status(cd_send(r, Method.PUT, "/doc", "If-Unmodified-Since",
                             "Wed, 14 Oct 2026 17:46:40 GMT")) == 200);
    // "create, never replace" on a resource that exists
    assert(cd_status(cd_send(r, Method.PUT, "/doc", "If-None-Match", "*")) == 412);
}

fn test_router_etags_tag_reads_and_answer_304() {
    let r = cd_router();
    assert(r.etags() == 0);
    let first = cd_send(r, Method.GET, "/body", "", "");
    let tag = resp_header(first, "etag");
    assert(tag == etag_of(to_bytes("hello")));
    let again = cd_send(r, Method.GET, "/body", "If-None-Match", tag);
    assert(cd_status(again) == 304);
    assert(len(again.body) == 0);
    // a cache refreshes its headers from the 304
    assert(resp_header(again, "cache-control") == "public, max-age=60");
    assert(resp_header(again, "etag") == tag);
    // not a read, not a 200, or tagged already: left alone
    assert(resp_header(cd_send(r, Method.POST, "/body", "", ""), "etag") == "");
    assert(resp_header(cd_send(r, Method.GET, "/missing", "", ""), "etag") == "");
    assert(resp_header(cd_send(r, Method.GET, "/own", "", ""), "etag") == "\"own\"");
}

fn test_router_etags_are_off_by_default() {
    let r = cd_router();
    assert(resp_header(cd_send(r, Method.GET, "/body", "", ""), "etag") == "");
}

fn test_etag_of_is_a_quoted_strong_tag() {
    let t = etag_of(to_bytes("hello"));
    assert(strings.has_prefix(t, "\"5-"));
    assert(strings.has_prefix(t, "\"") && strings.has_suffix(t, "\""));
    assert(t != etag_of(to_bytes("hellp")));
}
