import "pg";
import "../domain" as domain;
import "../service" as service;

// Which adapter __feature__ is stored with, chosen at startup in
// platform/app: one type for all of them, so the app state and every test
// above this layer stay the same whichever is in use.
pub gc struct Store {
    memory: opt[Memory],
    postgres: opt[Postgres]
}

// Kept in this process (development, tests).
pub fn in_memory() -> service.__Entity__Store[Store] {
    let none_pg: opt[Postgres] = none;
    return wrap(Store { memory: some(new_memory()), postgres: none_pg });
}

// In Postgres: the table migrations/ creates.
pub fn on_postgres(pool: pg.Pool) -> service.__Entity__Store[Store] {
    let none_mem: opt[Memory] = none;
    return wrap(Store { memory: none_mem, postgres: some(new_postgres(pool)) });
}

fn wrap(s: Store) -> service.__Entity__Store[Store] {
    return service.__Entity__Store[Store] { context: s, insert: store_insert, find: store_find,
                                         list: store_list };
}

fn store_insert(s: Store, n: domain.__Entity__) -> result[bool, str] {
    if let p = s.postgres { return pg_insert(p, n); }
    guard let m = s.memory else { return err("no store"); }
    return memory_insert(m, n);
}

fn store_find(s: Store, tenant_id: str, id: str) -> result[opt[domain.__Entity__], str] {
    if let p = s.postgres { return pg_find(p, tenant_id, id); }
    guard let m = s.memory else { return err("no store"); }
    return memory_find(m, tenant_id, id);
}

fn store_list(s: Store, tenant_id: str, offset: int, limit: int) -> result[[domain.__Entity__], str] {
    if let p = s.postgres { return pg_list(p, tenant_id, offset, limit); }
    guard let m = s.memory else { return err("no store"); }
    return memory_list(m, tenant_id, offset, limit);
}
