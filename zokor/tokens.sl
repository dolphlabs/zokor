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
// The store is in memory and shared by every connection's task, so it
// is guarded by a mutex; a service that runs several processes needs a
// shared store (Redis) instead -- the shape of the calls stays the same.

import "crypto";
import "encoding";
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
        since_sweep: 0
    };
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
        return self.issue_at(subject, time.mono() as int);
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

    // How many tokens are held (expired ones count until swept).
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
