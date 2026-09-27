import "redis";
import "time";

// cfg_of/says are config_test.sl's own helpers -- same package, no
// need to redefine them (slang errors on a duplicate function name
// across files in one package, the same as it would within one file).

fn test_no_redis_url_is_not_a_problem() {
    let c = cfg_of("SERVICE_NAME=api\n");
    assert(!has_redis(c));
    let r = redis_from_config(c);
    guard let _p = r else let e = err_of(r) {
        assert(e == "REDIS_URL is not set");
        assert(len(problems(c)) == 0);
        return;
    }
    panic("expected err with no REDIS_URL set");
}

fn test_valid_url_builds_a_pool_without_connecting() {
    // new_pool/redis_from_config connect nothing until the first
    // acquire, so this passes with no server listening at all -- the
    // point of testing it here rather than only in the live test
    // below, which a sandbox with no Redis (this project's own CI
    // containers included) skips.
    let c = cfg_of("REDIS_URL=redis://127.0.0.1:6379/0\n");
    assert(has_redis(c));
    let r = redis_from_config(c);
    guard let p = r else let e = err_of(r) {
        panic("expected a pool: " + e);
    }
    assert(len(problems(c)) == 0);
    redis_close(p);
}

fn test_malformed_url_is_a_config_problem() {
    let c = cfg_of("REDIS_URL=not-a-url\n");
    let r = redis_from_config(c);
    guard let _p = r else let e = err_of(r) {
        assert(len(problems(c)) == 1);
        assert(says(problems(c)[0].reason, "must be a connection URL"));
        return;
    }
    panic("expected a malformed REDIS_URL to be rejected");
}

fn test_pool_size_must_be_positive() {
    let c = cfg_of("REDIS_URL=redis://127.0.0.1:6379/0\nREDIS_POOL_SIZE=0\n");
    let r = redis_from_config(c);
    guard let _p = r else let e = err_of(r) {
        assert(e == "REDIS_POOL_SIZE must be at least 1");
        return;
    }
    panic("expected REDIS_POOL_SIZE=0 to be rejected");
}

// A real round trip against a real server, when one is reachable.
// db 15 (not the default 0) and a namespaced key: this is deliberately
// runnable against a developer's own local Redis, which may hold real
// data on db 0, not just a throwaway test instance -- so this claims
// its own database and cleans up the one key it touches. Skips (not
// fails) when nothing answers on 127.0.0.1:6379 -- this project's own
// CI containers have no Redis, and `make check` has to stay green
// there the same as anywhere else.
fn test_live_roundtrip() {
    let c = cfg_of("REDIS_URL=redis://127.0.0.1:6379/15\n");
    let pr = redis_from_config(c);
    guard let pool = pr else {
        println("skip live_roundtrip (bad REDIS_URL)");
        return;
    }
    let dl = until_of(time.mono() + 1000000000);
    let cr = redis.acquire(pool, dl);
    guard let conn = cr else {
        println("skip live_roundtrip (no Redis reachable on 127.0.0.1:6379)");
        return;
    }
    let key = "zokor:redis_test:roundtrip";
    let sr = redis.set(conn, key, to_bytes("hello"), dl);
    guard let _sok = sr else let e = err_of(sr) {
        panic("set failed: " + e);
    }
    let gr = redis.get(conn, key, dl);
    guard let got = gr else let e = err_of(gr) {
        panic("get failed: " + e);
    }
    guard let v = got else {
        panic("expected the key to exist");
    }
    assert(to_str(v) == "hello");
    let dr = redis.del_keys(conn, [key], dl);
    guard let _dn = dr else let e = err_of(dr) {
        panic("cleanup del failed: " + e);
    }
    redis.release(pool, conn);
    redis_close(pool);
}
