import "pg";
import "time";
import "strings";
import "internal/migration" as migsql;

fn migration_test_load() -> [Migration] {
    let r = load_migrations("testdata/migrations", migration_limits());
    guard let ms = r else let e = err_of(r) { panic(e); }
    return ms;
}

fn test_migration_names_and_sql_boundaries() {
    assert((migsql.version("001_create_users.sql") ?? -1) == 1);
    assert((migsql.version("10_more-users.sql") ?? -1) == 10);
    assert((migsql.version("0_empty.sql") ?? -1) == -1);
    assert((migsql.version("1_../bad.sql") ?? -1) == -1);
    assert((migsql.version("999999999999999999999_x.sql") ?? -1) == -1);
    let r = migsql.statements("/* outer /* nested */ */ CREATE TABLE x (v text); " +
        "INSERT INTO x VALUES ('a;''b'); DO $body$ BEGIN PERFORM 1; END $body$;");
    guard let ss = r else let e = err_of(r) { panic(e); }
    assert(len(ss) == 3);
    for sql in ["COMMIT", "select 1; -- comment\nROLLBACK", "START TRANSACTION", "END", "COPY x FROM STDIN", "SET standard_conforming_strings=off"] {
        let bad = migsql.statements(sql);
        guard let _s = bad else { continue; }
        panic("accepted transaction/session command: " + sql);
    }
    for sql in ["select 'unfinished", "select $x$unfinished", "/* unfinished"] {
        let bad = migsql.statements(sql);
        guard let _s = bad else { continue; }
        panic("accepted invalid SQL");
    }
}

fn test_load_migrations_orders_numbers_and_caps_files() {
    let r = load_migrations("testdata/migrations", migration_limits());
    guard let ms = r else let e = err_of(r) { panic(e); }
    assert(len(ms) == 2 && ms[0].version == 2 && ms[1].version == 10);
    assert(len(ms[0].checksum) == 64 && ms[0].checksum != ms[1].checksum);
    let limits = migration_limits();
    limits.max_file_bytes = 1;
    let too_big = load_migrations("testdata/migrations", limits);
    guard let _m = too_big else let e = err_of(too_big) {
        assert(strings.contains(e, "max_file_bytes"), e);
        return;
    }
    panic("oversized SQL file accepted");
}

fn test_migrations_reject_duplicate_versions_and_unchecked_edits() {
    let m = new_migration(1, "1_one.sql", "select 1;");
    let duplicates: [Migration] = [m, m];
    let dupe = migration_validate(duplicates);
    guard let _d = dupe else {
        m.sql = "select 2;";
        let changed: [Migration] = [m];
        let stale = migration_validate(changed);
        guard let _s = stale else let e = err_of(stale) {
            assert(strings.contains(e, "checksum"), e);
            return;
        }
        panic("stale checksum accepted");
    }
    panic("duplicate versions accepted");
}

fn test_migration_file_reader_rejects_nul_before_string_conversion() {
    let r = load_migrations("testdata/migrations-nul", migration_limits());
    guard let _m = r else let e = err_of(r) {
        assert(strings.contains(e, "NUL"), e);
        return;
    }
    panic("NUL truncated migration SQL and checksum");
}

fn test_live_migrations_atomic_idempotent_and_detect_drift() {
    guard let p = pg_live("migrations_atomic_idempotent_and_detect_drift") else { return; }
    pg_must(p, "drop table if exists public.zokor_schema_migrations; drop table if exists zokor_t_migrated");
    let ms = migration_test_load();
    assert((migrate(p, ms, pg_dl()) ?? -1) == 2);
    assert((migrate(p, ms, pg_dl()) ?? -1) == 0);
    let changed = migration_test_load();
    changed[0].sql = changed[0].sql + "\n-- edit";
    changed[0].checksum = migration_checksum(changed[0].sql);
    let drift = migrate(p, changed, pg_dl());
    guard let _d = drift else let e = err_of(drift) {
        assert(strings.contains(e, "changed"), e);
        let missing: [Migration] = [ms[1]];
        let gone = migrate(p, missing, pg_dl());
        guard let _g = gone else {
            push(ms, new_migration(11, "11_valid.sql", "insert into zokor_t_migrated values (3);"));
            let bad = new_migration(12, "12_bad.sql", "insert into zokor_t_migrated values (4); select absent_column from zokor_t_migrated;");
            push(ms, bad);
            let failed = migrate(p, ms, pg_dl());
            guard let _f = failed else {
                let args: [pg.Arg] = [];
                let rr = pg.pool_query(p, "select count(*) from zokor_t_migrated", args, pg_dl());
                guard let rows = rr else let why = err_of(rr) { panic(why); }
                assert(pg.get_int(rows, 0, 0) == 2, "failed batch rolled back both files and the earlier statement");
                let hr = pg.pool_query(p, "select count(*) from public.zokor_schema_migrations", args, pg_dl());
                guard let history = hr else let why = err_of(hr) { panic(why); }
                assert(pg.get_int(history, 0, 0) == 2, "failed batch did not advance history");
                pg_must(p, "drop table public.zokor_schema_migrations; drop table zokor_t_migrated");
                return;
            }
            panic("invalid SQL committed");
        }
        panic("missing historical migration accepted");
    }
    panic("edited applied SQL accepted");
}

fn test_live_migrations_concurrent_runners_apply_once() {
    guard let p = pg_live("migrations_concurrent") else { return; }
    pg_must(p, "drop table if exists public.zokor_schema_migrations; drop table if exists zokor_t_migrated");
    let ms = migration_test_load();
    let a = spawn migrate(p, ms, pg_dl());
    let b = spawn migrate(p, ms, pg_dl());
    let aj = join_wait(a);
    let bj = join_wait(b);
    guard let ar = aj else let e = err_of(aj) { panic(e); }
    guard let br = bj else let e = err_of(bj) { panic(e); }
    guard let ac = ar else let e = err_of(ar) { panic(e); }
    guard let bc = br else let e = err_of(br) { panic(e); }
    assert(ac + bc == 2 && (ac == 0 || bc == 0), "one runner applies, the other observes history");
    pg_must(p, "drop table public.zokor_schema_migrations; drop table zokor_t_migrated");
}
