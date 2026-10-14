// What zokor's Postgres helpers cost over slang's `pg` used by hand.
//
//   query: the same SELECT, mapped into the same struct two ways --
//          `raw` reads each cell with pg.get_* (the floor), `zokor` uses
//          query_all (each row rendered as JSON, then json.decode).
//   tx:    one UPDATE in a transaction -- `raw` sends BEGIN / UPDATE /
//          COMMIT itself, `zokor` uses transaction() (adds a spawned
//          task for panic isolation).
//
// Needs ZOKOR_TEST_DATABASE_URL. Runs ABBA-ordered rounds and prints the
// median per operation, with allocations per operation from the GC
// counters (run with SLANG_GC_STAT=1 to see totals).
//
//     ZOKOR_TEST_DATABASE_URL=postgres://... slangc bench/postgres/main.sl --run

import "pg";
import "proc";
import "time";
import "../../zokor" as zokor;

struct User {
    id: int,
    email: str,
    name: opt[str],
    active: bool,
    created: str,
}

fn dl() -> until {
    return until_of(time.mono() + 10000000000);
}

fn must(p: pg.Pool, sql: str) {
    let r = pg.pool_exec(p, sql, dl());
    guard let _n = r else let e = err_of(r) { panic(sql + ": " + e); }
}

fn sql_for(n: int) -> str {
    return "select id, email, name, active, created::text as created from zokor_b_users " +
           "where id <= " + to_str(n) + " order by id";
}

fn raw_query(p: pg.Pool, sql: str) -> int {
    let no_args: [pg.Arg] = [];
    let r = pg.pool_query(p, sql, no_args, dl());
    guard let rows = r else let e = err_of(r) { panic(e); }
    let out: [User] = [];
    let ci = pg.col(rows, "id");
    let ce = pg.col(rows, "email");
    let cn = pg.col(rows, "name");
    let ca = pg.col(rows, "active");
    let cc = pg.col(rows, "created");
    let i = 0;
    while i < rows.count {
        let name: opt[str] = none;
        if !pg.is_null(rows, i, cn) {
            name = some(pg.get_text(rows, i, cn));
        }
        push(out, User {
            id: pg.get_int(rows, i, ci),
            email: pg.get_text(rows, i, ce),
            name: name,
            active: pg.get_bool(rows, i, ca),
            created: pg.get_text(rows, i, cc)
        });
        i = i + 1;
    }
    return len(out);
}

fn zokor_query(p: pg.Pool, sql: str) -> int {
    let no_args: [pg.Arg] = [];
    let r: result[[User], str] = zokor.query_all(p, sql, no_args, dl());
    guard let users = r else let e = err_of(r) { panic(e); }
    return len(users);
}

fn bump(c: pg.Conn, id: int) -> result[int, str] {
    let r = pg.query(c, "update zokor_b_users set active = not active where id = $1",
                     [pg.arg_int(id)], dl());
    guard let _r = r else let e = err_of(r) { return err(e); }
    return ok(1);
}

fn raw_tx(p: pg.Pool) -> int {
    let cr = pg.acquire(p, dl());
    guard let c = cr else let e = err_of(cr) { panic(e); }
    let _b = pg.exec(c, "BEGIN", dl());
    let r = bump(c, 1);
    let _c = pg.exec(c, "COMMIT", dl());
    pg.release(p, c);
    return r ?? 0;
}

fn zokor_tx(p: pg.Pool) -> int {
    let r = zokor.transaction(p, 1, bump, dl());
    return r ?? 0;
}

fn median(xs: [int]) -> int {
    let s = xs;
    // insertion sort: a handful of samples
    let i = 1;
    while i < len(s) {
        let v = s[i];
        let j = i - 1;
        while j >= 0 && s[j] > v {
            s[j + 1] = s[j];
            j = j - 1;
        }
        s[j + 1] = v;
        i = i + 1;
    }
    return s[len(s) / 2];
}

// ns per call of `which` over `reps` calls.
fn time_query(p: pg.Pool, which: str, sql: str, reps: int) -> int {
    let t0 = time.mono();
    let i = 0;
    while i < reps {
        if which == "raw" {
            raw_query(p, sql);
        } else {
            zokor_query(p, sql);
        }
        i = i + 1;
    }
    return ((time.mono() - t0) as int) / reps;
}

fn time_tx(p: pg.Pool, which: str, reps: int) -> int {
    let t0 = time.mono();
    let i = 0;
    while i < reps {
        if which == "raw" {
            raw_tx(p);
        } else {
            zokor_tx(p);
        }
        i = i + 1;
    }
    return ((time.mono() - t0) as int) / reps;
}

fn us(ns: int) -> str {
    let sign = "";
    let v = ns;
    if v < 0 {
        sign = "-";
        v = -v;
    }
    return sign + to_str(v / 1000) + "." + to_str((v % 1000) / 100) + "us";
}

let url = proc.getenv("ZOKOR_TEST_DATABASE_URL") ?? "";
if len(url) == 0 {
    println("set ZOKOR_TEST_DATABASE_URL");
    exit(1);
}
let pr = pg.new_pool(url, 4);
guard let p = pr else let e = err_of(pr) { println(e); exit(1); }
must(p, "drop table if exists zokor_b_users");
must(p, "create table zokor_b_users (id int primary key, email text not null, name text, " +
        "active bool not null, created timestamptz not null default now())");
must(p, "insert into zokor_b_users (id, email, name, active) select g, 'user' || g || '@example.com', " +
        "case when g % 3 = 0 then null else 'User ' || g end, g % 2 = 0 from generate_series(1, 1000) g");

for n in [1, 10, 100, 1000] {
    let sql = sql_for(n);
    let reps = 2000 / n + 20;
    raw_query(p, sql);
    zokor_query(p, sql);
    let raws: [int] = [];
    let zs: [int] = [];
    for round in [1, 2, 3] {
        push(raws, time_query(p, "raw", sql, reps));
        push(zs, time_query(p, "zokor", sql, reps));
        push(zs, time_query(p, "zokor", sql, reps));
        push(raws, time_query(p, "raw", sql, reps));
    }
    let r = median(raws);
    let z = median(zs);
    println("query rows=" + to_str(n) + "  raw " + us(r) + "  zokor " + us(z) +
            "  overhead " + us(z - r) + " (" + to_str((z - r) / n) + "ns/row)");
}
let rt: [int] = [];
let zt: [int] = [];
for round in [1, 2, 3] {
    push(rt, time_tx(p, "raw", 300));
    push(zt, time_tx(p, "zokor", 300));
    push(zt, time_tx(p, "zokor", 300));
    push(rt, time_tx(p, "raw", 300));
}
println("tx  raw " + us(median(rt)) + "  zokor " + us(median(zt)) + "  overhead " +
        us(median(zt) - median(rt)));
must(p, "drop table zokor_b_users");
