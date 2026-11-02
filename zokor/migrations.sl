// Forward-only SQL migrations: immutable history and an atomic pending batch.
import "crypto";
import "encoding";
import "fs";
import "os";
import "pg";
import "strings";
import "builder";
import "internal/migration" as migsql;

pub gc struct Migration {
    version: int,
    name: str,
    sql: str,
    checksum: str,
}

// Limits for reading files, chosen by the caller before startup.
pub gc struct MigrationLimits {
    max_files: int,
    max_file_bytes: int,
    max_total_bytes: int,
}

pub fn migration_limits() -> MigrationLimits {
    return MigrationLimits { max_files: 1000, max_file_bytes: 1048576, max_total_bytes: 16777216 };
}

pub fn migration_checksum(sql: str) -> str {
    return encoding.hex_encode(crypto.sha256(to_bytes(sql)));
}

pub fn new_migration(version: int, name: str, sql: str) -> Migration {
    return Migration { version: version, name: name, sql: sql, checksum: migration_checksum(sql) };
}

fn migration_read(file: str, cap: int) -> result[str, str] {
    if !os.is_file(file) { return err("migration must be a regular file"); }
    let opened = fs.open(file);
    guard let fd = opened else let e = err_of(opened) { return err(e); }
    let st = fs.fstat(fd);
    if len(st) != 4 || st[0] != 0 || st[1] > cap {
        fs.close(fd);
        return err("migration must be a regular file within max_file_bytes");
    }
    let sb = builder.new_str();
    let n = 0;
    while n <= cap {
        let want = cap - n + 1;
        if want > 65536 { want = 65536; }
        let rr = fs.read(fd, want);
        guard let chunk = rr else let e = err_of(rr) { fs.close(fd); return err(e); }
        if len(chunk) == 0 { fs.close(fd); return ok(sb.finish()); }
        for byte in chunk {
            if byte == 0 { fs.close(fd); return err("SQL contains NUL; remove it"); }
        }
        n = n + len(chunk);
        if n > cap { break; }
        sb.write(to_str(chunk));
    }
    fs.close(fd);
    return err("migration exceeds max_file_bytes");
}

// Load N_description.sql files, sort numerically, and reject duplicates.
// Non-SQL entries are ignored; SQL symlinks must resolve inside the root.
pub fn load_migrations(dir: str, limits: MigrationLimits) -> result[[Migration], str] {
    if limits.max_files < 1 || limits.max_file_bytes < 1 || limits.max_total_bytes < 1 || limits.max_file_bytes == 9223372036854775807 {
        return err("migration limits must be positive and max_file_bytes below the integer maximum");
    }
    let rp = fs.realpath(dir);
    guard let root = rp else let e = err_of(rp) { return err("migrations directory: " + e); }
    let rd = os.read_dir(root);
    guard let names = rd else let e = err_of(rd) { return err("migrations directory: " + e); }
    let out: [Migration] = [];
    let total = 0;
    for name in names {
        if !strings.has_suffix(name, ".sql") { continue; }
        let nv = migsql.version(name);
        guard let v = nv else { return err("migration '" + name + "': use N_description.sql with a positive number"); }
        if len(out) >= limits.max_files { return err("migrations exceed max_files"); }
        let real = fs.realpath(root + "/" + name);
        guard let file = real else let e = err_of(real) { return err(name + ": " + e); }
        if !strings.has_prefix(file, root + "/") { return err(name + ": migration escapes its directory"); }
        let cap = limits.max_file_bytes;
        if limits.max_total_bytes - total < cap { cap = limits.max_total_bytes - total; }
        if cap == 0 { return err("migrations exceed max_total_bytes"); }
        let read = migration_read(file, cap);
        guard let sql = read else let e = err_of(read) {
            if cap < limits.max_file_bytes { return err(name + ": max_total_bytes: " + e); }
            return err(name + ": " + e);
        }
        total = total + len(sql);
        let parsed = migsql.statements(sql);
        guard let _ss = parsed else let e = err_of(parsed) { return err(name + ": " + e); }
        let m = new_migration(v, name, sql);
        let pos = len(out);
        push(out, m);
        while pos > 0 && out[pos - 1].version > v { out[pos] = out[pos - 1]; pos = pos - 1; }
        out[pos] = m;
    }
    let checked = migration_validate(out);
    guard let _c = checked else let e = err_of(checked) { return err(e); }
    return ok(out);
}

fn migration_validate(ms: [Migration]) -> result[int, str] {
    let prev = 0;
    for m in ms {
        if m.version <= prev || (migsql.version(m.name) ?? -1) != m.version {
            return err("migrations must have unique, increasing versions matching their filenames");
        }
        if m.checksum != migration_checksum(m.sql) { return err(m.name + ": checksum does not match SQL"); }
        let parsed = migsql.statements(m.sql);
        guard let _ss = parsed else let e = err_of(parsed) { return err(m.name + ": " + e); }
        prev = m.version;
    }
    return ok(0);
}

// Validate all historical files, then apply the pending batch in one
// transaction under a database-wide advisory lock. Returns the applied
// count; error or panic rolls back the entire batch and releases the lock.
pub fn migrate(p: pg.Pool, ms: [Migration], deadline: until) -> result[int, str] {
    let checked = migration_validate(ms);
    guard let _c = checked else let e = err_of(checked) { return err(e); }
    return transaction(p, MigrationRun { migrations: ms, deadline: deadline }, migration_run, deadline);
}

gc struct MigrationRun { migrations: [Migration], deadline: until }

fn migration_run(c: pg.Conn, run: MigrationRun) -> result[int, str] {
    let d = run.deadline;
    // The snapshot must see a runner that committed while we waited for
    // the lock, even when the database defaults to repeatable read.
    let setup = pg.exec(c, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED; SET LOCAL standard_conforming_strings = on", d);
    guard let _s = setup else let e = err_of(setup) { return err(e); }
    let args: [pg.Arg] = [];
    let locked = pg.query(c, "select pg_advisory_xact_lock(2054123378, 1)", args, d);
    guard let _l = locked else let e = err_of(locked) { return err(e); }
    let created = pg.exec(c, "create table if not exists public.zokor_schema_migrations (version bigint primary key, name text not null, checksum text not null, applied_at timestamptz not null default current_timestamp)", d);
    guard let _t = created else let e = err_of(created) { return err(e); }
    let history = pg.query(c, "select version, name, checksum from public.zokor_schema_migrations order by version limit $1", [pg.arg_int(len(run.migrations) + 1)], d);
    guard let rows = history else let e = err_of(history) { return err(e); }
    if rows.count > len(run.migrations) { return err("applied migration is missing from the directory"); }
    let i = 0;
    while i < rows.count {
        let m = run.migrations[i];
        if m.version != pg.get_int(rows, i, 0) { return err("applied migration is missing or a version was inserted into history"); }
        if m.name != pg.get_text(rows, i, 1) || m.checksum != pg.get_text(rows, i, 2) { return err(m.name + ": applied migration changed; restore the original file and add a new migration"); }
        i = i + 1;
    }
    let applied = 0;
    while i < len(run.migrations) {
        let m = run.migrations[i];
        let parsed = migsql.statements(m.sql);
        guard let ss = parsed else let e = err_of(parsed) { return err(m.name + ": " + e); }
        for sql in ss {
            let rr = pg.query(c, sql, args, d);
            guard let _r = rr else let e = err_of(rr) { return err(m.name + ": " + e); }
        }
        let saved = pg.query(c, "insert into public.zokor_schema_migrations (version, name, checksum) values ($1, $2, $3)", [pg.arg_int(m.version), pg.arg_text(m.name), pg.arg_text(m.checksum)], d);
        guard let _h = saved else let e = err_of(saved) { return err(e); }
        applied = applied + 1;
        i = i + 1;
    }
    return ok(applied);
}
