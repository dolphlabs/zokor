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
// One limiter is shared by every connection's task, so it is guarded
// by a mutex. Memory is bounded by the clients seen in the last window:
// keys that went quiet are swept every `sweep_every` requests.

import "http";
import "time";

pub gc struct RateLimiter {
    limit: int,
    window: int,
    // Per client key: the times (time.mono nanoseconds) of the requests
    // still inside the window, oldest first.
    hits: map[str][int],
    lock: mutex,
    since_sweep: int,
    sweep_every: int,
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
    return RateLimiter {
        limit: n,
        window: w,
        hits: {},
        lock: make_mutex(),
        since_sweep: 0,
        sweep_every: 1024
    };
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

impl RateLimiter {
    // Counts one request for `key` at `now` (time.mono nanoseconds).
    // 0 means allowed and counted; otherwise it was refused, not
    // counted, and the result is the nanoseconds until a slot frees.
    // The clock is a parameter so tests need no sleeps.
    pub fn take_at(self: RateLimiter, key: str, now: int) -> int {
        let floor = now - self.window;
        let wait = 0;
        mutex_lock(self.lock);
        let kept: [int] = [];
        if has(self.hits, key) {
            let old = self.hits[key];
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
        self.hits[key] = kept;
        self.since_sweep = self.since_sweep + 1;
        if self.since_sweep >= self.sweep_every {
            self.since_sweep = 0;
            sweep_quiet(self.hits, floor);
        }
        mutex_unlock(self.lock);
        return wait;
    }

    // The same, now.
    pub fn take(self: RateLimiter, key: str) -> int {
        return self.take_at(key, time.mono() as int);
    }

    // How many client keys are being tracked.
    pub fn tracked(self: RateLimiter) -> int {
        mutex_lock(self.lock);
        let n = len(self.hits);
        mutex_unlock(self.lock);
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
// service's own envelope, with `Retry-After`. An empty key counts as
// the client "anonymous".
pub fn rate_limit[S](c: Ctx[S], l: RateLimiter, key: str) -> opt[http.Response] {
    let k = key;
    if len(k) == 0 {
        k = "anonymous";
    }
    let wait = l.take(k);
    if wait == 0 {
        return none;
    }
    let resp = respond(c.errors, "rate_limited", c.request_id);
    return some(http.with_header(resp, "retry-after", to_str(retry_after_secs(wait))));
}
