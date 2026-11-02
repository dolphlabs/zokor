import "pg";
import "time";
import "zokor";
import "../domain" as domain;

// __Feature__ in Postgres. Every query is parameterised ($1, ...) and
// names its tenant; rows decode by column name into domain.__Entity__.
pub gc struct Postgres {
    pool: pg.Pool,
    // How long one query may take, in nanoseconds.
    timeout: int,
}

fn new_postgres(pool: pg.Pool) -> Postgres {
    return Postgres { pool: pool, timeout: 2000000000 };
}

fn deadline(p: Postgres) -> until {
    return until_of(time.mono() + p.timeout);
}

fn pg_insert(p: Postgres, n: domain.__Entity__) -> result[bool, str] {
    let r: result[[domain.__Entity__], str] = zokor.query_all(p.pool,
        "insert into __feature__ (tenant_id, id, title, body) values ($1, $2, $3, $4) " +
        "returning tenant_id, id, title, body",
        [pg.arg_text(n.tenant_id), pg.arg_text(n.id), pg.arg_text(n.title), pg.arg_text(n.body)],
        deadline(p));
    guard let _rows = r else let e = err_of(r) {
        return err(e);
    }
    return ok(true);
}

fn pg_find(p: Postgres, tenant_id: str, id: str) -> result[opt[domain.__Entity__], str] {
    return zokor.query_one(p.pool,
        "select tenant_id, id, title, body from __feature__ where tenant_id = $1 and id = $2",
        [pg.arg_text(tenant_id), pg.arg_text(id)], deadline(p));
}

fn pg_list(p: Postgres, tenant_id: str, offset: int, limit: int) -> result[[domain.__Entity__], str] {
    return zokor.query_all(p.pool,
        "select tenant_id, id, title, body from __feature__ where tenant_id = $1 " +
        "order by created_at, id offset $2 limit $3",
        [pg.arg_text(tenant_id), pg.arg_int(offset), pg.arg_int(limit)], deadline(p));
}
