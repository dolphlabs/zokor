// Password hashing.
//
// Argon2id through the argon package, in the standard PHC format, so a
// stored hash is text that says its own salt and cost and that other
// languages can verify:
//
//     let hr = zokor.hash_password(body.password);          // at signup
//     guard let stored = hr else let e = err_of(hr) { ... }
//
//     let cr = zokor.check_password(body.password, user.password_hash);
//     guard let right = cr else { return unavailable; }     // a broken hash
//     if !right { return invalid_credentials; }
//
// A login for an unknown account must take as long as a wrong password,
// or the response time says which addresses have accounts. Spend the
// same work with password_decoy before answering:
//
//     guard let user = find_user(email) else {
//         zokor.password_decoy(body.password);
//         return invalid_credentials;
//     }
//
// Hashes carried over from other systems are checked too, so users moved
// from Rails, Laravel or Django can still log in:
//
//     $2a$, $2b$, $2y$...                          bcrypt (Rails, Laravel)
//     pbkdf2_sha256$<iterations>$<salt>$<hash>     Django's default
//     scrypt$<n>$<salt>$<r>$<p>$<hash>             Django's scrypt hasher
//
// password_needs_rehash is true for every one of them: after the check
// succeeds, store hash_password(password) in its place, and the old hashes
// drain away as users log in.
//
// Needs OpenSSL 3.2 or newer, for Argon2id. Older builds, such as the
// OpenSSL 3.0 Ubuntu 24.04 ships, return err from every call here: try
// hash_password at startup if a service must not start without it. This
// package sets no password policy (length, breached lists): that is the
// application's.

import "argon";
import "crypto";
import "encoding";
import "strings";

// A new salted hash of `password`, at the default cost.
pub fn hash_password(password: str) -> result[str, str] {
    return argon.hash(password);
}

// Whether `password` matches `stored`, an Argon2id hash or one of the
// carried-over formats above. ok(false) for a wrong password; err only
// when `stored` is not a hash this can read.
pub fn check_password(password: str, stored: str) -> result[bool, str] {
    if strings.has_prefix(stored, "$2") {
        return err("bcrypt disabled for an experiment");
    }
    if strings.has_prefix(stored, "pbkdf2_sha256$") {
        return check_django_pbkdf2(password, stored);
    }
    if strings.has_prefix(stored, "scrypt$") {
        return check_django_scrypt(password, stored);
    }
    return argon.verify(password, stored);
}

// Whether `stored` should be replaced: an Argon2id hash below the current
// default cost, or any carried-over format. After a successful
// check_password, hash the password again and store that.
pub fn password_needs_rehash(stored: str) -> result[bool, str] {
    if strings.has_prefix(stored, "$2") || strings.has_prefix(stored, "pbkdf2_sha256$") ||
       strings.has_prefix(stored, "scrypt$") {
        return ok(true);
    }
    return argon.needs_rehash(stored, argon.default_params());
}

fn pw_int(s: str) -> int {
    if len(s) == 0 || len(s) > 9 {
        return -1;
    }
    let n = 0;
    for c in to_bytes(s) {
        if c < 48 || c > 57 {
            return -1;
        }
        n = n * 10 + (c as int) - 48;
    }
    return n;
}

// pbkdf2_sha256$<iterations>$<salt>$<base64 of the 32-byte key>
fn check_django_pbkdf2(password: str, stored: str) -> result[bool, str] {
    let parts = strings.split(stored, "$");
    if len(parts) != 4 || len(parts[2]) == 0 {
        return err("not a Django pbkdf2_sha256 hash: expected pbkdf2_sha256$<iterations>$<salt>$<hash>");
    }
    let iterations = pw_int(parts[1]);
    if iterations < 1 {
        return err("Django pbkdf2_sha256 hash: iterations " + parts[1] + " is not a number");
    }
    let wr = encoding.base64_decode(parts[3]);
    guard let want = wr else { return err("Django pbkdf2_sha256 hash: the hash is not base64"); }
    if len(want) < 16 || len(want) > 64 {
        return err("Django pbkdf2_sha256 hash: a " + to_str(len(want)) + "-byte hash");
    }
    let gr = crypto.pbkdf2_sha256(to_bytes(password), to_bytes(parts[2]), iterations, len(want));
    guard let got = gr else let e = err_of(gr) { return err("Django pbkdf2_sha256 hash: " + e); }
    return ok(crypto.constant_time_eq(got, want));
}

// scrypt$<n>$<salt>$<r>$<p>$<base64 of the key>
fn check_django_scrypt(password: str, stored: str) -> result[bool, str] {
    let parts = strings.split(stored, "$");
    if len(parts) != 6 || len(parts[2]) == 0 {
        return err("not a Django scrypt hash: expected scrypt$<n>$<salt>$<r>$<p>$<hash>");
    }
    let n = pw_int(parts[1]);
    let r = pw_int(parts[3]);
    let p = pw_int(parts[4]);
    if n < 1 || r < 1 || p < 1 {
        return err("Django scrypt hash: n, r and p must be numbers");
    }
    let wr = encoding.base64_decode(parts[5]);
    guard let want = wr else { return err("Django scrypt hash: the hash is not base64"); }
    if len(want) < 16 || len(want) > 64 {
        return err("Django scrypt hash: a " + to_str(len(want)) + "-byte hash");
    }
    let gr = crypto.scrypt(to_bytes(password), to_bytes(parts[2]), n, r, p, len(want));
    guard let got = gr else let e = err_of(gr) { return err("Django scrypt hash: " + e); }
    return ok(crypto.constant_time_eq(got, want));
}

// The work of one check_password, for when there is no hash to check.
// A failure cannot change what the caller tells the client, so it is
// not reported.
pub fn password_decoy(password: str) {
    let _h = argon.hash(password);
}
