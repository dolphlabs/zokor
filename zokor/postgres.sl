// Postgres, wired to zokor's config, results and error envelope.
//
// slang's `pg` package is the driver: pooling, prepared statements,
// streaming, COPY, LISTEN/NOTIFY. This adds what every service writes on
// top of it, and nothing that bypasses it:
//
//   - a pool from DATABASE_URL (pg_from_config);
//   - rows as your own structs, by column name (query_all, query_one,
//     rows_as);
//   - transactions that commit when the body returns ok and roll back on
//     err or a panic, always returning the connection (transaction);
//   - database failures as the right status in your envelope, never as a
//     500 that leaks the SQL error (db_failure).
//
// Parameterised queries only: every helper takes `$1`-style SQL and a
// list of `pg.Arg`, and nothing here builds SQL out of strings. That is
// the SQL-injection defence; a filter that hunts for quotes in input is
// not one.
//
//     struct User { id: int, email: str, name: opt[str] }
//
//     let r: result[[User], str] = zokor.query_all(c.state.db,
//         "select id, email, name from users where org = $1",
//         [pg.arg_int(org)], deadline);
//     guard let users = r else let e = err_of(r) {
//         return zokor.db_failure(c.errors, e, c.request_id);
//     }
//
// Cost, measured (bench/postgres, against a local Postgres): about 2.2 us
// a row over reading the cells by hand -- 1,000 rows 5.3 ms against 3.0
// ms, 10 rows 412 us against 382 us. At API page sizes the round trip
// dominates; for thousands of rows, read them with pg.get_* or
// pg.stream.
//
// Rows map by name through JSON: integers, floats and numerics become
// numbers, booleans booleans, json/jsonb columns their own JSON, NULL
// `null` (so an opt field), bytea base64, and everything else -- text,
// uuid, timestamps -- a string. A column your struct does not name is
// ignored; a field the query does not return must be an opt.

import "builder";
import "encoding";
import "http";
import "json";
import "pg";

// DATABASE_URL (postgres://user:pass@host:port/db?sslmode=require) and
// DB_POOL_SIZE (default 10). Connects nothing until the first query.
// err when DATABASE_URL is unset or malformed: the caller decides
// whether a service without a database may start.
pub fn pg_from_config(cfg: Config) -> result[pg.Pool, str] {
    let url = optional_dsn(cfg, "DATABASE_URL", "");
    if len(url) == 0 {
        return err("DATABASE_URL is not set");
    }
    let size = int_or(cfg, "DB_POOL_SIZE", 10);
    if size < 1 {
        record(cfg, "DB_POOL_SIZE", to_str(size), "must be at least 1");
        return err("DB_POOL_SIZE must be at least 1");
    }
    return pg.new_pool(url, size);
}

pub fn has_postgres(cfg: Config) -> bool {
    return len(optional_dsn(cfg, "DATABASE_URL", "")) > 0;
}

pub fn pg_close(p: pg.Pool) {
    pg.pool_close(p);
}

// ---- rows into structs -------------------------------------------------------

// A numeric column's text is a JSON number unless it is NaN or infinite,
// which JSON cannot hold: those become strings.
fn json_number_ok(t: str) -> bool {
    return len(t) > 0 && t != "NaN" && t != "Infinity" && t != "-Infinity";
}

fn cell_into(sb: builder.Str, rows: pg.Rows, r: int, c: int) {
    if pg.is_null(rows, r, c) {
        sb.write("null");
        return;
    }
    let oid = rows.types[c];
    // int2, int4, int8, oid
    if oid == 21 || oid == 23 || oid == 20 || oid == 26 {
        sb.write(pg.get_text(rows, r, c));
        return;
    }
    // float4, float8, numeric
    if oid == 700 || oid == 701 || oid == 1700 {
        let t = pg.get_text(rows, r, c);
        if json_number_ok(t) {
            sb.write(t);
        } else {
            quote_into(sb, t);
        }
        return;
    }
    if oid == 16 {
        if pg.get_bool(rows, r, c) {
            sb.write("true");
        } else {
            sb.write("false");
        }
        return;
    }
    // json, jsonb: already JSON
    if oid == 114 || oid == 3802 {
        sb.write(pg.get_text(rows, r, c));
        return;
    }
    if oid == 17 {
        quote_into(sb, encoding.base64_encode(pg.get_bytes(rows, r, c)));
        return;
    }
    quote_into(sb, pg.get_text(rows, r, c));
}

// Row `r` as a JSON object keyed by column name.
pub fn row_json(rows: pg.Rows, r: int) -> str {
    let sb = builder.new_str();
    row_into(sb, rows, column_keys(rows), r);
    return sb.finish();
}

// `"name":` per column, quoted once per query, not once per row.
fn column_keys(rows: pg.Rows) -> [str] {
    let keys: [str] = [];
    let c = 0;
    while c < len(rows.columns) {
        let k = quote(rows.columns[c]) + ":";
        if c > 0 {
            k = "," + k;
        }
        push(keys, k);
        c = c + 1;
    }
    return keys;
}

fn row_into(sb: builder.Str, rows: pg.Rows, keys: [str], r: int) {
    sb.write("{");
    let c = 0;
    while c < len(keys) {
        sb.write(keys[c]);
        cell_into(sb, rows, r, c);
        c = c + 1;
    }
    sb.write("}");
}

// Every row as a T, matched by column name.
pub fn rows_as[T](rows: pg.Rows) -> result[[T], str] {
    let sb = builder.new_str();
    let keys = column_keys(rows);
    sb.write("[");
    let r = 0;
    while r < rows.count {
        if r > 0 {
            sb.write(",");
        }
        row_into(sb, rows, keys, r);
        r = r + 1;
    }
    sb.write("]");
    let out: result[[T], str] = json.decode(sb.finish());
    guard let list = out else let e = err_of(out) {
        return err("rows do not fit the struct: " + e);
    }
    return ok(list);
}

// Runs `sql` with `args` on a pooled connection and returns every row as
// a T.
pub fn query_all[T](p: pg.Pool, sql: str, args: [pg.Arg], deadline: until) -> result[[T], str] {
    let qr = pg.pool_query(p, sql, args, deadline);
    guard let rows = qr else let e = err_of(qr) {
        return err(e);
    }
    return rows_as(rows);
}

// The first row as a T, none when the query returned no row.
pub fn query_one[T](p: pg.Pool, sql: str, args: [pg.Arg], deadline: until) -> result[opt[T], str] {
    let r: result[[T], str] = query_all(p, sql, args, deadline);
    guard let list = r else let e = err_of(r) {
        return err(e);
    }
    if len(list) == 0 {
        return ok(none);
    }
    return ok(some(list[0]));
}

// The same on a connection you hold -- inside a transaction body.
pub fn conn_query_all[T](c: pg.Conn, sql: str, args: [pg.Arg], deadline: until) -> result[[T], str] {
    let qr = pg.query(c, sql, args, deadline);
    guard let rows = qr else let e = err_of(qr) {
        return err(e);
    }
    return rows_as(rows);
}

// ---- transactions -------------------------------------------------------------

// Runs `body(conn, arg)` inside BEGIN ... COMMIT on one pooled
// connection. err from the body, a failed COMMIT, or a panic in the body
// rolls back; the connection goes back to the pool every way out (a
// connection a rollback could not reset is closed, not reused). There
// are no closures, so what the body needs comes in as `arg`:
//
//     fn move_funds(c: pg.Conn, t: Transfer) -> result[int, str] {
//         let d = until_of(time.mono() + 2000000000);
//         let a = pg.query(c, "update accounts set balance = balance - $1 where id = $2",
//                          [pg.arg_int(t.amount), pg.arg_int(t.from)], d);
//         guard let _a = a else let e = err_of(a) { return err(e); }
//         ...
//         return ok(0);
//     }
//
//     let r = zokor.transaction(c.state.db, transfer, move_funds, deadline);
pub fn transaction[A, R](p: pg.Pool, arg: A, body: fn(pg.Conn, A) -> result[R, str],
                         deadline: until) -> result[R, str] {
    let cr = pg.acquire(p, deadline);
    guard let conn = cr else let e = err_of(cr) {
        return err(e);
    }
    let br = pg.exec(conn, "BEGIN", deadline);
    guard let _b = br else let e = err_of(br) {
        pg.release(p, conn);
        return err(e);
    }
    // In its own task, so a panic in the body is a rollback, not a
    // connection stuck in an open transaction for the rest of its life.
    let h = spawn run_tx_body(body, conn, arg);
    let jr = join_wait(h);
    guard let r = jr else let pe = err_of(jr) {
        rollback_and_release(p, conn, deadline);
        return err("transaction body panicked: " + pe);
    }
    guard let v = r else let e = err_of(r) {
        rollback_and_release(p, conn, deadline);
        return err(e);
    }
    let cm = pg.exec(conn, "COMMIT", deadline);
    guard let _c = cm else let e = err_of(cm) {
        rollback_and_release(p, conn, deadline);
        return err(e);
    }
    pg.release(p, conn);
    return ok(v);
}

fn run_tx_body[A, R](body: fn(pg.Conn, A) -> result[R, str], conn: pg.Conn, arg: A) -> result[R, str] {
    return body(conn, arg);
}

fn rollback_and_release(p: pg.Pool, conn: pg.Conn, deadline: until) {
    let _r = pg.exec(conn, "ROLLBACK", deadline);
    pg.release(p, conn);
}

// ---- failures -----------------------------------------------------------------

pub fn is_unique_violation(e: str) -> bool {
    return pg.sqlstate(e) == "23505";
}

// A database error as the answer to send, in the service's envelope. The
// SQLSTATE picks the status; the server's message never reaches the
// client (it names tables, columns and values):
//
//   23505 unique_violation       409 already_exists
//   23503 foreign_key_violation  409 conflict
//   23502, 23514, 22xxx          422 unprocessable (not null, check, bad value)
//   40001, 40P01                 503 unavailable  (serialization, deadlock: retry)
//   57014, a timeout             503 unavailable
//   anything else                500 internal
pub fn db_failure(reg: Registry, e: str, request_id: str) -> http.Response {
    let state = pg.sqlstate(e);
    if state == "23505" {
        return respond(reg, "already_exists", request_id);
    }
    if state == "23503" {
        return respond(reg, "conflict", request_id);
    }
    if state == "23502" || state == "23514" || strings_prefix(state, "22") {
        return respond(reg, "unprocessable", request_id);
    }
    if state == "40001" || state == "40P01" || state == "57014" || e == "timeout" {
        return respond(reg, "unavailable", request_id);
    }
    return respond(reg, "internal", request_id);
}

fn strings_prefix(s: str, p: str) -> bool {
    return len(s) >= len(p) && to_str(to_bytes(s)[0..len(p)]) == p;
}
