// Opaque bearer tokens.
//
// The token a login hands back should mean nothing to anyone who reads
// it: 256 bits from the OS's generator, hex, looked up server-side. That
// makes revoking one a map delete instead of a deny-list, and it is
// what `c.bearer()` already extracts:
//
//     let r = c.state.tokens.issue(user_id);       // at login
//     guard let user = zokor.bearer_subject(c, c.state.tokens) else {
//         return some(zokor.respond(c.errors, "unauthorized", c.request_id));
//     }
//
// new_token_store keeps tokens in this process, guarded by a mutex, so
// they end with it and other instances do not know them.
// token_store_redis takes the same calls and shares them. Redis holds only
// a SHA-256 of each token, so a dump of it holds no working credential. If
// Redis does not answer, a lookup finds nothing, so a request is refused
// rather than let through.

import "crypto";
import "encoding";
import "redis";
import "time";

pub gc struct TokenStore {
    // token -> the subject it was issued to (a user id, an account)
    subjects: map[str]str,
    // token -> time.mono nanoseconds it stops being valid; absent when
    // the store's ttl is 0 (tokens live until revoked)
    expires: map[str]int,
    ttl: int,
    lock: mutex,
    since_sweep: int,
    // Set by token_store_redis: the maps above stay empty.
    remote: opt[redis.Pool],
    // How long one call to Redis may take.
    timeout: int,
}

// `ttl_ns` is how long a token stays valid after it is issued, in
// nanoseconds; 0 means until it is revoked.
pub fn new_token_store(ttl_ns: int) -> TokenStore {
    let t = ttl_ns;
    if t < 0 {
        t = 0;
    }
    return TokenStore {
        subjects: {},
        expires: {},
        ttl: t,
        lock: make_mutex(),
        since_sweep: 0,
        remote: none,
        timeout: 2000000000
    };
}

// The same store in Redis, shared by every instance behind the balancer.
pub fn token_store_redis(p: redis.Pool, ttl_ns: int) -> TokenStore {
    let s = new_token_store(ttl_ns);
    s.remote = some(p);
    return s;
}

fn token_slot(token: str) -> bytes {
    return to_bytes("zokor:token:" + encoding.hex_encode(crypto.sha256(to_bytes(token))));
}

fn token_index(subject: str) -> bytes {
    return to_bytes("zokor:token_subject:" + subject);
}

// 32 random bytes as 64 lowercase hex characters.
pub fn new_token() -> result[str, str] {
    let r = crypto.rand(32);
    guard let b = r else let e = err_of(r) {
        return err("no randomness for a token: " + e);
    }
    return ok(encoding.hex_encode(b));
}

impl TokenStore {
    // A new token for `subject`. Fails only when the OS refuses
    // randomness, which a login should answer with 500, not a weak token.
    pub fn issue(self: TokenStore, subject: str) -> result[str, str] {
        if let p = self.remote {
            return self.issue_shared(p, subject);
        }
        return self.issue_at(subject, time.mono() as int);
    }

    fn store_deadline(self: TokenStore) -> until {
        return until_of(time.mono() + self.timeout);
    }

    fn issue_shared(self: TokenStore, p: redis.Pool, subject: str) -> result[str, str] {
        let r = new_token();
        guard let tok = r else let e = err_of(r) {
            return err(e);
        }
        let dl = self.store_deadline();
        let slot = token_slot(tok);
        let cmd = [to_bytes("SET"), slot, to_bytes(subject)];
        if self.ttl > 0 {
            push(cmd, to_bytes("PX"));
            push(cmd, to_bytes(to_str(self.ttl / 1000000 + 1)));
        }
        let sr = redis.pool_do(p, cmd, dl);
        guard let _s = sr else let e = err_of(sr) {
            return err("token store: " + e);
        }
        let ar = redis.pool_do(p, [to_bytes("SADD"), token_index(subject), slot], dl);
        guard let _a = ar else let e = err_of(ar) {
            return err("token store: " + e);
        }
        if self.ttl > 0 {
            let xr = redis.pool_do(p, [to_bytes("PEXPIRE"), token_index(subject),
                                       to_bytes(to_str(self.ttl / 1000000 + 1))], dl);
            guard let _x = xr else let e = err_of(xr) {
                return err("token store: " + e);
            }
        }
        return ok(tok);
    }

    pub fn issue_at(self: TokenStore, subject: str, now: int) -> result[str, str] {
        let r = new_token();
        guard let tok = r else let e = err_of(r) {
            return err(e);
        }
        mutex_lock(self.lock);
        self.subjects[tok] = subject;
        if self.ttl > 0 {
            self.expires[tok] = now + self.ttl;
        }
        self.since_sweep = self.since_sweep + 1;
        if self.since_sweep >= 1024 {
            self.since_sweep = 0;
            sweep_expired(self, now);
        }
        mutex_unlock(self.lock);
        return ok(tok);
    }

    // The subject a live token was issued to; none for an unknown,
    // revoked or expired token (an expired one is dropped on the way).
    pub fn lookup(self: TokenStore, token: str) -> opt[str] {
        if let p = self.remote {
            if len(token) == 0 {
                return none;
            }
            let gr = redis.pool_do(p, [to_bytes("GET"), token_slot(token)],
                                   self.store_deadline());
            guard let got = gr else {
                return none;
            }
            guard let raw = got.bulk else {
                return none;
            }
            return some(to_str(raw));
        }
        return self.lookup_at(token, time.mono() as int);
    }

    pub fn lookup_at(self: TokenStore, token: str, now: int) -> opt[str] {
        if len(token) == 0 {
            return none;
        }
        let found = "";
        let live = false;
        mutex_lock(self.lock);
        if has(self.subjects, token) {
            live = true;
            if has(self.expires, token) && self.expires[token] <= now {
                live = false;
                del(self.subjects, token);
                del(self.expires, token);
            }
            if live {
                found = self.subjects[token];
            }
        }
        mutex_unlock(self.lock);
        if !live {
            return none;
        }
        return some(found);
    }

    // Ends one token (logout). True when it was live.
    pub fn revoke(self: TokenStore, token: str) -> bool {
        if let p = self.remote {
            return self.revoke_shared(p, token);
        }
        let was = false;
        mutex_lock(self.lock);
        if has(self.subjects, token) {
            was = true;
            del(self.subjects, token);
        }
        if has(self.expires, token) {
            del(self.expires, token);
        }
        mutex_unlock(self.lock);
        return was;
    }

    // Ends every token issued to `subject` ("log out everywhere", a
    // password change). Returns how many were revoked.
    pub fn revoke_subject(self: TokenStore, subject: str) -> int {
        if let p = self.remote {
            return self.revoke_subject_shared(p, subject);
        }
        let gone: [str] = [];
        mutex_lock(self.lock);
        for tok, who in self.subjects {
            if who == subject {
                push(gone, tok);
            }
        }
        for tok in gone {
            del(self.subjects, tok);
            if has(self.expires, tok) {
                del(self.expires, tok);
            }
        }
        mutex_unlock(self.lock);
        return len(gone);
    }

    // Whether a token was live and has gone. A failed call answers
    // false: the token may still be live, which a caller must not hide.
    fn revoke_shared(self: TokenStore, p: redis.Pool, token: str) -> bool {
        let dl = self.store_deadline();
        let slot = token_slot(token);
        let gr = redis.pool_do(p, [to_bytes("GET"), slot], dl);
        guard let got = gr else {
            return false;
        }
        guard let raw = got.bulk else {
            return false;
        }
        let dr = redis.pool_do(p, [to_bytes("DEL"), slot], dl);
        guard let gone = dr else {
            return false;
        }
        let _i = redis.pool_do(p, [to_bytes("SREM"), token_index(to_str(raw)), slot], dl);
        return gone.num == 1;
    }

    fn revoke_subject_shared(self: TokenStore, p: redis.Pool, subject: str) -> int {
        let dl = self.store_deadline();
        let mr = redis.pool_do(p, [to_bytes("SMEMBERS"), token_index(subject)], dl);
        guard let members = mr else {
            return 0;
        }
        let ended = 0;
        for m in members.items {
            if let slot = m.bulk {
                let dr = redis.pool_do(p, [to_bytes("DEL"), slot], dl);
                if let d = dr {
                    ended = ended + d.num;
                }
            }
        }
        let _x = redis.pool_do(p, [to_bytes("DEL"), token_index(subject)], dl);
        return ended;
    }

    // How many tokens this process holds (expired ones count until
    // swept). Always 0 on Redis, which it does not ask.
    pub fn count(self: TokenStore) -> int {
        mutex_lock(self.lock);
        let n = len(self.subjects);
        mutex_unlock(self.lock);
        return n;
    }
}

// Drops expired tokens. Called with the store's lock held.
fn sweep_expired(s: TokenStore, now: int) {
    let dead: [str] = [];
    for tok, at in s.expires {
        if at <= now {
            push(dead, tok);
        }
    }
    for tok in dead {
        del(s.expires, tok);
        if has(s.subjects, tok) {
            del(s.subjects, tok);
        }
    }
}

// The subject behind the request's `Authorization: Bearer <token>`, or
// none when the header is missing or the token is not live.
pub fn bearer_subject[S](c: Ctx[S], store: TokenStore) -> opt[str] {
    return store.lookup(c.bearer());
}
