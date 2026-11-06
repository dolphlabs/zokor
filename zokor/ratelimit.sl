// Rate limiting.
//
// A limiter answers one question per request -- may this client go
// now? -- and the answer has to be exact, because a client that is told
// "429, retry after 1s" and is refused again a second later stops
// trusting the header. So this is a sliding log, not a fixed window: a
// client may make at most `limit` requests in ANY `window` long span,
// and Retry-After is the time until its oldest counted request leaves
// the window, rounded up to whole seconds.
//
// There are no closures, so the limiter lives in your state and a
// three-line `before` hands it over together with the client's key:
//
//     fn limit(c: zokor.Ctx[App]) -> opt[http.Response] {
//         return zokor.rate_limit(c, c.state.limiter, c.header("x-client-id"));
//     }
//
// One limiter is shared by every connection's task. Its keys are split
// across 16 shards by a hash of the key, each with its own mutex, so
// tasks counting different clients rarely wait on each other. Measured,
// 8 tasks checking distinct keys: one mutex took 17.3 us a check (a
// lone task: 3.8 us -- contention made it 4.5x slower); 16 shards take
// 2.0 us, at the cost of hashing the key (a lone task: 4.4 us).
// Memory is bounded by the clients seen in the last window: each shard
// sweeps keys that went quiet every `sweep_every` of its requests.
//
// That limiter lives in one process, so behind a balancer each instance
// keeps its own count and three instances allow three times the limit,
// which is how login throttling quietly weakens as a service scales.
// rate_limiter_redis counts once for all of them:
//
//     let l = zokor.rate_limiter_redis(pool, "login", 5, 60 * timez.SECOND);
//
// It is the same sliding log, in a script Redis runs atomically and on
// Redis's clock, since instances' monotonic clocks cannot be compared. When
// Redis does not answer within `timeout`, the check falls back to this
// process's own count and adds to `fallbacks`: an outage weakens the limit
// by the number of instances, rather than removing it or taking the API
// down with it.

import "http";
import "crypto";
import "encoding";
import "redis";
import "time";

pub gc struct RateShard {
    // Per client key: the times (time.mono nanoseconds) of the requests
    // still inside the window, oldest first.
    hits: map[str][int],
    lock: mutex,
    since_sweep: int,
}

pub gc struct RateLimiter {
    limit: int,
    window: int,
    shards: [RateShard],
    sweep_every: int,
    // Set by rate_limiter_redis: the count is shared, under `name`.
    remote: opt[redis.Pool],
    name: str,
    // How long a shared check may take; it sits on the request path.
    timeout: int,
    // Shared checks answered by this process's count instead.
    fallbacks: int,
    fallback_lock: mutex,
}

// A power of two, so a shard is a mask, not a division.
fn rate_shard_count() -> int {
    return 16;
}

// FNV-1a over the key's bytes: cheap, and spreads similar keys (two
// addresses one digit apart) across shards.
fn key_hash(key: str) -> int {
    let h = 2166136261;
    for c in to_bytes(key) {
        h = ((h ^ (c as int)) * 16777619) & 0xffffffff;
    }
    return h;
}

// At most `limit` requests per client in any `window_ns` nanoseconds
// (1000000000 is one second). A limit below 1 is treated as 1.
pub fn new_rate_limiter(limit: int, window_ns: int) -> RateLimiter {
    let n = limit;
    if n < 1 {
        n = 1;
    }
    let w = window_ns;
    if w < 1 {
        w = 1;
    }
    let shards: [RateShard] = [];
    let i = 0;
    while i < rate_shard_count() {
        push(shards, RateShard { hits: {}, lock: make_mutex(), since_sweep: 0 });
        i = i + 1;
    }
    return RateLimiter {
        limit: n,
        window: w,
        shards: shards,
        sweep_every: 1024,
        remote: none,
        name: "",
        timeout: 100000000,
        fallbacks: 0,
        fallback_lock: make_mutex()
    };
}

// The same limit shared by every instance, counted in Redis. `name` keeps
// this limiter's counts apart from any other's on that server.
pub fn rate_limiter_redis(p: redis.Pool, name: str, limit: int, window_ns: int) -> RateLimiter {
    let l = new_rate_limiter(limit, window_ns);
    l.remote = some(p);
    l.name = name;
    return l;
}

// The sliding log of check_at. Microsecond scores, because a Lua number
// holds them exactly and nanoseconds since 1970 it does not. KEYS[1] is
// the client's set; ARGV is the window, the limit and a member unique to
// this request, since two requests in one microsecond must both count.
fn rate_script() -> str {
    return "local t = redis.call('TIME')\n" +
           "local now = t[1] * 1000000 + t[2]\n" +
           "local window = tonumber(ARGV[1])\n" +
           "local limit = tonumber(ARGV[2])\n" +
           "local floor = now - window\n" +
           "redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', floor)\n" +
           "local n = redis.call('ZCARD', KEYS[1])\n" +
           "local wait = 0\n" +
           "if n >= limit then\n" +
           "  local old = redis.call('ZRANGE', KEYS[1], 0, 0, 'WITHSCORES')\n" +
           "  wait = tonumber(old[2]) - floor\n" +
           "else\n" +
           "  redis.call('ZADD', KEYS[1], now, ARGV[3])\n" +
           "  n = n + 1\n" +
           "  redis.call('PEXPIRE', KEYS[1], math.ceil(window / 1000) + 1)\n" +
           "end\n" +
           "local first = redis.call('ZRANGE', KEYS[1], 0, 0, 'WITHSCORES')\n" +
           "return {wait, limit - n, tonumber(first[2]) - floor}\n";
}

// Whole seconds until `wait_ns` has passed, never below 1: a
// Retry-After of 0 invites an immediate retry that will be refused.
pub fn retry_after_secs(wait_ns: int) -> int {
    let s = (wait_ns + 999999999) / 1000000000;
    if s < 1 {
        return 1;
    }
    return s;
}

// One check's answer, for the RateLimit-* headers. A value struct, so
// asking costs no allocation.
pub struct RateCheck {
    // 0 when allowed (and counted); otherwise nanoseconds until a slot
    // frees, and the request was not counted.
    wait: int,
    // Requests the key may still make in the current window.
    remaining: int,
    // Nanoseconds until the oldest counted request leaves the window, the
    // moment `remaining` next goes up; the whole window when none is
    // counted.
    reset: int,
}

impl RateLimiter {
    // Counts one request for `key` at `now` (time.mono nanoseconds).
    // 0 means allowed and counted; otherwise it was refused, not
    // counted, and the result is the nanoseconds until a slot frees.
    // The clock is a parameter so tests need no sleeps.
    pub fn take_at(self: RateLimiter, key: str, now: int) -> int {
        return self.check_at(key, now).wait;
    }

    // take_at, with what is left: what the RateLimit-* headers report.
    pub fn check_at(self: RateLimiter, key: str, now: int) -> RateCheck {
        let floor = now - self.window;
        let wait = 0;
        let sh = self.shards[key_hash(key) & (rate_shard_count() - 1)];
        mutex_lock(sh.lock);
        let kept: [int] = [];
        if has(sh.hits, key) {
            let old = sh.hits[key];
            for t in old {
                if t > floor {
                    push(kept, t);
                }
            }
        }
        if len(kept) >= self.limit {
            wait = kept[0] - floor;
        } else {
            push(kept, now);
        }
        let remaining = self.limit - len(kept);
        let reset = kept[0] - floor;
        sh.hits[key] = kept;
        sh.since_sweep = sh.since_sweep + 1;
        if sh.since_sweep >= self.sweep_every {
            sh.since_sweep = 0;
            sweep_quiet(sh.hits, floor);
        }
        mutex_unlock(sh.lock);
        return RateCheck { wait: wait, remaining: remaining, reset: reset };
    }

    // One check of `key` now: shared when the limiter is, falling back
    // to this process's count when Redis does not answer.
    pub fn check(self: RateLimiter, key: str) -> RateCheck {
        guard let p = self.remote else {
            return self.check_at(key, time.mono() as int);
        }
        let r = self.check_shared(p, key);
        guard let rc = r else {
            mutex_lock(self.fallback_lock);
            self.fallbacks = self.fallbacks + 1;
            mutex_unlock(self.fallback_lock);
            return self.check_at(key, time.mono() as int);
        }
        return rc;
    }

    fn check_shared(self: RateLimiter, p: redis.Pool, key: str) -> result[RateCheck, str] {
        let dl = until_of(time.mono() + self.timeout);
        let mr = crypto.rand(16);
        guard let member = mr else let e = err_of(mr) {
            return err(e);
        }
        let cr = redis.acquire(p, dl);
        guard let conn = cr else let e = err_of(cr) {
            return err(e);
        }
        let window_us = self.window / 1000;
        if window_us < 1 {
            window_us = 1;
        }
        let rr = redis.evalsha(conn, rate_script(), ["zokor:rate:" + self.name + ":" + key],
                               [to_bytes(to_str(window_us)), to_bytes(to_str(self.limit)),
                                to_bytes(encoding.hex_encode(member))], dl);
        redis.release(p, conn);
        guard let reply = rr else let e = err_of(rr) {
            return err(e);
        }
        if len(reply.items) != 3 {
            return err("rate script: unexpected reply");
        }
        return ok(RateCheck {
            wait: reply.items[0].num * 1000,
            remaining: reply.items[1].num,
            reset: reply.items[2].num * 1000
        });
    }

    // The same, now.
    pub fn take(self: RateLimiter, key: str) -> int {
        return self.check(key).wait;
    }

    // How many client keys are being tracked.
    pub fn tracked(self: RateLimiter) -> int {
        let n = 0;
        for sh in self.shards {
            mutex_lock(sh.lock);
            n = n + len(sh.hits);
            mutex_unlock(sh.lock);
        }
        return n;
    }
}

// Drops every key whose newest request has left the window. Called
// with the limiter's lock held.
fn sweep_quiet(hits: map[str][int], floor: int) {
    let quiet: [str] = [];
    for k, ts in hits {
        if len(ts) == 0 || ts[len(ts) - 1] <= floor {
            push(quiet, k);
        }
    }
    for k in quiet {
        del(hits, k);
    }
}

// The body of a rate-limiting `before`: `none` to continue, or the
// registered `rate_limited` failure (429 unless re-registered) in the
// service's own envelope, with `Retry-After`. Either way the answer
// carries the RateLimit headers clients use to pace themselves
// (IETF draft-ietf-httpapi-ratelimit-headers, the widely deployed form):
//
//   RateLimit-Limit: 100        requests per window
//   RateLimit-Remaining: 42     left in the current window
//   RateLimit-Reset: 17         seconds until the next one frees up
//
// An empty key counts as the client "anonymous".
pub fn rate_limit[S](c: Ctx[S], l: RateLimiter, key: str) -> opt[http.Response] {
    let k = key;
    if len(k) == 0 {
        k = "anonymous";
    }
    let rc = l.check(k);
    let limit = to_str(l.limit);
    let reset = to_str(retry_after_secs(rc.reset));
    if rc.wait == 0 {
        c.add_header("ratelimit-limit", limit);
        c.add_header("ratelimit-remaining", to_str(rc.remaining));
        c.add_header("ratelimit-reset", reset);
        return none;
    }
    let resp = respond(c.errors, "rate_limited", c.request_id);
    return some(http.with_headers(resp, [
        "retry-after: " + to_str(retry_after_secs(rc.wait)),
        "ratelimit-limit: " + limit,
        "ratelimit-remaining: 0",
        "ratelimit-reset: " + reset
    ]));
}

// rate_limit keyed on the client's address: the socket's peer, or, behind
// a proxy listed in TRUSTED_PROXIES, the address that proxy forwarded. A
// client cannot pick its own key by sending a header, so it can neither
// escape its limit nor spend someone else's.
pub fn rate_limit_client[S](c: Ctx[S], l: RateLimiter) -> opt[http.Response] {
    return rate_limit(c, l, c.client_ip);
}
