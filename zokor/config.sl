// Configuration: read once, validated once, then held as a value.
//
// Two rules this API exists to enforce.
//
// **Nothing reads the environment while serving.** A handler that calls
// getenv changes behaviour without a deploy and cannot be tested without
// setting process state, so every value is taken at startup and kept in
// a Config the application passes around.
//
// **Every problem is reported at once.** A service with six unset
// variables should say so once, not fail, get one fixed, and fail again
// on the next -- six restarts to learn six facts. Each `require_*` call
// records what it found; `check` returns every failure together.
//
//     let cfg = zokor.load_config();                 // base, profile, startup environment
//     let port = zokor.require_port(cfg, "PORT");
//     let dsn  = zokor.require_dsn(cfg, "DATABASE_URL");
//     let from = zokor.require_email(cfg, "ALERT_FROM");
//     let mode = zokor.require_one_of(cfg, "MODE", ["dev", "prod"]);
//     guard let _ok = zokor.check(cfg) else let e = err_of(zokor.check(cfg)) {
//         log.error(e);
//         exit(1);
//     }

import "fs";
import "os";
import "strings";
import "builder";
import "internal/envfile";
import "internal/validate" as valid;

pub gc struct Problem {
    key: str,
    reason: str,
    // The value as read, with anything secret-looking masked, so the
    // report can be logged without leaking a password.
    shown: str,
}

pub gc struct Config {
    values: map[str]str,   // effective startup snapshot: files, then environment
    problems: [Problem],
    source: str,           // last regular file attempted, or "" for environment only
    profile: str,          // effective profile, or "" for a single-file load
    sources: [str],        // regular files attempted, in precedence order
}

// Profile selection and file limits, chosen before startup loading.
// Empty profile selects ZOKOR_PROFILE, defaulting to dev; explicit wins.
pub gc struct ConfigLoad {
    profile: str,
    directory: str,
    max_file_bytes: int,
}

pub fn config_load() -> ConfigLoad {
    return ConfigLoad { profile: "", directory: ".", max_file_bytes: 1048576 };
}

// Own a copy of supplied values, with no process-state reads: useful for fakes.
pub fn config_from_values(values: map[str]str) -> Config {
    let copy: map[str]str = {};
    for key, value in values { copy[key] = value; }
    return Config { values: copy, problems: [], source: "", profile: "", sources: [] };
}

pub fn default_env_path() -> str { return ".env"; }

// Base .env, then .env.<profile>, then one environment snapshot.
pub fn load_config() -> Config { return load_config_with(config_load()); }

// Explicit dev/test/prod overrides ZOKOR_PROFILE for file selection.
pub fn load_config_profile(profile: str) -> Config {
    if len(profile) == 0 {
        let cfg = load_config_from("");
        record(cfg, "ZOKOR_PROFILE", profile, "must be one of: dev, test, prod");
        return cfg;
    }
    let options = config_load();
    options.profile = profile;
    return load_config_with(options);
}

fn config_environment() -> map[str]str { return envfile.environment(os.environ()); }

fn config_profile_ok(profile: str) -> bool {
    return profile == "dev" || profile == "test" || profile == "prod";
}

fn config_path(directory: str, name: str) -> str {
    if directory == "." { return name; }
    if strings.has_suffix(directory, "/") { return directory + name; }
    return directory + "/" + name;
}

// Missing files are optional; present files must be regular and within limits.
fn config_read(path: str, cap: int) -> result[str, str] {
    let opened = fs.open(path);
    guard let fd = opened else let e = err_of(opened) { return err("cannot open " + path + ": " + e); }
    let st = fs.fstat(fd);
    if len(st) != 4 || st[0] != 0 {
        fs.close(fd); return err("must be a regular file");
    }
    if st[1] > cap { fs.close(fd); return err("exceeds max_file_bytes"); }
    let bb = builder.new_bytes();
    let read = 0;
    while read <= cap {
        let want = cap - read + 1;
        if want > 65536 { want = 65536; }
        let rr = fs.read(fd, want);
        guard let chunk = rr else let e = err_of(rr) { fs.close(fd); return err("cannot read " + path + ": " + e); }
        if len(chunk) == 0 { fs.close(fd); return ok(to_str(bb.finish())); }
        for byte in chunk { if byte == 0 { fs.close(fd); return err("contains NUL; remove it"); } }
        read += len(chunk);
        if read > cap { fs.close(fd); return err("exceeds max_file_bytes"); }
        bb.write(chunk);
    }
    fs.close(fd);
    return err("exceeds max_file_bytes");
}

fn config_apply_file(cfg: Config, path: str, cap: int) {
    if !os.exists(path) { return; }
    if !os.is_file(path) { push(cfg.problems, Problem { key: path, reason: "must be a regular file", shown: "" }); return; }
    push(cfg.sources, path);
    cfg.source = path;
    let loaded = config_read(path, cap);
    guard let text = loaded else let e = err_of(loaded) { push(cfg.problems, Problem { key: path, reason: e, shown: "" }); return; }
    for key, value in envfile.parse(text) { cfg.values[key] = value; }
}

fn config_apply_environment(cfg: Config, snapshot: map[str]str) {
    // Empty values are real overrides; require_* reports them as invalid.
    for key, value in snapshot { cfg.values[key] = value; }
}

pub fn load_config_with(options: ConfigLoad) -> Config {
    let snapshot = config_environment();
    let empty_values: map[str]str = {};
    let cfg = config_from_values(empty_values);
    if len(options.directory) == 0 { record(cfg, "directory", "", "must not be empty"); }
    if options.max_file_bytes < 1 || options.max_file_bytes == 9223372036854775807 {
        record(cfg, "max_file_bytes", to_str(options.max_file_bytes), "must be positive and below the integer maximum");
    }
    let can_read = len(options.directory) > 0 && options.max_file_bytes >= 1 && options.max_file_bytes < 9223372036854775807;
    if can_read { config_apply_file(cfg, config_path(options.directory, default_env_path()), options.max_file_bytes); }
    let profile = options.profile;
    if len(profile) == 0 {
        profile = "dev";
        if has(snapshot, "ZOKOR_PROFILE") { profile = snapshot["ZOKOR_PROFILE"]; }
        else if has(cfg.values, "ZOKOR_PROFILE") { profile = cfg.values["ZOKOR_PROFILE"]; }
    }
    if !config_profile_ok(profile) { record(cfg, "ZOKOR_PROFILE", profile, "must be one of: dev, test, prod"); }
    else {
        cfg.profile = profile;
        if can_read { config_apply_file(cfg, config_path(options.directory, ".env." + profile), options.max_file_bytes); }
    }
    config_apply_environment(cfg, snapshot);
    return cfg;
}

// Load one explicit file, then apply the captured environment; no profile overlay.
// A missing file is valid. For a caller-selected limit, use the bounded variant.
pub fn load_config_from(path: str) -> Config { return load_config_file(path, config_load().max_file_bytes); }

pub fn load_config_file(path: str, max_file_bytes: int) -> Config {
    let snapshot = config_environment();
    let empty_values: map[str]str = {};
    let cfg = config_from_values(empty_values);
    if max_file_bytes < 1 || max_file_bytes == 9223372036854775807 {
        record(cfg, "max_file_bytes", to_str(max_file_bytes), "must be positive and below the integer maximum");
    } else if len(path) > 0 { config_apply_file(cfg, path, max_file_bytes); }
    config_apply_environment(cfg, snapshot);
    return cfg;
}

// ---------------------------------------------------------------- //
// Reading                                                            //
// ---------------------------------------------------------------- //

pub fn get(c: Config, key: str) -> opt[str] {
    if has(c.values, key) {
        return some(c.values[key]);
    }
    return none;
}

pub fn has_key(c: Config, key: str) -> bool {
    guard let _v = get(c, key) else {
        return false;
    }
    return true;
}

pub fn str_or(c: Config, key: str, fallback: str) -> str {
    return get(c, key) ?? fallback;
}

pub fn int_or(c: Config, key: str, fallback: int) -> int {
    guard let s = get(c, key) else {
        return fallback;
    }
    return to_int(s) ?? fallback;
}

pub fn bool_or(c: Config, key: str, fallback: bool) -> bool {
    guard let s = get(c, key) else {
        return fallback;
    }
    let l = valid.lower(s);
    if l == "1" || l == "true" || l == "yes" || l == "on" {
        return true;
    }
    if l == "0" || l == "false" || l == "no" || l == "off" {
        return false;
    }
    return fallback;
}

// A duration in nanoseconds, the unit every slang timeout takes.
pub fn duration_or(c: Config, key: str, fallback_ns: int) -> int {
    guard let s = get(c, key) else {
        return fallback_ns;
    }
    return valid.duration_ns(s, fallback_ns);
}

// ---------------------------------------------------------------- //
// Requiring, with a rule                                             //
// ---------------------------------------------------------------- //

// A key whose name says it holds a secret is never echoed back in a
// problem report, because those reports get logged.
fn mask(key: str, value: str) -> str {
    let k = valid.lower(key);
    let secret = contains(k, "secret") || contains(k, "password") ||
                 contains(k, "token") || contains(k, "key") ||
                 contains(k, "dsn") || contains(k, "url") ||
                 contains(k, "credential");
    if !secret {
        return "'" + value + "'";
    }
    if len(value) == 0 {
        return "(empty)";
    }
    return "(" + to_str(len(value)) + " characters, hidden)";
}

// One substring search for the package: config masks secrets with it,
// uploads classify a parse failure with it.
fn contains(hay: str, needle: str) -> bool {
    let a = to_bytes(hay);
    let b = to_bytes(needle);
    let n = len(a);
    let m = len(b);
    if m == 0 || m > n {
        return false;
    }
    let i = 0;
    while i + m <= n {
        let j = 0;
        while j < m && a[i + j] == b[j] {
            j = j + 1;
        }
        if j == m {
            return true;
        }
        i = i + 1;
    }
    return false;
}

fn record(c: Config, key: str, value: str, reason: str) {
    push(c.problems, Problem {
        key: key,
        reason: reason,
        shown: mask(key, value)
    });
}

// The one path every `require_*` goes through: read it, and if it is
// there, run the rule. Absent and invalid are different problems and
// read differently in the report.
fn checked(c: Config, key: str, r: result[bool, str], value: str) -> str {
    guard let _ok = r else let e = err_of(r) {
        record(c, key, value, e);
        return value;
    }
    return value;
}

pub fn require(c: Config, key: str) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, valid.is_string(s), s);
}

pub fn require_int(c: Config, key: str) -> int {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return 0;
    }
    checked(c, key, valid.is_int(s), s);
    return to_int(s) ?? 0;
}

pub fn require_range(c: Config, key: str, lo: int, hi: int) -> int {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return lo;
    }
    checked(c, key, valid.in_range(s, lo, hi), s);
    return to_int(s) ?? lo;
}

pub fn require_port(c: Config, key: str) -> int {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return 0;
    }
    checked(c, key, valid.is_port(s), s);
    return to_int(s) ?? 0;
}

pub fn require_bool(c: Config, key: str) -> bool {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return false;
    }
    checked(c, key, valid.is_bool(s), s);
    return bool_or(c, key, false);
}

pub fn require_float(c: Config, key: str) -> float {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return 0.0;
    }
    checked(c, key, valid.is_float(s), s);
    return to_float(s) ?? 0.0;
}

pub fn require_email(c: Config, key: str) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, valid.is_email(s), s);
}

pub fn require_url(c: Config, key: str) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, valid.is_url(s), s);
}

pub fn require_dsn(c: Config, key: str) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, valid.is_dsn(s), s);
}

pub fn require_host(c: Config, key: str) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, valid.is_host(s), s);
}

pub fn require_ipv4(c: Config, key: str) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, valid.is_ipv4(s), s);
}

pub fn require_uuid(c: Config, key: str) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, valid.is_uuid(s), s);
}

pub fn require_one_of(c: Config, key: str, allowed: [str]) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, valid.is_one_of(s, allowed), s);
}

pub fn require_duration(c: Config, key: str) -> int {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return 0;
    }
    checked(c, key, valid.is_duration(s), s);
    return valid.duration_ns(s, 0);
}

pub fn require_min_len(c: Config, key: str, n: int) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, valid.min_len(s, n), s);
}

pub fn require_max_len(c: Config, key: str, n: int) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, valid.max_len(s, n), s);
}

// An optional value that still has to be valid WHEN it is set: the
// common case of a feature that is off until configured.
pub fn optional_one_of(c: Config, key: str, allowed: [str],
                       fallback: str) -> str {
    guard let s = get(c, key) else {
        return fallback;
    }
    return checked(c, key, valid.is_one_of(s, allowed), s);
}

pub fn optional_url(c: Config, key: str, fallback: str) -> str {
    guard let s = get(c, key) else {
        return fallback;
    }
    return checked(c, key, valid.is_url(s), s);
}

// Same shape as optional_url, for a connection string rather than an
// HTTP one: `is_dsn` accepts any scheme with a host (redis://, amqp://,
// ...), where is_url would reject all of them. The dependency this
// gates is off by default (fallback, typically ""), on once configured
// -- REDIS_URL is the first caller.
pub fn optional_dsn(c: Config, key: str, fallback: str) -> str {
    guard let s = get(c, key) else {
        return fallback;
    }
    return checked(c, key, valid.is_dsn(s), s);
}

// ---------------------------------------------------------------- //
// The report                                                         //
// ---------------------------------------------------------------- //

pub fn problems(c: Config) -> [Problem] {
    return c.problems;
}

pub fn is_valid(c: Config) -> bool {
    return len(c.problems) == 0;
}

// Every problem, one per line, named and explained. This is what a
// service prints before refusing to start.
pub fn check(c: Config) -> result[bool, str] {
    if len(c.problems) == 0 {
        return ok(true);
    }
    let where = "the environment";
    if len(c.sources) > 0 { where = strings.join(c.sources, ", ") + " and the environment"; }
    else if len(c.source) > 0 { where = c.source + " and the environment"; }
    let out = "configuration is not usable (read from " + where + "):";
    let i = 0;
    while i < len(c.problems) {
        let p = c.problems[i];
        out = out + "\n  " + p.key + " " + p.reason;
        if len(p.shown) > 0 {
            out = out + ", got " + p.shown;
        }
        i = i + 1;
    }
    return err(out);
}
