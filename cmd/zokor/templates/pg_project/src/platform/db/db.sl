import "pg";
import "zokor";

// The service's one Postgres pool: DATABASE_URL, DB_POOL_SIZE (10). Only
// this package and the features' store/ packages import pg.
pub fn open(cfg: zokor.Config) -> result[pg.Pool, str] {
    return zokor.pg_from_config(cfg);
}
