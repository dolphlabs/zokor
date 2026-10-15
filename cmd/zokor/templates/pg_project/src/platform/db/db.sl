import "pg";
import "zokor";

// The service's one Postgres pool: DATABASE_URL, DB_POOL_SIZE (10). Only
// this package and the features' store/ packages import pg; everything
// else holds a Db.
pub gc struct Db {
    pool: pg.Pool,
}

pub fn open(cfg: zokor.Config) -> result[Db, str] {
    let r = zokor.pg_from_config(cfg);
    guard let pool = r else let e = err_of(r) {
        return err(e);
    }
    return ok(Db { pool: pool });
}
