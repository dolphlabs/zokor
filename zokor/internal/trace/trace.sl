// W3C trace context parsing, independent of sockets, clocks and randomness.
import "strings";

pub struct Parent { trace_id: str, span_id: str, sampled: bool }

fn hex(c: int) -> int {
    if c >= 48 && c <= 57 { return c - 48; }
    if c >= 97 && c <= 102 { return c - 87; }
    return -1;
}

pub fn id_ok(value: str, size: int) -> bool {
    if len(value) != size { return false; }
    let nonzero = false;
    for c in to_bytes(value) {
        if hex(c as int) < 0 { return false; }
        if c != 48 { nonzero = true; }
    }
    return nonzero;
}

pub fn parent(value: str) -> opt[Parent] {
    if len(value) < 55 { return none; }
    let b = to_bytes(strings.slice(value, 0, 55));
    let hi = hex(b[0] as int);
    let lo = hex(b[1] as int);
    if hi < 0 || lo < 0 || (hi == 15 && lo == 15) || b[2] != 45 || b[35] != 45 || b[52] != 45 { return none; }
    if hi == 0 && lo == 0 && len(value) != 55 { return none; }
    if len(value) > 55 && strings.slice(value, 55, 56) != "-" { return none; }
    let trace_id = strings.slice(value, 3, 35);
    let span_id = strings.slice(value, 36, 52);
    if !id_ok(trace_id, 32) || !id_ok(span_id, 16) || hex(b[53] as int) < 0 || hex(b[54] as int) < 0 { return none; }
    return some(Parent { trace_id: trace_id, span_id: span_id, sampled: hex(b[54] as int) % 2 == 1 });
}

fn key_char(c: int) -> bool {
    return (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 45 || c == 42 || c == 47;
}

fn key_part(s: str, cap: int, digit_first: bool) -> bool {
    let b = to_bytes(s);
    if len(b) == 0 || len(b) > cap { return false; }
    let c = b[0] as int;
    if !((c >= 97 && c <= 122) || (digit_first && c >= 48 && c <= 57)) { return false; }
    for v in b { if !key_char(v as int) { return false; } }
    return true;
}

fn key_ok(key: str) -> bool {
    let at = strings.find(key, "@");
    if at < 0 { return key_part(key, 256, false); }
    return key_part(strings.slice(key, 0, at), 241, true) &&
        key_part(strings.slice(key, at + 1, len(key)), 14, false);
}

// Invalid vendor state is discarded independently of a valid parent.
pub fn state(value: str, max_bytes: int, max_members: int) -> str {
    if len(value) == 0 || len(value) > max_bytes { return ""; }
    // Only SP/HTAB are optional whitespace; trimming must not hide CR/LF.
    for byte in to_bytes(value) {
        if byte < 32 && byte != 9 { return ""; }
        if byte > 126 { return ""; }
    }
    let members = strings.split(value, ",");
    if len(members) > max_members { return ""; }
    let seen: map[str]bool = {};
    let out: [str] = [];
    for item in members {
        let pair = strings.trim(item);
        if len(pair) == 0 { continue; }
        let eq = strings.find(pair, "=");
        if eq < 1 { return ""; }
        let key = strings.slice(pair, 0, eq);
        let val = strings.slice(pair, eq + 1, len(pair));
        if !key_ok(key) || has(seen, key) || len(val) == 0 || len(val) > 256 { return ""; }
        for byte in to_bytes(val) {
            let c = byte as int;
            if c < 32 || c > 126 || c == 61 || c == 44 { return ""; }
        }
        seen[key] = true;
        push(out, key + "=" + val);
    }
    return strings.join(out, ",");
}
