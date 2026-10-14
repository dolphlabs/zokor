// Migration names and SQL boundaries, independent of files and databases.
import "strings";

fn letter(b: int) -> bool {
    return (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95;
}

fn digit(b: int) -> bool { return b >= 48 && b <= 57; }

// Positive numeric prefix, an ASCII description, and .sql; no paths.
pub fn version(name: str) -> opt[int] {
    if len(name) > 128 || !strings.has_suffix(name, ".sql") { return none; }
    let b = to_bytes(name);
    let i = 0;
    while i < len(b) && digit(b[i] as int) { i = i + 1; }
    if i == 0 || i + 5 >= len(b) || b[i] != 95 { return none; }
    let n = to_int(strings.slice(name, 0, i));
    guard let v = n else { return none; }
    if v <= 0 { return none; }
    i = i + 1;
    while i < len(b) - 4 {
        let c = b[i] as int;
        if !letter(c) && !digit(c) && c != 45 { return none; }
        i = i + 1;
    }
    return some(v);
}

fn forbidden(word: str) -> bool {
    return word == "begin" || word == "start" || word == "commit" || word == "end" ||
        word == "rollback" || word == "abort" || word == "savepoint" || word == "release" ||
        word == "prepare" || word == "set" || word == "reset" || word == "discard" || word == "copy";
}

fn dollar_end(b: bytes, start: int, tag_start: int, tag_len: int) -> int {
    let i = start;
    while i <= len(b) - tag_len {
        if b[i] != 36 { i = i + 1; continue; }
        let j = 1;
        while j < tag_len && b[i + j] == b[tag_start + j] { j = j + 1; }
        if j == tag_len { return i + tag_len; }
        // A tag has no interior '$', so no possible opening delimiter
        // is skipped. Each body byte is examined at most twice.
        i = i + j;
    }
    return -1;
}

// Split outside quotes/comments. Each result is sent through pg.query,
// whose extended protocol refuses multiple commands in one statement.
// Transaction/session control belongs to the runner, never to a file.
pub fn statements(sql: str) -> result[[str], str] {
    let b = to_bytes(sql);
    for c in b { if c == 0 { return err("SQL contains NUL; remove it"); } }
    let out: [str] = [];
    let i = 0;
    let start = 0;
    let first = true;
    while i < len(b) {
        let c = b[i] as int;
        if c == 32 || c == 9 || c == 10 || c == 13 || c == 12 { i = i + 1; continue; }
        if c == 45 && i + 1 < len(b) && b[i + 1] == 45 {
            i = i + 2;
            while i < len(b) && b[i] != 10 && b[i] != 13 { i = i + 1; }
            continue;
        }
        if c == 47 && i + 1 < len(b) && b[i + 1] == 42 {
            let depth = 1;
            i = i + 2;
            while i < len(b) && depth > 0 {
                if i + 1 < len(b) && b[i] == 47 && b[i + 1] == 42 { depth = depth + 1; i = i + 2; }
                else if i + 1 < len(b) && b[i] == 42 && b[i + 1] == 47 { depth = depth - 1; i = i + 2; }
                else { i = i + 1; }
            }
            if depth != 0 { return err("unterminated SQL comment; add */"); }
            continue;
        }
        if c == 59 {
            if !first { push(out, strings.slice(sql, start, i)); }
            i = i + 1; start = i; first = true;
            continue;
        }
        if first {
            if !letter(c) { return err("SQL command must start with a keyword"); }
            let end = i + 1;
            while end < len(b) && (letter(b[end] as int) || digit(b[end] as int) || b[end] == 36) { end = end + 1; }
            let word = strings.to_lower(strings.slice(sql, i, end));
            if forbidden(word) { return err("migration cannot use " + word + "; the runner owns transaction and session control"); }
            first = false;
        }
        if c == 39 || c == 34 {
            let escape = c == 39 && i > 0 && (b[i - 1] == 69 || b[i - 1] == 101) &&
                (i < 2 || (!letter(b[i - 2] as int) && !digit(b[i - 2] as int) && b[i - 2] != 36));
            i = i + 1;
            let closed = false;
            while i < len(b) {
                if escape && b[i] == 92 { i = i + 2; continue; }
                if (b[i] as int) == c {
                    if i + 1 < len(b) && (b[i + 1] as int) == c { i = i + 2; continue; }
                    closed = true; i = i + 1; break;
                }
                i = i + 1;
            }
            if !closed { return err("unterminated SQL quote; close it"); }
            continue;
        }
        if c == 36 && (i == 0 || (!letter(b[i - 1] as int) && !digit(b[i - 1] as int) && b[i - 1] != 36)) {
            let end = i + 1;
            if end < len(b) && letter(b[end] as int) {
                end = end + 1;
                while end < len(b) && (letter(b[end] as int) || digit(b[end] as int)) { end = end + 1; }
            }
            if end < len(b) && b[end] == 36 {
                let at = dollar_end(b, end + 1, i, end + 1 - i);
                if at < 0 { return err("unterminated dollar quote; add " + strings.slice(sql, i, end + 1)); }
                i = at;
                continue;
            }
        }
        i = i + 1;
    }
    if !first { push(out, strings.slice(sql, start, len(b))); }
    if len(out) == 0 { return err("migration has no SQL statements"); }
    return ok(out);
}
