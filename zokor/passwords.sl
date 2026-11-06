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
// Needs OpenSSL 3.2 or newer, for Argon2id. Older builds, such as the
// OpenSSL 3.0 Ubuntu 24.04 ships, return err from every call here: try
// hash_password at startup if a service must not start without it. This
// package sets no password policy (length, breached lists): that is the
// application's.

import "argon";

// A new salted hash of `password`, at the default cost.
pub fn hash_password(password: str) -> result[str, str] {
    return argon.hash(password);
}

// Whether `password` matches `stored`. ok(false) for a wrong password;
// err only when `stored` is not a hash this can read.
pub fn check_password(password: str, stored: str) -> result[bool, str] {
    return argon.verify(password, stored);
}

// Whether `stored` is below the current default cost: after a successful
// check_password, hash the password again and store that.
pub fn password_needs_rehash(stored: str) -> result[bool, str] {
    return argon.needs_rehash(stored, argon.default_params());
}

// The work of one check_password, for when there is no hash to check.
// A failure cannot change what the caller tells the client, so it is
// not reported.
pub fn password_decoy(password: str) {
    let _h = argon.hash(password);
}
