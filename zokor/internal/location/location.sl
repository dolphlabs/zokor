// Bounded HTTP Location validation; URI references are emitted without rewriting.
import "strings";

fn hex(c: int) -> bool { return (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102); }
fn uri_byte(c: int) -> bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) ||
        c == 45 || c == 46 || c == 95 || c == 126 || c == 33 || c == 36 || c == 38 ||
        c == 39 || c == 40 || c == 41 || c == 42 || c == 43 || c == 44 || c == 59 ||
        c == 61 || c == 58 || c == 47 || c == 63 || c == 64 || c == 35 || c == 91 || c == 93;
}

fn ipv4(value: str) -> bool {
    let parts = strings.split(value, ".");
    if len(parts) != 4 { return false; }
    for part in parts {
        let b = to_bytes(part);
        if len(b) == 0 || len(b) > 3 || (len(b) > 1 && b[0] == 48) { return false; }
        let n = 0;
        for ch in b { if ch < 48 || ch > 57 { return false; } n = n * 10 + ch as int - 48; }
        if n > 255 { return false; }
    }
    return true;
}
fn ipv6(value: str) -> bool {
    let halves = strings.split(value, "::");
    if len(halves) > 2 { return false; }
    let groups = 0;
    let index = 0;
    for half in halves {
        if len(half) > 0 {
            let parts = strings.split(half, ":");
            let part_index = 0;
            for part in parts {
                if strings.contains(part, ".") {
                    if index != len(halves) - 1 || part_index != len(parts) - 1 || !ipv4(part) { return false; }
                    groups += 2;
                } else {
                    let b = to_bytes(part);
                    if len(b) < 1 || len(b) > 4 { return false; }
                    for ch in b { if !hex(ch as int) { return false; } }
                    groups += 1;
                }
                part_index += 1;
            }
        }
        index += 1;
    }
    if len(halves) == 2 { return groups < 8; }
    return groups == 8;
}
fn authority_ok(value: str) -> bool {
    let host = value;
    let port = "";
    if strings.has_prefix(value, "[") {
        let close = strings.find(value, "]");
        if close < 0 || !ipv6(strings.slice(value, 1, close)) { return false; }
        let tail = strings.slice(value, close + 1, len(value));
        if len(tail) > 0 {
            if !strings.has_prefix(tail, ":") { return false; }
            port = strings.slice(tail, 1, len(tail));
            if len(port) == 0 { return false; }
        }
    } else {
        if strings.contains(value, "[") || strings.contains(value, "]") { return false; }
        let colon = strings.find(value, ":");
        if colon >= 0 {
            host = strings.slice(value, 0, colon);
            port = strings.slice(value, colon + 1, len(value));
            if len(port) == 0 { return false; }
        }
        if len(host) == 0 { return false; }
    }
    if len(port) > 0 {
        let b = to_bytes(port);
        if len(b) > 5 { return false; }
        let n = 0;
        for ch in b { if ch < 48 || ch > 57 { return false; } n = n * 10 + ch as int - 48; }
        if n < 1 || n > 65535 { return false; }
    }
    return true;
}

pub fn check(value: str, max_bytes: int, allow_external: bool) -> result[bool, str] {
    if max_bytes < 1 { return err("max_location_bytes must be positive"); }
    if len(value) == 0 || len(value) > max_bytes { return err("location must be nonempty and within max_location_bytes"); }
    let b = to_bytes(value);
    let i = 0;
    let fragment = false;
    while i < len(b) {
        let c = b[i] as int;
        if c == 37 {
            if i + 2 >= len(b) || !hex(b[i + 1] as int) || !hex(b[i + 2] as int) { return err("location has an invalid percent escape"); }
            i += 3; continue;
        }
        if !uri_byte(c) { return err("location must be an ASCII URI reference; percent-encode other bytes"); }
        if c == 35 { if fragment { return err("location has more than one fragment delimiter"); } fragment = true; }
        i += 1;
    }
    if strings.has_prefix(value, "//") { return err("location must use a relative reference or an explicit HTTP(S) URL"); }
    let first_end = 0;
    while first_end < len(b) && b[first_end] != 47 && b[first_end] != 63 && b[first_end] != 35 { first_end += 1; }
    let prefix = strings.slice(value, 0, first_end);
    let authority_start = -1;
    if strings.contains(prefix, ":") {
        let low = strings.to_lower(value);
        if !strings.has_prefix(low, "http://") && !strings.has_prefix(low, "https://") { return err("location scheme must be HTTP or HTTPS"); }
        if !allow_external { return err("location must be relative unless allow_external is enabled"); }
        authority_start = 7;
        if strings.has_prefix(low, "https://") { authority_start = 8; }
    }
    let authority_end = authority_start;
    if authority_start >= 0 {
        while authority_end < len(b) && b[authority_end] != 47 && b[authority_end] != 63 && b[authority_end] != 35 { authority_end += 1; }
        if authority_end == authority_start { return err("location URL requires a host"); }
        let authority = strings.slice(value, authority_start, authority_end);
        if strings.contains(authority, "@") { return err("location URL must not contain credentials"); }
        if !authority_ok(authority) { return err("location URL requires a valid host and port"); }
    }
    i = 0;
    while i < len(b) {
        if (b[i] == 91 || b[i] == 93) && (authority_start < 0 || i < authority_start || i >= authority_end) {
            return err("location brackets are only valid around an IP host");
        }
        i += 1;
    }
    return ok(true);
}
