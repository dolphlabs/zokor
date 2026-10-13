import "http";
import "pg";
import "proc";
import "strings";
import "time";

struct PgMeta {
    tags: [str],
}

struct PgItem {
    id: int,
    name: str,
    note: opt[str],
    active: bool,
    price: float,
    meta: opt[PgMeta],
    created: str,
}

struct PgName {
    name: str,
}

struct PgText {
    price: str,
}

fn pg_dl() -> until {
    return until_of(time.mono() + 5000000000);
}

// The live database, or none when ZOKOR_TEST_DATABASE_URL is unset or
// unreachable: these tests then say so and pass, like redis_test.
fn pg_live(test: str) -> opt[pg.Pool] {
    let url = proc.getenv("ZOKOR_TEST_DATABASE_URL") ?? "";
    if len(url) == 0 {
        println("skip " + test + " (ZOKOR_TEST_DATABASE_URL is not set)");
        return none;
    }
    let pr = pg_from_config(cfg_of("DATABASE_URL=" + url + "\nDB_POOL_SIZE=2\n"));
    guard let p = pr else let e = err_of(pr) {
        panic("pool: " + e);
    }
    let ping = pg.pool_exec(p, "select 1", pg_dl());
    guard let _ok = ping else let e = err_of(ping) {
        println("skip " + test + " (database unreachable: " + e + ")");
        return none;
    }
    return some(p);
}

fn pg_must(p: pg.Pool, sql: str) {
    let r = pg.pool_exec(p, sql, pg_dl());
    guard let _n = r else let e = err_of(r) {
        panic(sql + ": " + e);
    }
}

fn test_db_failure_maps_sqlstates_without_leaking_the_message() {
    let reg = new_registry();
    let unique = db_failure(reg, "ERROR: duplicate key value violates unique constraint \"users_email_key\" (SQLSTATE 23505)", "r1");
    assert(resp_status(unique) == 409 && resp_error_code(unique) == "already_exists");
    assert(!strings.contains(resp_text(unique), "users_email_key"), "the constraint name stays on the server");
    assert(resp_status(db_failure(reg, "x (SQLSTATE 23503)", "")) == 409);
    assert(resp_status(db_failure(reg, "x (SQLSTATE 23502)", "")) == 422);
    assert(resp_status(db_failure(reg, "x (SQLSTATE 22P02)", "")) == 422);
    assert(resp_status(db_failure(reg, "x (SQLSTATE 40001)", "")) == 503);
    assert(resp_status(db_failure(reg, "timeout", "")) == 503);
    assert(resp_status(db_failure(reg, "connection refused", "")) == 500);
    assert(is_unique_violation("x (SQLSTATE 23505)") && !is_unique_violation("x"));
}

fn test_pg_from_config() {
    let none_set = pg_from_config(cfg_of(""));
    guard let _p = none_set else let e = err_of(none_set) {
        assert(strings.contains(e, "DATABASE_URL"), e);
        assert(!has_postgres(cfg_of("")));
        assert(has_postgres(cfg_of("DATABASE_URL=postgres://u:p@127.0.0.1:5432/d\n")));
        let small = pg_from_config(cfg_of("DATABASE_URL=postgres://u:p@127.0.0.1:5432/d\nDB_POOL_SIZE=0\n"));
        guard let _q = small else { return; }
        panic("a pool of 0 was accepted");
    }
    panic("a pool was built with no DATABASE_URL");
}

fn test_numbers_json_cannot_hold_become_strings() {
    assert(json_number_ok("3.25") && json_number_ok("-7"));
    assert(!json_number_ok("NaN") && !json_number_ok("Infinity") && !json_number_ok(""));
}

fn test_live_rows_map_by_name_into_structs() {
    guard let p = pg_live("live_rows_map_by_name_into_structs") else { return; }
    pg_must(p, "drop table if exists zokor_t_items");
    pg_must(p, "create table zokor_t_items (id bigint primary key, name text not null, " +
               "note text, active bool not null, price numeric not null, meta jsonb not null, " +
               "created timestamptz not null default '2026-01-02T03:04:05Z', extra int)");
    pg_must(p, "insert into zokor_t_items (id, name, note, active, price, meta) values " +
               "(1, 'tea \"green\"', null, true, 3.50, '{\"tags\":[\"hot\"]}'), " +
               "(2, 'coffee', 'strong', false, 'NaN', '{}')");
    let r: result[[PgItem], str] = query_all(p,
        "select id, name, note, active, price::float8 as price, meta, created::text as created, extra " +
        "from zokor_t_items where id = $1", [pg.arg_int(1)], pg_dl());
    guard let items = r else let e = err_of(r) { panic(e); }
    assert(len(items) == 1);
    let a = items[0];
    assert(a.id == 1 && a.name == "tea \"green\"" && a.active && a.price == 3.5);
    guard let _n = a.note else {
        guard let meta = a.meta else { panic("jsonb did not decode"); }
        assert(meta.tags[0] == "hot", "a jsonb column decodes into a nested struct");
        assert(strings.has_prefix(a.created, "2026-01-02"), a.created);
        let one: result[opt[PgName], str] = query_one(p,
            "select name from zokor_t_items where id = $1", [pg.arg_int(2)], pg_dl());
        guard let found = one else let e = err_of(one) { panic(e); }
        guard let nm = found else { panic("row 2 missing"); }
        assert(nm.name == "coffee");
        let missing: result[opt[PgName], str] = query_one(p,
            "select name from zokor_t_items where id = $1", [pg.arg_int(99)], pg_dl());
        guard let m = missing else let e = err_of(missing) { panic(e); }
        guard let _x = m else {
            pg_must(p, "drop table zokor_t_items");
            return;
        }
        panic("a missing row was found");
    }
    panic("NULL did not decode to none");
}

fn test_live_nan_arrives_as_a_string() {
    guard let p = pg_live("live_nan_arrives_as_a_string") else { return; }
    let no_args: [pg.Arg] = [];
    let r: result[[PgText], str] = query_all(p, "select 'NaN'::float8 as price", no_args, pg_dl());
    guard let rows = r else let e = err_of(r) { panic(e); }
    assert(rows[0].price == "NaN", "JSON has no NaN; the text survives as a string");
}

fn test_live_rows_that_do_not_fit_say_so() {
    guard let p = pg_live("live_rows_that_do_not_fit_say_so") else { return; }
    let no_args: [pg.Arg] = [];
    let r: result[[PgItem], str] = query_all(p, "select 1 as id", no_args, pg_dl());
    guard let _x = r else let e = err_of(r) {
        assert(strings.contains(e, "do not fit the struct"), e);
        return;
    }
    panic("a row without required fields decoded");
}

struct Credit {
    id: int,
    amount: int,
    fail: bool,
    explode: bool,
}

fn credit(c: pg.Conn, cr: Credit) -> result[int, str] {
    let u = pg.query(c, "update zokor_t_acct set balance = balance + $1 where id = $2",
                     [pg.arg_int(cr.amount), pg.arg_int(cr.id)], pg_dl());
    guard let _u = u else let e = err_of(u) { return err(e); }
    if cr.explode {
        let xs: [int] = [];
        return ok(xs[1]);
    }
    if cr.fail {
        return err("business rule refused it");
    }
    return ok(cr.amount);
}

fn balance(p: pg.Pool) -> int {
    let no_args: [pg.Arg] = [];
    let r = pg.pool_query(p, "select balance from zokor_t_acct where id = 1", no_args, pg_dl());
    guard let rows = r else let e = err_of(r) { panic(e); }
    return pg.get_int(rows, 0, 0);
}

fn test_live_transactions_commit_or_roll_back_and_return_the_connection() {
    guard let p = pg_live("live_transactions") else { return; }
    pg_must(p, "drop table if exists zokor_t_acct");
    pg_must(p, "create table zokor_t_acct (id int primary key, balance int not null)");
    pg_must(p, "insert into zokor_t_acct values (1, 100)");
    let okr = transaction(p, Credit { id: 1, amount: 5, fail: false, explode: false }, credit, pg_dl());
    assert((okr ?? -1) == 5);
    assert(balance(p) == 105, "committed");
    let bad = transaction(p, Credit { id: 1, amount: 50, fail: true, explode: false }, credit, pg_dl());
    guard let _b = bad else let e = err_of(bad) {
        assert(e == "business rule refused it", e);
        assert(balance(p) == 105, "rolled back on err");
        let boom = transaction(p, Credit { id: 1, amount: 50, fail: false, explode: true }, credit, pg_dl());
        guard let _x = boom else let e2 = err_of(boom) {
            assert(strings.contains(e2, "panicked"), e2);
            assert(balance(p) == 105, "rolled back on a panic");
            // a pool of 2: ten more transactions only finish if every
            // connection went back
            let i = 0;
            while i < 10 {
                let rr = transaction(p, Credit { id: 1, amount: 1, fail: i % 2 == 0, explode: false },
                                     credit, until_of(time.mono() + 2000000000));
                i = i + 1;
            }
            assert(balance(p) == 110, to_str(balance(p)));
            pg_must(p, "drop table zokor_t_acct");
            return;
        }
        panic("a panicking body committed");
    }
    panic("an err body committed");
}

fn test_live_unique_violation_answers_409() {
    guard let p = pg_live("live_unique_violation_answers_409") else { return; }
    pg_must(p, "drop table if exists zokor_t_users");
    pg_must(p, "create table zokor_t_users (email text unique)");
    pg_must(p, "insert into zokor_t_users values ('a@x.com')");
    let r = pg.pool_query(p, "insert into zokor_t_users values ($1)", [pg.arg_text("a@x.com")], pg_dl());
    guard let _x = r else let e = err_of(r) {
        assert(is_unique_violation(e), e);
        assert(resp_status(db_failure(new_registry(), e, "")) == 409);
        pg_must(p, "drop table zokor_t_users");
        return;
    }
    panic("a duplicate was inserted");
}
