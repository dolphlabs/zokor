import "../domain" as domain;

// __Feature__ kept in memory: for development, tests of the layers above, and
// a service that does not need them to outlive the process. Every key
// is tenant-scoped, so one tenant's id can never name another's __entity__.
pub gc struct Memory {
    lock: mutex,
    rows: map[str]domain.__Entity__,
    order: [str],
}

fn new_memory() -> Memory {
    let rows: map[str]domain.__Entity__ = {};
    let order: [str] = [];
    return Memory { lock: make_mutex(), rows: rows, order: order };
}

fn key(tenant_id: str, id: str) -> str {
    return tenant_id + "/" + id;
}

fn memory_insert(m: Memory, n: domain.__Entity__) -> result[bool, str] {
    let k = key(n.tenant_id, n.id);
    mutex_lock(m.lock);
    let fresh = !has(m.rows, k);
    if fresh {
        m.rows[k] = n;
        push(m.order, k);
    }
    mutex_unlock(m.lock);
    if !fresh {
        return err("__entity__ " + k + " already exists");
    }
    return ok(true);
}

fn memory_find(m: Memory, tenant_id: str, id: str) -> result[opt[domain.__Entity__], str] {
    let k = key(tenant_id, id);
    mutex_lock(m.lock);
    let found: opt[domain.__Entity__] = none;
    if has(m.rows, k) {
        found = some(m.rows[k]);
    }
    mutex_unlock(m.lock);
    return ok(found);
}

fn memory_list(m: Memory, tenant_id: str, offset: int, limit: int) -> result[[domain.__Entity__], str] {
    let out: [domain.__Entity__] = [];
    let skipped = 0;
    mutex_lock(m.lock);
    for k in m.order {
        let n = m.rows[k];
        if n.tenant_id == tenant_id && len(out) < limit {
            if skipped < offset {
                skipped = skipped + 1;
            } else {
                push(out, n);
            }
        }
    }
    mutex_unlock(m.lock);
    return ok(out);
}
