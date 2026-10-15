import "../../zokor" as zokor;
import "proc";
import "io";
import "time";

fn usage() -> str {
    return "usage:\n" +
           "  zokor new <name> [--db pg] [--zokor-git URL] [--zokor-tag TAG]\n" +
           "  zokor add feature <name> [--entity <singular>]\n" +
           "  zokor migrate [directory]   (default: migrations; DATABASE_URL required)";
}

fn fail_usage(why: str) {
    if len(why) > 0 {
        io.eprintln("zokor: " + why);
    }
    io.eprintln(usage());
    exit(2);
}

fn cli_int(cfg: zokor.Config, key: str, fallback: int) -> int {
    if !zokor.has_key(cfg, key) { return fallback; }
    return zokor.require_int(cfg, key);
}

fn migrate_cmd(args: [str]) {
    if len(args) > 3 {
        fail_usage("migrate takes at most one directory");
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

// The value after `flag` in args[from..], or `fallback`; the flags it
// knows are consumed, anything else is a usage error.
gc struct Flags {
    values: map[str]str,
    rest: [str],
}

fn parse_flags(args: [str], from: int, known: [str]) -> Flags {
    let values: map[str]str = {};
    let rest: [str] = [];
    let i = from;
    while i < len(args) {
        let a = args[i];
        let is_known = false;
        for k in known {
            if a == k { is_known = true; }
        }
        if is_known {
            if i + 1 >= len(args) {
                fail_usage(a + " needs a value");
            }
            values[a] = args[i + 1];
            i = i + 2;
        } else if strings_has_prefix(a, "--") {
            fail_usage("unknown option " + a);
        } else {
            push(rest, a);
            i = i + 1;
        }
    }
    return Flags { values: values, rest: rest };
}

fn strings_has_prefix(s: str, p: str) -> bool {
    let a = to_bytes(s);
    let b = to_bytes(p);
    if len(b) > len(a) { return false; }
    return a[0..len(b)] == b;
}

fn flag(f: Flags, name: str, fallback: str) -> str {
    if has(f.values, name) { return f.values[name]; }
    return fallback;
}

fn report(written: [str], root: str) {
    for w in written {
        println("  wrote " + root + w);
    }
}

fn new_cmd(args: [str]) {
    let f = parse_flags(args, 2, ["--db", "--zokor-git", "--zokor-tag"]);
    if len(f.rest) != 1 {
        fail_usage("new takes one service name");
    }
    let db = flag(f, "--db", "memory");
    if db != "memory" && db != "pg" {
        fail_usage("--db is memory (the default) or pg");
    }
    let name = f.rest[0];
    let r = new_project(name, db == "pg", flag(f, "--zokor-git", default_git()),
                        flag(f, "--zokor-tag", default_tag()));
    guard let written = r else let e = err_of(r) {
        io.eprintln("zokor: " + e);
        exit(1);
    }
    report(written, name + "/");
    println("created " + name + ": cd " + name + " && slangc get && make test");
}

fn add_cmd(args: [str]) {
    if len(args) < 3 || args[2] != "feature" {
        fail_usage("add takes: feature <name>");
    }
    let f = parse_flags(args, 3, ["--entity"]);
    if len(f.rest) != 1 {
        fail_usage("add feature takes one feature name");
    }
    let feature = f.rest[0];
    let why = feature_name_problem(feature);
    if len(why) > 0 {
        io.eprintln("zokor: " + why);
        exit(2);
    }
    let entity = flag(f, "--entity", singular(feature));
    let ew = entity_name_problem(entity);
    if len(ew) > 0 {
        io.eprintln("zokor: " + ew);
        exit(2);
    }
    if entity == feature {
        io.eprintln("zokor: the entity must differ from the feature name (" + feature +
                    "): pass --entity, e.g. --entity item");
        exit(2);
    }
    let sr = service_of(".");
    guard let service = sr else let e = err_of(sr) {
        io.eprintln("zokor: " + e);
        exit(1);
    }
    let r = add_feature_at(".", feature_vars(service, feature, entity, "."));
    guard let written = r else let e = err_of(r) {
        io.eprintln("zokor: " + e);
        exit(1);
    }
    report(written, "");
    println("added " + feature + " (wired into src/platform/app/app.sl and src/main.sl)");
}

fn main() {
    let args = proc.args();
    if len(args) < 2 {
        fail_usage("");
    }
    let cmd = args[1];
    if cmd == "migrate" {
        migrate_cmd(args);
    } else if cmd == "new" {
        new_cmd(args);
    } else if cmd == "add" {
        add_cmd(args);
    } else {
        fail_usage("unknown command '" + cmd + "'");
    }
}

main();
