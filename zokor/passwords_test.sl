import "time";

// Argon2id needs OpenSSL 3.2: these say so and pass where it is older,
// like the live database tests.
fn pw_usable(test: str) -> bool {
    let r = hash_password("probe");
    guard let _h = r else let e = err_of(r) {
        println("skip " + test + " (" + e + ")");
        return false;
    }
    return true;
}

fn test_password_round_trip_and_wrong_password() {
    if !pw_usable("test_password_round_trip_and_wrong_password") { return; }
    let stored = hash_password("correct horse") ?? "";
    assert(contains(stored, "$argon2id$"));
    assert(!contains(stored, "correct horse"));
    assert(check_password("correct horse", stored) ?? false);
    assert(!(check_password("wrong horse", stored) ?? true));
}

fn test_password_hashes_are_salted() {
    if !pw_usable("test_password_hashes_are_salted") { return; }
    assert((hash_password("same") ?? "a") != (hash_password("same") ?? "a"));
}

fn test_password_check_refuses_a_broken_hash_instead_of_saying_no() {
    if !pw_usable("test_password_check_refuses_a_broken_hash_instead_of_saying_no") { return; }
    let r = check_password("x", "not-a-hash");
    guard let _b = r else {
        return;
    }
    panic("a broken hash must be an error, not a wrong password");
}

fn test_password_rehash_is_needed_only_below_the_current_cost() {
    if !pw_usable("test_password_rehash_is_needed_only_below_the_current_cost") { return; }
    let stored = hash_password("x") ?? "";
    assert(!(password_needs_rehash(stored) ?? true));
    let weak = "$argon2id$v=19$m=8192,t=1,p=1$c2FsdHNhbHRzYWx0c2FsdA$" +
               "c2FsdHNhbHRzYWx0c2FsdHNhbHRzYWx0c2FsdHNhbHQ";
    assert(password_needs_rehash(weak) ?? false);
}

// The point of a decoy is that it costs what a real check costs.
fn test_password_decoy_takes_as_long_as_a_real_check() {
    if !pw_usable("test_password_decoy_takes_as_long_as_a_real_check") { return; }
    let stored = hash_password("x") ?? "";
    let t0 = time.mono();
    let _c = check_password("x", stored);
    let real = (time.mono() - t0) as int;
    let t1 = time.mono();
    password_decoy("x");
    let decoy = (time.mono() - t1) as int;
    assert(decoy * 3 > real);
}
