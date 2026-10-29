import "../domain" as domain;

// A store for tests: canned answers, and a record of what it was asked.
// In a _test.sl file, so it is never compiled into the service.
gc struct FakeStore {
    calls: [str],
    rows: map[str]domain.__Entity__,
    failure: str,
}

fn fake_store() -> FakeStore {
    let calls: [str] = [];
    let rows: map[str]domain.__Entity__ = {};
    return FakeStore { calls: calls, rows: rows, failure: "" };
}

fn fake_insert(f: FakeStore, n: domain.__Entity__) -> result[bool, str] {
    push(f.calls, "insert " + n.tenant_id + "/" + n.id);
    if len(f.failure) > 0 { return err(f.failure); }
    f.rows[n.tenant_id + "/" + n.id] = n;
    return ok(true);
}

fn fake_find(f: FakeStore, tenant_id: str, id: str) -> result[opt[domain.__Entity__], str] {
    push(f.calls, "find " + tenant_id + "/" + id);
    if len(f.failure) > 0 { return err(f.failure); }
    let key = tenant_id + "/" + id;
    let absent: opt[domain.__Entity__] = none;
    if !has(f.rows, key) { return ok(absent); }
    return ok(some(f.rows[key]));
}

fn fake_list(f: FakeStore, tenant_id: str, offset: int, limit: int) -> result[[domain.__Entity__], str] {
    push(f.calls, "list " + tenant_id);
    if len(f.failure) > 0 { return err(f.failure); }
    let out: [domain.__Entity__] = [];
    for _k, n in f.rows {
        if n.tenant_id == tenant_id { push(out, n); }
    }
    return ok(out);
}

fn fixed_id() -> str {
    return "n1";
}

fn fake___feature__(f: FakeStore) -> __Feature__[FakeStore] {
    return new___feature__(__Entity__Store[FakeStore] { context: f, insert: fake_insert, find: fake_find,
                                            list: fake_list }, fixed_id);
}
