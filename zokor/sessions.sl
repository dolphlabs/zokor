// Browser sessions: a login that lives on the server.
//
// The cookie holds one random token and nothing else; who it belongs to
// is looked up here, so logging someone out takes effect at once, which a
// signed cookie cannot do.
//
//     let ss = zokor.sessions_in_memory();          // one instance
//     let ss = zokor.sessions_redis(redis_pool);    // shared, many
//
//     fn login(c: zokor.Ctx[App]) -> http.Response {
//         ... check the password ...
//         let sr = zokor.session_start(c, c.state.sessions, user.id);
//         guard let s = sr else { return zokor.respond(c.errors, "unavailable", c.request_id); }
//         return zokor.session_cookie(zokor.ok_json("{}"), c.state.sessions, s) ?? ...;
//     }
//
//     fn me(c: zokor.Ctx[App]) -> http.Response {
//         let r = zokor.session_require(c, c.state.sessions);
//         guard let s = r else let denied = err_of(r) { return denied; }
//         return ... s.subject ...;
//     }
//
// Why it is built this way:
//   - Only a SHA-256 of the token is stored, so whoever reads the store
//     (a Redis dump, a backup) gets no working login. The token has 256
//     bits of entropy, so a fast hash is enough.
//   - session_start always issues a new token and ends the one the
//     request came with, so a token planted before login (session
//     fixation) is worth nothing after it.
//   - Both limits are enforced here, not left to the cookie: `idle_ttl`
//     since the last request and `absolute_ttl` since login, which no
//     amount of activity extends, so a stolen token does not live forever.
//   - The cookie defaults to __Host-sid: Secure, HttpOnly, SameSite=Lax,
//     host-only, and a subdomain cannot overwrite it. For plain http in
//     development, set ss.cookie.name = "sid"; ss.cookie.secure = false.
//   - A store that is down fails closed: session_require answers 503,
//     never lets a request through.
//
// Two requests that both save a session race, and the last save wins, so
// keep a counter that matters in your database rather than here. A session
// is for who someone is, not for their data.

import "crypto";
import "encoding";
import "http";
import "json";
import "redis";
import "strings";
import "time";
import "timez";

// What is kept for a session, as JSON, under the token's hash.
struct StoredSession {
    subject: str,
    data: map[str]str,
    csrf: str,
    created: int,
    seen: int,
}

gc struct LocalSession {
    text: str,
    subject: str,
    expires: int,
}

pub gc struct Session {
    // Who logged in: what you passed to session_start.
    subject: str,
    // Send this to your pages; see csrf_token_ok.
    csrf: str,
    // Unix nanoseconds of the login.
    created: int,
    data: map[str]str,
    seen: int,
    key: str,
    // The cookie's value, only on the request that started the session:
    // it exists nowhere else.
    token: str,
}

impl Session {
    // The value saved under `key`, "" when there is none.
    pub fn get(self: Session, key: str) -> str {
        if has(self.data, key) {
            return self.data[key];
        }
        return "";
    }

    // Sets a value; `sessions.save` stores it.
    pub fn set(self: Session, key: str, value: str) -> int {
        self.data[key] = value;
        return len(self.data);
    }

    pub fn remove(self: Session, key: str) -> bool {
        if has(self.data, key) {
            del(self.data, key);
            return true;
        }
        return false;
    }

    // Whether `token` is this session's CSRF token, in constant time.
    pub fn csrf_matches(self: Session, token: str) -> bool {
        return len(token) > 0 && constant_time_equal(to_bytes(self.csrf), to_bytes(token));
    }
}

pub gc struct Sessions {
    // Ends a session this long after its last request.
    idle_ttl: int,
    // Ends a session this long after login, however active it is.
    absolute_ttl: int,
    // The attributes of the cookie; the value is filled in. Change these
    // rather than the cookie session_cookie returns.
    cookie: Cookie,
    // Where now comes from: a fixed clock in tests.
    clock: timez.Clock,
    // How long one call to the store may take.
    timeout: int,
    remote: opt[redis.Pool],
    local: map[str]LocalSession,
    by_subject: map[str]map[str]bool,
    lock: mutex,
    since_sweep: int,
}

fn sessions_defaults(remote: opt[redis.Pool]) -> Sessions {
    return Sessions {
        idle_ttl: 2 * timez.HOUR,
        absolute_ttl: 24 * timez.HOUR,
        cookie: new_cookie("__Host-sid", ""),
        clock: timez.system_clock(),
        timeout: 2 * timez.SECOND,
        remote: remote,
        local: {},
        by_subject: {},
        lock: make_mutex(),
        since_sweep: 0
    };
}

// Sessions kept in this process: right for one instance, and every login
// ends with it.
pub fn sessions_in_memory() -> Sessions {
    return sessions_defaults(none);
}

// Sessions kept in Redis, shared by every instance behind the balancer.
pub fn sessions_redis(p: redis.Pool) -> Sessions {
    return sessions_defaults(some(p));
}

fn session_key(token: str) -> str {
    return encoding.hex_encode(crypto.sha256(to_bytes(token)));
}

// What new_token makes: 64 lowercase hex characters. Anything else cannot
// be a session, and is refused before it costs a lookup.
fn session_token_ok(t: str) -> bool {
    if len(t) != 64 {
        return false;
    }
    for b in to_bytes(t) {
        let x = b as int;
        if !((x >= 0x30 && x <= 0x39) || (x >= 0x61 && x <= 0x66)) {
            return false;
        }
    }
    return true;
}

fn remote_slot(key: str) -> bytes {
    return to_bytes("zokor:session:" + key);
}

fn remote_index(subject: str) -> bytes {
    return to_bytes("zokor:session_subject:" + subject);
}

fn sweep_every() -> int {
    return 256;
}

impl Sessions {
    fn store_deadline(self: Sessions) -> until {
        return until_of(time.mono() + self.timeout);
    }

    fn now_ns(self: Sessions) -> int {
        return self.clock.now().unix_nano();
    }

    // Time left before `s` must end, whichever limit comes first.
    fn time_left(self: Sessions, s: Session, now: int) -> int {
        let idle = s.seen + self.idle_ttl - now;
        let absolute = s.created + self.absolute_ttl - now;
        if absolute < idle {
            return absolute;
        }
        return idle;
    }

    // Drops what has expired; under the lock.
    fn sweep_local(self: Sessions, now: int) {
        let gone: [str] = [];
        for key, held in self.local {
            if held.expires <= now {
                push(gone, key);
            }
        }
        for key in gone {
            self.forget_local(key);
        }
    }

    // Under the lock.
    fn forget_local(self: Sessions, key: str) {
        if !has(self.local, key) {
            return;
        }
        let subject = self.local[key].subject;
        del(self.local, key);
        if has(self.by_subject, subject) {
            let held = self.by_subject[subject];
            del(held, key);
            if len(held) == 0 {
                del(self.by_subject, subject);
            }
        }
    }

    fn put(self: Sessions, s: Session, now: int) -> result[int, str] {
        let left = self.time_left(s, now);
        if left <= 0 {
            return err("the session has expired");
        }
        let text = json.encode(StoredSession {
            subject: s.subject, data: s.data, csrf: s.csrf, created: s.created, seen: s.seen
        });
        if let p = self.remote {
            let dl = self.store_deadline();
            let ms = left / timez.MILLISECOND;
            if ms < 1 {
                ms = 1;
            }
            let sr = redis.pool_do(p, [to_bytes("SET"), remote_slot(s.key), to_bytes(text),
                                       to_bytes("PX"), to_bytes(to_str(ms))], dl);
            guard let _set = sr else let e = err_of(sr) {
                return err("session store: " + e);
            }
            return ok(0);
        }
        mutex_lock(self.lock);
        self.local[s.key] = LocalSession { text: text, subject: s.subject, expires: now + left };
        if !has(self.by_subject, s.subject) {
            let held: map[str]bool = {};
            self.by_subject[s.subject] = held;
        }
        let held = self.by_subject[s.subject];
        held[s.key] = true;
        self.since_sweep = self.since_sweep + 1;
        if self.since_sweep >= sweep_every() {
            self.since_sweep = 0;
            self.sweep_local(now);
        }
        mutex_unlock(self.lock);
        return ok(0);
    }

    // Remembers a new session under its subject, for end_all. Redis keeps
    // the set no longer than the longest session in it can live.
    fn index(self: Sessions, s: Session) -> result[int, str] {
        guard let p = self.remote else {
            return ok(0);
        }
        let dl = self.store_deadline();
        let ar = redis.pool_do(p, [to_bytes("SADD"), remote_index(s.subject), to_bytes(s.key)], dl);
        guard let _a = ar else let e = err_of(ar) {
            return err("session store: " + e);
        }
        let xr = redis.pool_do(p, [to_bytes("PEXPIRE"), remote_index(s.subject),
                                   to_bytes(to_str(self.absolute_ttl / timez.MILLISECOND))], dl);
        guard let _x = xr else let e = err_of(xr) {
            return err("session store: " + e);
        }
        return ok(0);
    }

    fn fetch(self: Sessions, key: str, now: int) -> result[opt[str], str] {
        if let p = self.remote {
            let gr = redis.pool_do(p, [to_bytes("GET"), remote_slot(key)], self.store_deadline());
            guard let got = gr else let e = err_of(gr) {
                return err("session store: " + e);
            }
            guard let raw = got.bulk else {
                return ok(none);
            }
            return ok(some(to_str(raw)));
        }
        mutex_lock(self.lock);
        if !has(self.local, key) {
            mutex_unlock(self.lock);
            return ok(none);
        }
        let held = self.local[key];
        if held.expires <= now {
            self.forget_local(key);
            mutex_unlock(self.lock);
            return ok(none);
        }
        mutex_unlock(self.lock);
        return ok(some(held.text));
    }

    fn forget(self: Sessions, key: str, subject: str) -> result[int, str] {
        if let p = self.remote {
            let dl = self.store_deadline();
            let dr = redis.pool_do(p, [to_bytes("DEL"), remote_slot(key)], dl);
            guard let _d = dr else let e = err_of(dr) {
                return err("session store: " + e);
            }
            let sr = redis.pool_do(p, [to_bytes("SREM"), remote_index(subject), to_bytes(key)], dl);
            guard let _s = sr else let e = err_of(sr) {
                return err("session store: " + e);
            }
            return ok(0);
        }
        mutex_lock(self.lock);
        self.forget_local(key);
        mutex_unlock(self.lock);
        return ok(0);
    }

    // The session this token names, if it is still good. A session is
    // written back only once a tenth of idle_ttl has passed, so a burst of
    // requests is not a burst of writes; that much is all its idle time
    // can be short by.
    fn load(self: Sessions, token: str) -> result[opt[Session], str] {
        if !session_token_ok(token) {
            return ok(none);
        }
        let key = session_key(token);
        let now = self.now_ns();
        let fr = self.fetch(key, now);
        guard let found = fr else let e = err_of(fr) {
            return err(e);
        }
        guard let text = found else {
            return ok(none);
        }
        let dr: result[StoredSession, str] = json.decode(text);
        guard let st = dr else {
            // Not ours to interpret, and never to be trusted as a login.
            return ok(none);
        }
        let s = Session {
            subject: st.subject, csrf: st.csrf, created: st.created, data: st.data,
            seen: st.seen, key: key, token: ""
        };
        if self.time_left(s, now) <= 0 {
            let fg = self.forget(key, s.subject);
            guard let _f = fg else let e = err_of(fg) {
                return err(e);
            }
            return ok(none);
        }
        if now - s.seen >= self.idle_ttl / 10 {
            s.seen = now;
            // A failed touch costs idle time, not this request.
            let _p = self.put(s, now);
        }
        return ok(some(s));
    }

    // Stores what has changed in `s`.
    pub fn save(self: Sessions, s: Session) -> result[int, str] {
        return self.put(s, self.now_ns());
    }

    // Ends every session of `subject`, on every device: after a password
    // change, or to lock an account. Returns how many ended.
    pub fn end_all(self: Sessions, subject: str) -> result[int, str] {
        if let p = self.remote {
            let dl = self.store_deadline();
            let mr = redis.pool_do(p, [to_bytes("SMEMBERS"), remote_index(subject)], dl);
            guard let members = mr else let e = err_of(mr) {
                return err("session store: " + e);
            }
            let ended = 0;
            for m in members.items {
                guard let raw = m.bulk else {
                    continue;
                }
                let dr = redis.pool_do(p, [to_bytes("DEL"), remote_slot(to_str(raw))], dl);
                guard let _d = dr else let e = err_of(dr) {
                    return err("session store: " + e);
                }
                ended = ended + 1;
            }
            let xr = redis.pool_do(p, [to_bytes("DEL"), remote_index(subject)], dl);
            guard let _x = xr else let e = err_of(xr) {
                return err("session store: " + e);
            }
            return ok(ended);
        }
        mutex_lock(self.lock);
        let ended = 0;
        if has(self.by_subject, subject) {
            // A copy: forget_local changes the map it would walk.
            let held: [str] = [];
            for key, _yes in self.by_subject[subject] {
                push(held, key);
            }
            for key in held {
                self.forget_local(key);
                ended = ended + 1;
            }
        }
        mutex_unlock(self.lock);
        return ok(ended);
    }

    // The session cookie's attributes with `value`, copied so one
    // request's cookie is never another's.
    fn cookie_with(self: Sessions, value: str) -> Cookie {
        let t = self.cookie;
        return Cookie {
            name: t.name, value: value, path: t.path, domain: t.domain, max_age: t.max_age,
            expires: t.expires, secure: t.secure, http_only: t.http_only,
            same_site: t.same_site, partitioned: t.partitioned
        };
    }
}

// A session for `subject`, in place of any the request came with. Call it
// at login, and again whenever privileges change.
pub fn session_start[S](c: Ctx[S], ss: Sessions, subject: str) -> result[Session, str] {
    if len(subject) == 0 {
        return err("a session needs a subject");
    }
    let lr = ss.load(c.cookie(ss.cookie.name));
    guard let before = lr else let e = err_of(lr) {
        return err(e);
    }
    if let old = before {
        let fg = ss.forget(old.key, old.subject);
        guard let _f = fg else let e = err_of(fg) {
            return err(e);
        }
    }
    let tr = new_token();
    guard let token = tr else let e = err_of(tr) {
        return err(e);
    }
    let cr = new_token();
    guard let csrf = cr else let e = err_of(cr) {
        return err(e);
    }
    let now = ss.now_ns();
    let data: map[str]str = {};
    let s = Session {
        subject: subject, csrf: csrf, created: now, data: data, seen: now,
        key: session_key(token), token: token
    };
    let pr = ss.put(s, now);
    guard let _p = pr else let e = err_of(pr) {
        return err(e);
    }
    let ir = ss.index(s);
    guard let _i = ir else let e = err_of(ir) {
        return err(e);
    }
    return ok(s);
}

// Puts the cookie for a session just started on `resp`.
pub fn session_cookie(resp: http.Response, ss: Sessions, s: Session) -> result[http.Response, str] {
    if len(s.token) == 0 {
        return err("only the request that started a session can set its cookie");
    }
    return set_cookie(resp, ss.cookie_with(s.token));
}

// The request's session, none when it has no good one. err when the
// store cannot say: treat that as a failure, not as logged out.
pub fn session_of[S](c: Ctx[S], ss: Sessions) -> result[opt[Session], str] {
    return ss.load(c.cookie(ss.cookie.name));
}

// The request's session, or the response to send: 401 without one, 503
// when the store is down.
pub fn session_require[S](c: Ctx[S], ss: Sessions) -> result[Session, http.Response] {
    let r = session_of(c, ss);
    guard let found = r else {
        return err(respond(c.errors, "unavailable", c.request_id));
    }
    guard let s = found else {
        return err(respond(c.errors, "unauthorized", c.request_id));
    }
    return ok(s);
}

// Logs the request out: ends its session and clears the cookie on `resp`.
pub fn session_end[S](c: Ctx[S], ss: Sessions, resp: http.Response) -> result[http.Response, str] {
    let r = session_of(c, ss);
    guard let found = r else let e = err_of(r) {
        return err(e);
    }
    if let s = found {
        let fg = ss.forget(s.key, s.subject);
        guard let _f = fg else let e = err_of(fg) {
            return err(e);
        }
    }
    let gone = ss.cookie_with("");
    gone.max_age = 0;
    gone.expires = some(timez.unix(0));
    return set_cookie(resp, gone);
}

// Whether the request's x-csrf-token header is this session's token: the
// second layer csrf.sl describes.
pub fn csrf_token_ok[S](c: Ctx[S], s: Session) -> bool {
    return s.csrf_matches(c.header("x-csrf-token"));
}
