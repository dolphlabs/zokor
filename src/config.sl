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
//     let cfg = zokor.load_config();                 // ".env", then the environment
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
import "proc";
import "internal/envfile";
import "internal/validate" as rules;

pub gc struct Problem {
    key: str,
    reason: str,
    // The value as read, with anything secret-looking masked, so the
    // report can be logged without leaking a password.
    shown: str,
}

pub gc struct Config {
    values: map[str]str,   // what the file provided
    problems: [Problem],
    source: str,           // the file it read, or "" for environment only
}

// The default file name, used by `load_config`. An application that
// wants another path calls `load_config_from`.
pub fn default_env_path() -> str {
    return ".env";
}

// `.env` if present, then the environment -- which always wins, so a
// shell override does what it looks like it does and a deployment that
// ships no file behaves the same way.
pub fn load_config() -> Config {
    return load_config_from(default_env_path());
}

// The same, from a path of your choosing (".env.test", "/etc/app/env").
// A missing file is not an error: the environment alone is a valid
// source, and that is what production usually looks like.
pub fn load_config_from(path: str) -> Config {
    let probs: [Problem] = [];
    let empty: map[str]str = {};
    if len(path) == 0 || !os.is_file(path) {
        return Config { values: empty, problems: probs, source: "" };
    }
    let text = read_file(path);
    guard let body = text else let e = err_of(text) {
        push(probs, Problem { key: path, reason: e, shown: "" });
        return Config { values: empty, problems: probs, source: path };
    }
    return Config {
        values: envfile.parse(body),
        problems: probs,
        source: path
    };
}

fn read_file(path: str) -> result[str, str] {
    let sr = os.size(path);
    guard let n = sr else let e = err_of(sr) {
        return err("cannot read " + path + ": " + e);
    }
    let orr = fs.open(path);
    guard let fd = orr else let e = err_of(orr) {
        return err("cannot open " + path + ": " + e);
    }
    let out: bytes = b"";
    let left = n;
    while left > 0 {
        let rr = fs.read(fd, left);
        guard let chunk = rr else let e = err_of(rr) {
            fs.close(fd);
            return err("cannot read " + path + ": " + e);
        }
        if len(chunk) == 0 {
            left = 0;
        } else {
            out = out + chunk;
            left = left - len(chunk);
        }
    }
    fs.close(fd);
    return ok(to_str(out));
}

// ---------------------------------------------------------------- //
// Reading                                                            //
// ---------------------------------------------------------------- //

pub fn get(c: Config, key: str) -> opt[str] {
    let env = proc.getenv(key) ?? "";
    if len(env) > 0 {
        return some(env);
    }
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
    let l = rules.lower(s);
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
    return rules.duration_ns(s, fallback_ns);
}

// ---------------------------------------------------------------- //
// Requiring, with a rule                                             //
// ---------------------------------------------------------------- //

// A key whose name says it holds a secret is never echoed back in a
// problem report, because those reports get logged.
fn mask(key: str, value: str) -> str {
    let k = rules.lower(key);
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
    return checked(c, key, rules.is_string(s), s);
}

pub fn require_int(c: Config, key: str) -> int {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return 0;
    }
    checked(c, key, rules.is_int(s), s);
    return to_int(s) ?? 0;
}

pub fn require_range(c: Config, key: str, lo: int, hi: int) -> int {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return lo;
    }
    checked(c, key, rules.in_range(s, lo, hi), s);
    return to_int(s) ?? lo;
}

pub fn require_port(c: Config, key: str) -> int {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return 0;
    }
    checked(c, key, rules.is_port(s), s);
    return to_int(s) ?? 0;
}

pub fn require_bool(c: Config, key: str) -> bool {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return false;
    }
    checked(c, key, rules.is_bool(s), s);
    return bool_or(c, key, false);
}

pub fn require_float(c: Config, key: str) -> float {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return 0.0;
    }
    checked(c, key, rules.is_float(s), s);
    return to_float(s) ?? 0.0;
}

pub fn require_email(c: Config, key: str) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, rules.is_email(s), s);
}

pub fn require_url(c: Config, key: str) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, rules.is_url(s), s);
}

pub fn require_dsn(c: Config, key: str) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, rules.is_dsn(s), s);
}

pub fn require_host(c: Config, key: str) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, rules.is_host(s), s);
}

pub fn require_ipv4(c: Config, key: str) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, rules.is_ipv4(s), s);
}

pub fn require_uuid(c: Config, key: str) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, rules.is_uuid(s), s);
}

pub fn require_one_of(c: Config, key: str, allowed: [str]) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, rules.is_one_of(s, allowed), s);
}

pub fn require_duration(c: Config, key: str) -> int {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return 0;
    }
    checked(c, key, rules.is_duration(s), s);
    return rules.duration_ns(s, 0);
}

pub fn require_min_len(c: Config, key: str, n: int) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, rules.min_len(s, n), s);
}

pub fn require_max_len(c: Config, key: str, n: int) -> str {
    guard let s = get(c, key) else {
        record(c, key, "", "is required but not set");
        return "";
    }
    return checked(c, key, rules.max_len(s, n), s);
}

// An optional value that still has to be valid WHEN it is set: the
// common case of a feature that is off until configured.
pub fn optional_one_of(c: Config, key: str, allowed: [str],
                       fallback: str) -> str {
    guard let s = get(c, key) else {
        return fallback;
    }
    return checked(c, key, rules.is_one_of(s, allowed), s);
}

pub fn optional_url(c: Config, key: str, fallback: str) -> str {
    guard let s = get(c, key) else {
        return fallback;
    }
    return checked(c, key, rules.is_url(s), s);
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
    if len(c.source) > 0 {
        where = c.source + " and the environment";
    }
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
