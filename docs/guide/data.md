# Data and storage

> slang's pg package is the driver.

## Postgres

slang's `pg` package is the driver. zokor adds what every service writes on
top of it, and nothing that bypasses it:

```slang
let pr = zokor.pg_from_config(cfg);          // DATABASE_URL, DB_POOL_SIZE (10)
guard let db = pr else let e = err_of(pr) { log.error(e); exit(1); }

struct User { id: int, email: str, name: opt[str] }

fn list_users(c: zokor.Ctx[App]) -> http.Response {
    let r: result[[User], str] = zokor.query_all(c.state.db,
        "select id, email, name from users where org = $1",
        [pg.arg_int(c.param_int("org", 0))], until_of(time.mono() + 2000000000));
    guard let users = r else let e = err_of(r) {
        return zokor.db_failure(c.errors, e, c.request_id);
    }
    return zokor.ok_json(json.encode(users));
}
```

- **Rows into structs, by column name.** `query_all`, `query_one` (none
  when there's no row), `conn_query_all` inside a transaction, and
  `rows_as` use slang's compiler-backed `pg.rows_as`, binding column names
  once without rendering intermediate JSON text:
  - integers, floats and numerics become numbers (NaN and infinity become
    strings)
  - booleans stay booleans
  - `json`/`jsonb` decode into nested structs
  - NULL becomes `none`, so use an `opt` field
  - `bytea` reads into `bytes` or a base64 string
  - `timestamptz` and `timestamp` become RFC 3339 strings, so a
    `timez.Time` field reads them (a `timestamp` without a zone as UTC),
    and a `str` field gets the text an API would send
  - text and uuid become strings

  A column your struct doesn't name is ignored. A field the query doesn't
  return must be an `opt`, or the result names the missing field. Invalid
  cell storage and type mismatches return errors with row and field context.
- **Transactions.** `transaction(db, arg, body, deadline)` runs
  `body(conn, arg)` between `BEGIN` and `COMMIT`. An `err`, a failed
  `COMMIT` or a panic in the body rolls back, and the connection goes back
  to the pool every way out. There are no closures, so what the body
  needs comes in as `arg`.
- **Failures in your envelope.** `db_failure(reg, e, rid)` picks the
  status from the SQLSTATE:
  - unique violation: `409 already_exists`
  - foreign key: `409 conflict`
  - not null, check, or a bad value: `422`
  - serialization, deadlock or timeout: `503`
  - anything else: `500`

  The server's message, which names tables, columns and values, never
  reaches the client. `is_unique_violation(e)` is there for the common
  branch.
- **Parameterised queries only.** Every helper takes `$1`-style SQL and
  `pg.Arg` values, and nothing builds SQL from strings. That's the SQL
  injection defence.

## Redis

Optional the same way any dependency should be: a service with no
`REDIS_URL` builds no pool and opens no connection.

```slang
let cfg = zokor.load_config();
let pr = zokor.redis_from_config(cfg);   // reads REDIS_URL, REDIS_POOL_SIZE
guard let pool = pr else let e = err_of(pr) {
    println(e);       // "REDIS_URL is not set" -- your call whether that's fatal
    exit(1);
}
```

That is the whole of it: a pool from config, nothing more. Everything
past that point is slang's own `redis` package — `redis.acquire`,
`redis.get`/`set`/`hset`/`zadd`/…, transactions, pub/sub, streams,
cluster routing — called directly, the same way any other zokor
service reaches its dependencies. Wrapping the other ~150 functions
here would only be a second place for that API to drift from the one
slang ships.

```slang
let cr = redis.acquire(pool, deadline);
guard let conn = cr else let e = err_of(cr) {
    return zokor.respond(c.state.errors, "unavailable", c.request_id);
}
let r = redis.get(conn, "session:" + token, deadline);
redis.release(pool, conn);
```

## Migrations

`make cli` builds `bin/zokor`. Run `bin/zokor migrate [directory]` with
`DATABASE_URL` configured; the default directory is `migrations`. Files
are numbered forward-only SQL, for example `001_create_users.sql`.
Versions must be positive and unique; descriptions use ASCII letters,
digits, underscores or hyphens. Files are ordered numerically.

The runner checks every applied filename and SHA-256 checksum, takes a
Postgres transaction advisory lock, and applies the whole pending batch
in one transaction. A failure rolls back SQL and history together. Keep
applied files unchanged and present; add a new file for every change.
SQL can contain multiple statements, comments and dollar-quoted function
bodies. Explicit transaction/session commands and COPY are refused;
nontransactional operations such as CREATE INDEX CONCURRENTLY belong in
a separate operational procedure.

Services can call `load_migrations(dir, migration_limits())` and
`migrate(pool, migrations, deadline)` at startup. File limits are caller
configurable; the CLI reads `MIGRATION_MAX_FILES` (1000),
`MIGRATION_MAX_FILE_BYTES` (1 MiB), `MIGRATION_MAX_TOTAL_BYTES` (16 MiB),
and `MIGRATION_TIMEOUT_SECONDS` (60, maximum 86400). Errors exit nonzero;
success prints the applied count, including zero for an unchanged schema.
