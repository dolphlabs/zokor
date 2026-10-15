import "../domain" as domain;
import "../service" as service;

// Which adapter __feature__ is stored with, chosen at startup in
// platform/app: one type for all of them, so the app state and every test
// above this layer stay the same whichever is in use.
pub gc struct Store {
    memory: Memory
}

// Kept in this process (development, tests).
pub fn in_memory() -> service.__Entity__Store[Store] {
    return service.__Entity__Store[Store] { context: Store { memory: new_memory() },
                                         insert: store_insert, find: store_find,
                                         list: store_list };
}

fn store_insert(s: Store, n: domain.__Entity__) -> result[bool, str] {
    return memory_insert(s.memory, n);
}

fn store_find(s: Store, tenant_id: str, id: str) -> result[opt[domain.__Entity__], str] {
    return memory_find(s.memory, tenant_id, id);
}

fn store_list(s: Store, tenant_id: str, offset: int, limit: int) -> result[[domain.__Entity__], str] {
    return memory_list(s.memory, tenant_id, offset, limit);
}
