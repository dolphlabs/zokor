import "proc";
import "time";
import "zokor";
import "../domain" as domain;

// Against a real database when TEST_DATABASE_URL is set (the migrations
// are applied first); skipped, and says so, when it is not.
fn live() -> opt[Postgres] {
    let none_here: opt[Postgres] = none;
    let url = proc.getenv("TEST_DATABASE_URL") ?? "";
    if len(url) == 0 {
        println("skip __feature__ postgres tests (TEST_DATABASE_URL is not set)");
        return none_here;
    }
    let m: map[str]str = {};
    m["DATABASE_URL"] = url;
    let opened = zokor.pg_from_config(zokor.config_from_values(m));
    guard let pool = opened else let e = err_of(opened) { panic(e); }
    let ms = zokor.load_migrations("migrations", zokor.migration_limits());
    guard let loaded = ms else let e = err_of(ms) { panic(e); }
    let applied = zokor.migrate(pool, loaded, until_of(time.mono() + 30000000000));
    guard let _n = applied else let e = err_of(applied) { panic(e); }
    return some(new_postgres(pool));
}

fn test_postgres_keeps_tenants_apart_and_pages() {
    guard let p = live() else { return; }
    let tenant = "t-" + zokor.new_session_id();
    for id in ["a", "b", "c"] {
        let r = pg_insert(p, domain.__Entity__ { id: id, tenant_id: tenant, title: id, body: "" });
        guard let _ok = r else let e = err_of(r) { panic(e); }
    }
    let found = pg_find(p, tenant, "b");
    guard let got = found else let e = err_of(found) { panic(e); }
    guard let n = got else { panic("b is missing"); }
    assert(n.title == "b");
    let other = pg_find(p, "someone-else", "b");
    guard let none_found = other else { panic("find failed"); }
    if let _x = none_found { panic("another tenant's row was found"); }
    let page = pg_list(p, tenant, 1, 1);
    guard let rows = page else let e = err_of(page) { panic(e); }
    assert(len(rows) == 1 && rows[0].id == "b");
}
