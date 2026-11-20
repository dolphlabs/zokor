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

// Hashes made elsewhere: htpasswd's bcrypt, and Python's hashlib in
// Django's two formats.
fn test_password_checks_hashes_from_other_systems() {
    let hashes = [
        "$2y$04$Fm.6qJ/hc1KL12qfk5r5Ou1WLcS/Va6Op.Whay8xInoUti2ZIfqQC",
        "pbkdf2_sha256$1000$seasalt123$KuEnssc6S4MzVSS8Tu48m1RDSrTAn7j3CfgvvjkvfWA=",
        "scrypt$1024$NaClSalt$8$1$3+AKEn+QQbfs7YP78DSMS6l4KSrl6u/UhL0QeqFeMfL1jAl7PNpU3vT970ttPj99WO9FgIEMfuaL23MriZ82Cw=="
    ];
    for h in hashes {
        assert(check_password("correct horse", h) ?? false, h);
        assert(!(check_password("wrong horse", h) ?? true), h);
        assert(password_needs_rehash(h) ?? false, h);
    }
    for broken in ["$2y$04$short", "pbkdf2_sha256$x$salt$aGFzaA==", "pbkdf2_sha256$1000$salt$!!!",
                   "scrypt$1000$salt$8$1$aGFzaGhhc2hoYXNoaGFzaA==", "scrypt$1024$salt$8$1"] {
        let r = check_password("correct horse", broken);
        guard let _b = r else { continue; }
        panic("a broken hash must be an error: " + broken);
    }
}
