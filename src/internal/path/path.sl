// Path work, kept pure so it is cheap to test and cheap to run.
//
// Every function here is called on the request path, once per request,
// so none of them allocates more than it must: no regular expressions,
// no repeated scans, and no copies of segments that match literally.

// Splits "/orgs/7/keys" into ["orgs", "7", "keys"], skipping empty
// segments so "/a//b/" and "/a/b" are one route rather than two.
//
// One pass over the bytes, one allocation per segment, and nothing for
// the separators.
import "builder";

pub fn split(p: str) -> [str] {
    let out: [str] = [];
    let b = to_bytes(p);
    let n = len(b);
    let start = 0;
    let i = 0;
    while i <= n {
        if i == n || b[i] == 47 {
            if i > start {
                push(out, to_str(b[start..i]));
            }
            start = i + 1;
        }
        i = i + 1;
    }
    return out;
}

// The path without its query string. Returns the same string when there
// is no "?", so the common case costs one scan and no allocation.
pub fn strip_query(p: str) -> str {
    let b = to_bytes(p);
    let n = len(b);
    let i = 0;
    while i < n {
        if b[i] == 63 {
            return to_str(b[0..i]);
        }
        i = i + 1;
    }
    return p;
}

// The query string, without the "?", or "".
pub fn query_of(p: str) -> str {
    let b = to_bytes(p);
    let n = len(b);
    let i = 0;
    while i < n {
        if b[i] == 63 {
            return to_str(b[i + 1..n]);
        }
        i = i + 1;
    }
    return "";
}

// One value from a query string, percent-decoded, or "" when absent.
// Scans the pairs in place rather than splitting the whole string.
pub fn query_get(qs: str, name: str) -> str {
    let b = to_bytes(qs);
    let n = len(b);
    let start = 0;
    let i = 0;
    while i <= n {
        if i == n || b[i] == 38 {
            if i > start {
                let eq = start;
                let found = -1;
                while eq < i {
                    if b[eq] == 61 {
                        found = eq;
                        eq = i;
                    } else {
                        eq = eq + 1;
                    }
                }
                if found < 0 {
                    if to_str(b[start..i]) == name {
                        return "";
                    }
                } else {
                    if to_str(b[start..found]) == name {
                        return percent_decode(to_str(b[found + 1..i]));
                    }
                }
            }
            start = i + 1;
        }
        i = i + 1;
    }
    return "";
}

// Every key and value from a query string, percent-decoded. A repeated
// key keeps its LAST value, the same rule browsers use for a form's own
// repeated fields. A key with no `=` gets "", same as `query_get`.
pub fn query_all(qs: str) -> map[str]str {
    let out: map[str]str = {};
    let b = to_bytes(qs);
    let n = len(b);
    let start = 0;
    let i = 0;
    while i <= n {
        if i == n || b[i] == 38 {
            if i > start {
                let eq = start;
                let found = -1;
                while eq < i {
                    if b[eq] == 61 {
                        found = eq;
                        eq = i;
                    } else {
                        eq = eq + 1;
                    }
                }
                if found < 0 {
                    out[to_str(b[start..i])] = "";
                } else {
                    out[to_str(b[start..found])] =
                        percent_decode(to_str(b[found + 1..i]));
                }
            }
            start = i + 1;
        }
        i = i + 1;
    }
    return out;
}

fn hex_val(c: int) -> int {
    if c >= 48 && c <= 57 {
        return c - 48;
    }
    if c >= 97 && c <= 102 {
        return c - 87;
    }
    if c >= 65 && c <= 70 {
        return c - 55;
    }
    return -1;
}

// "%20" and "+" decoding. Returns the input unchanged when there is
// nothing to decode, which is the usual case.
//
// The clean stretches between escapes are copied as slices and each
// escape is one byte, through a builder, so this is linear. (It used to
// append one byte at a time with `+`: 128 KB of escapes took two
// seconds.)
pub fn percent_decode(s: str) -> str {
    let b = to_bytes(s);
    let n = len(b);
    let i = 0;
    while i < n {
        if b[i] == 37 || b[i] == 43 {
            break;
        }
        i = i + 1;
    }
    if i == n {
        return s;
    }
    let out = builder.new_bytes();
    let start = 0;
    i = 0;
    while i < n {
        let c = b[i];
        if c == 43 {
            if i > start {
                out.write(b[start..i]);
            }
            out.write_byte(32);
            i = i + 1;
            start = i;
            continue;
        }
        if c == 37 && i + 2 < n {
            let hi = hex_val(b[i + 1]);
            let lo = hex_val(b[i + 2]);
            if hi >= 0 && lo >= 0 {
                if i > start {
                    out.write(b[start..i]);
                }
                out.write_byte(hi * 16 + lo);
                i = i + 3;
                start = i;
                continue;
            }
        }
        i = i + 1;
    }
    if n > start {
        out.write(b[start..n]);
    }
    return to_str(out.finish());
}

// Is this pattern segment a parameter (":id"), and if so what is its
// name? Returns "" for a literal segment.
pub fn param_name(seg: str) -> str {
    let b = to_bytes(seg);
    if len(b) > 1 && b[0] == 58 {
        return to_str(b[1..len(b)]);
    }
    return "";
}

// Is this pattern segment a wildcard tail ("*rest")?
pub fn wildcard_name(seg: str) -> str {
    let b = to_bytes(seg);
    if len(b) > 1 && b[0] == 42 {
        return to_str(b[1..len(b)]);
    }
    return "";
}
