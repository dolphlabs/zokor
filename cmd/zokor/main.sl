import "../../zokor" as zokor;
import "proc";
import "io";
import "time";

fn cli_int(cfg: zokor.Config, key: str, fallback: int) -> int {
    if !zokor.has_key(cfg, key) { return fallback; }
    return zokor.require_int(cfg, key);
}

fn main() {
    let args = proc.args();
    if len(args) < 2 || len(args) > 3 || args[1] != "migrate" {
        io.eprintln("usage: zokor migrate [directory] (default: migrations; DATABASE_URL required)");
        exit(2);
    }
    let dir = "migrations";
    if len(args) == 3 { dir = args[2]; }
    let cfg = zokor.load_config();
    let limits = zokor.migration_limits();
    limits.max_files = cli_int(cfg, "MIGRATION_MAX_FILES", limits.max_files);
    limits.max_file_bytes = cli_int(cfg, "MIGRATION_MAX_FILE_BYTES", limits.max_file_bytes);
    limits.max_total_bytes = cli_int(cfg, "MIGRATION_MAX_TOTAL_BYTES", limits.max_total_bytes);
    let seconds = cli_int(cfg, "MIGRATION_TIMEOUT_SECONDS", 60);
    let checked = zokor.check(cfg);
    guard let _ok = checked else let e = err_of(checked) { io.eprintln(e); exit(2); }
    if seconds < 1 || seconds > 86400 { io.eprintln("MIGRATION_TIMEOUT_SECONDS must be 1..86400"); exit(2); }
    let loaded = zokor.load_migrations(dir, limits);
    guard let ms = loaded else let e = err_of(loaded) { io.eprintln(e); exit(1); }
    let opened = zokor.pg_from_config(cfg);
    guard let p = opened else let e = err_of(opened) { io.eprintln(e); exit(1); }
    let migrated = zokor.migrate(p, ms, until_of(time.mono() + seconds * 1000000000));
    zokor.pg_close(p);
    guard let n = migrated else let e = err_of(migrated) { io.eprintln(e); exit(1); }
    println("applied " + to_str(n) + " migrations");
}

main();
