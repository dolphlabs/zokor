// Parsing a `.env` file, kept separate from reading one so the parser
// is testable without touching a disk.
//
// The format is the one everyone already has in their repository:
//
//     # a comment
//     PORT=8080
//     NAME="with spaces"
//     EMPTY=
//     export DATABASE_URL=postgres://localhost/app
//
// `export ` is accepted because half the files in the world have it.
// A line without `=` is skipped rather than fatal: a `.env` is a
// developer convenience, and refusing to boot over a stray line in one
// is worse than ignoring it.

pub fn parse(text: str) -> map[str]str {
    let out: map[str]str = {};
    let b = to_bytes(text);
    let n = len(b);
    let start = 0;
    let i = 0;
    while i <= n {
        if i == n || b[i] == 10 {
            if i > start {
                let line = trim(to_str(b[start..i]));
                take_line(out, line);
            }
            start = i + 1;
        }
        i = i + 1;
    }
    return out;
}

fn take_line(out: map[str]str, line: str) {
    if len(line) == 0 || starts(line, "#") {
        return;
    }
    let body = line;
    if starts(line, "export ") {
        body = trim(cut(line, 7, len(line)));
    }
    let b = to_bytes(body);
    let n = len(b);
    let eq = -1;
    let i = 0;
    while i < n {
        if b[i] == 61 {
            eq = i;
            i = n;
        } else {
            i = i + 1;
        }
    }
    if eq <= 0 {
        return;
    }
    let key = trim(to_str(b[0..eq]));
    if len(key) == 0 {
        return;
    }
    out[key] = unquote(trim(to_str(b[eq + 1..n])));
}

// A quoted value keeps its spaces; an unquoted one loses a trailing
// comment, because `PORT=8080 # the port` is a value of "8080" to every
// other tool that reads these files.
fn unquote(v: str) -> str {
    let b = to_bytes(v);
    let n = len(b);
    if n >= 2 {
        let q = b[0];
        if (q == 34 || q == 39) && b[n - 1] == q {
            return to_str(b[1..n - 1]);
        }
    }
    let i = 0;
    while i < n {
        if b[i] == 35 && i > 0 && (b[i - 1] == 32 || b[i - 1] == 9) {
            return trim(to_str(b[0..i]));
        }
        i = i + 1;
    }
    return v;
}

fn starts(v: str, p: str) -> bool {
    let a = to_bytes(v);
    let b = to_bytes(p);
    if len(b) > len(a) {
        return false;
    }
    let i = 0;
    while i < len(b) {
        if a[i] != b[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn cut(v: str, from: int, to: int) -> str {
    let b = to_bytes(v);
    if from >= len(b) {
        return "";
    }
    return to_str(b[from..to]);
}

pub fn trim(v: str) -> str {
    let b = to_bytes(v);
    let n = len(b);
    let s = 0;
    while s < n && (b[s] == 32 || b[s] == 9 || b[s] == 13) {
        s = s + 1;
    }
    let e = n;
    while e > s && (b[e - 1] == 32 || b[e - 1] == 9 || b[e - 1] == 13) {
        e = e - 1;
    }
    if s == 0 && e == n {
        return v;
    }
    return to_str(b[s..e]);
}
