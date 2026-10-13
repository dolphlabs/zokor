// Idempotency keys (the IETF Idempotency-Key header): a client retrying a
// POST or PATCH after a timeout gets the first answer again instead of a
// second charge, order or email.
//
//     r.idempotency(zokor.idempotency_in_memory());     // one instance
//     r.idempotency(zokor.idempotency_redis(redis_pool)); // shared, many
//
// A request with an `Idempotency-Key` header, on a POST or PATCH route:
//   - first time: runs, and its answer is kept for 24 hours;
//   - again, the same request: the kept answer, with
//     `Idempotent-Replayed: true`, and the handler does not run;
//   - again while the first is still running: 409 conflict;
//   - again with a different method, path or body: 422, the key was
//     reused for another request.
// Keys are scoped by method, route and -- when `scope_local` names one --
// the caller (`c.local("user_id")`, set by authentication), so one user
// cannot replay another's answer. Answers that are not final -- 5xx, 408,
// 429 -- are not kept: the next retry runs the handler again. A handler
// that panics leaves its key "running" for `lock_ttl` (30 s), then a
// retry runs.

import "crypto";
import "encoding";
import "http";
import "json";
import "redis";
import "strings";
import "time";

gc struct IdemSlot {
    fp: str,
    done: bool,
    resp: opt[http.Response],
    expires: int,
}

gc struct IdemShard {
    slots: map[str]IdemSlot,
    lock: mutex,
    since_sweep: int,
}

pub gc struct Idempotency {
    // How long a finished answer is kept.
    ttl: int,
    // How long a key stays "running" if its request never finishes.
    lock_ttl: int,
    // Answers with a bigger body are sent but not kept.
    max_body: int,
    // A local set by a `before` (authentication) that scopes keys to the
    // caller; "" scopes them to the route alone.
    scope_local: str,
    // A POST or PATCH without the header is refused with 400 when true.
    required: bool,
    shards: [IdemShard],
    remote: opt[redis.Pool],
}

fn idem_defaults(remote: opt[redis.Pool]) -> Idempotency {
    let shards: [IdemShard] = [];
    let i = 0;
    while i < 16 {
        push(shards, IdemShard { slots: {}, lock: make_mutex(), since_sweep: 0 });
        i = i + 1;
    }
    return Idempotency {
        ttl: 24 * 3600 * 1000000000,
        lock_ttl: 30 * 1000000000,
        max_body: 1 << 20,
        scope_local: "",
        required: false,
        shards: shards,
        remote: remote
    };
}

// Answers kept in this process: right for one instance.
pub fn idempotency_in_memory() -> Idempotency {
    return idem_defaults(none);
}

// Answers kept in Redis, shared by every instance behind the balancer.
pub fn idempotency_redis(p: redis.Pool) -> Idempotency {
    return idem_defaults(some(p));
}

fn idem_method(m: str) -> bool {
    return m == "POST" || m == "PATCH";
}

// A key a client may send: 1 to 255 printable ASCII characters.
fn idem_key_ok(k: str) -> bool {
    if len(k) == 0 || len(k) > 255 {
        return false;
    }
    for b in to_bytes(k) {
        let x = b as int;
        if x < 0x21 || x > 0x7e {
            return false;
        }
    }
    return true;
}

// Answers that say what the request did. A 5xx, timeout or rate limit is
// not final: a retry should run again.
fn idem_final(status: i32) -> bool {
    return status < 500 && status != 408 && status != 429;
}

// What happened when a key was looked up.
struct IdemStart {
    // set: answer with this and do not run the handler
    stop: opt[http.Response],
    // the storage key and request fingerprint, to finish with
    slot: str,
    fp: str,
}

impl Idempotency {
    fn shard_of(self: Idempotency, slot: str) -> IdemShard {
        let h = 0;
        for b in to_bytes(strings.slice(slot, 0, 8)) {
            h = h * 31 + (b as int);
        }
        if h < 0 {
            h = -h;
        }
        return self.shards[h % len(self.shards)];
    }

    // Keeps (or, when it is not final, releases) the answer for `st`.
    fn finish(self: Idempotency, st: IdemStart, resp: http.Response) {
        if len(st.slot) == 0 {
            return;
        }
        let keep = idem_final(resp.status) && len(resp.body) <= self.max_body;
        if let p = self.remote {
            idem_finish_remote(self, p, st, resp, keep);
            return;
        }
        let sh = self.shard_of(st.slot);
        mutex_lock(sh.lock);
        if keep {
            sh.slots[st.slot] = IdemSlot {
                fp: st.fp,
                done: true,
                resp: some(idem_copy(resp)),
                expires: (time.mono() as int) + self.ttl
            };
        } else {
            del(sh.slots, st.slot);
        }
        mutex_unlock(sh.lock);
    }
}

// Checks the key for a request about to run. `route` is the matched
// pattern.
fn idem_start[S](ip: Idempotency, c: Ctx[S], route: str) -> IdemStart {
    let key = c.header("idempotency-key");
    if len(key) == 0 {
        if ip.required {
            return IdemStart {
                stop: some(respond_with(c.errors, "bad_request",
                    "this request needs an Idempotency-Key header", c.request_id)),
                slot: "", fp: "" };
        }
        return IdemStart { stop: none, slot: "", fp: "" };
    }
    if !idem_key_ok(key) {
        return IdemStart {
            stop: some(respond_with(c.errors, "bad_request",
                "Idempotency-Key must be 1 to 255 printable characters", c.request_id)),
            slot: "", fp: "" };
    }
    let scope = "";
    if len(ip.scope_local) > 0 {
        scope = c.local(ip.scope_local);
    }
    let slot = "zokor:idem:" + encoding.base64url_encode(crypto.sha256(to_bytes(
        c.req.method + " " + route + " " + scope + " " + key))[0..18]);
    let fp = encoding.base64url_encode(crypto.sha256(to_bytes(c.req.method + " " +
        c.req.path + "\n" + to_str(c.req.body)))[0..18]);
    if let p = ip.remote {
        return idem_start_remote(ip, c, p, slot, fp);
    }
    let sh = ip.shard_of(slot);
    let now = time.mono() as int;
    mutex_lock(sh.lock);
    sh.since_sweep = sh.since_sweep + 1;
    if sh.since_sweep >= 256 {
        idem_sweep(sh, now);
        sh.since_sweep = 0;
    }
    if has(sh.slots, slot) {
        let s = sh.slots[slot];
        if s.expires > now {
            mutex_unlock(sh.lock);
            return IdemStart { stop: some(idem_seen(c, s.fp, fp, s.done, s.resp)), slot: "", fp: "" };
        }
    }
    sh.slots[slot] = IdemSlot { fp: fp, done: false, resp: none, expires: now + ip.lock_ttl };
    mutex_unlock(sh.lock);
    return IdemStart { stop: none, slot: slot, fp: fp };
}

fn idem_start_remote[S](ip: Idempotency, c: Ctx[S], p: redis.Pool, slot: str,
                        fp: str) -> IdemStart {
    let dl = until_of(time.mono() + 2000000000);
    let running = to_bytes("running " + fp);
    let sr = redis.pool_do(p, [to_bytes("SET"), to_bytes(slot), running, to_bytes("NX"),
                               to_bytes("PX"), to_bytes(to_str(ip.lock_ttl / 1000000))], dl);
    guard let set = sr else let e = err_of(sr) {
        // without the store, running twice is worse than refusing once
        return IdemStart { stop: some(respond_with(c.errors, "unavailable",
            "idempotency store unreachable: " + e, c.request_id)), slot: "", fp: "" };
    }
    if set.text == "OK" {
        return IdemStart { stop: none, slot: slot, fp: fp };
    }
    let gr = redis.pool_do(p, [to_bytes("GET"), to_bytes(slot)], dl);
    guard let got = gr else let e = err_of(gr) {
        return IdemStart { stop: some(respond_with(c.errors, "unavailable",
            "idempotency store unreachable: " + e, c.request_id)), slot: "", fp: "" };
    }
    guard let raw = got.bulk else {
        // expired between the two calls: a retry will take it
        return IdemStart { stop: some(respond(c.errors, "conflict", c.request_id)), slot: "", fp: "" };
    }
    let text = to_str(raw);
    if strings.has_prefix(text, "running ") {
        let not_yet: opt[http.Response] = none;
        return IdemStart { stop: some(idem_seen(c, strings.slice(text, 8, len(text)), fp, false,
                                                not_yet)),
                           slot: "", fp: "" };
    }
    let kr: result[IdemKept, str] = json.decode(text);
    guard let kept = kr else {
        return IdemStart { stop: some(respond(c.errors, "conflict", c.request_id)), slot: "", fp: "" };
    }
    let br = encoding.base64_decode(kept.b);
    guard let body = br else {
        return IdemStart { stop: some(respond(c.errors, "conflict", c.request_id)), slot: "", fp: "" };
    }
    let resp = http.Response {
        status: kept.s as i32,
        status_text: kept.t,
        content_type: kept.c,
        location: kept.l,
        extra: kept.x,
        body: body
    };
    return IdemStart { stop: some(idem_seen(c, kept.f, fp, true, some(resp))), slot: "", fp: "" };
}

// A kept answer in Redis.
gc struct IdemKept {
    f: str,
    s: int,
    t: str,
    c: str,
    l: str,
    x: [str],
    b: str,
}

fn idem_finish_remote(ip: Idempotency, p: redis.Pool, st: IdemStart, resp: http.Response,
                      keep: bool) {
    let dl = until_of(time.mono() + 2000000000);
    if !keep {
        let _d = redis.pool_do(p, [to_bytes("DEL"), to_bytes(st.slot)], dl);
        return;
    }
    let extra: [str] = [];
    for line in resp.extra {
        push(extra, line);
    }
    let kept = IdemKept {
        f: st.fp,
        s: resp.status as int,
        t: resp.status_text,
        c: resp.content_type,
        l: resp.location,
        x: extra,
        b: encoding.base64_encode(resp.body)
    };
    let _s = redis.pool_do(p, [to_bytes("SET"), to_bytes(st.slot), to_bytes(json.encode(kept)),
                               to_bytes("PX"), to_bytes(to_str(ip.ttl / 1000000))], dl);
}

// The answer to a key already seen: the kept one, or why not.
fn idem_seen[S](c: Ctx[S], kept_fp: str, fp: str, done: bool,
                resp: opt[http.Response]) -> http.Response {
    if kept_fp != fp {
        return respond_with(c.errors, "unprocessable",
            "this Idempotency-Key was used for a different request", c.request_id);
    }
    if !done {
        return respond_with(c.errors, "conflict",
            "a request with this Idempotency-Key is still being processed", c.request_id);
    }
    guard let r = resp else {
        return respond(c.errors, "conflict", c.request_id);
    }
    return http.with_header(idem_copy(r), "idempotent-replayed", "true");
}

// A copy whose header list is its own: finish() adds headers to the
// response it sends, which must not land in the kept one.
fn idem_copy(r: http.Response) -> http.Response {
    let extra: [str] = [];
    for line in r.extra {
        push(extra, line);
    }
    return http.Response {
        status: r.status,
        status_text: r.status_text,
        content_type: r.content_type,
        location: r.location,
        extra: extra,
        body: r.body
    };
}

fn idem_sweep(sh: IdemShard, now: int) {
    let dead: [str] = [];
    for k, slot in sh.slots {
        if slot.expires <= now {
            push(dead, k);
        }
    }
    for k in dead {
        del(sh.slots, k);
    }
}
