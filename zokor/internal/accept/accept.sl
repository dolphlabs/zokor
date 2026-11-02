// RFC 9110 media ranges and preference selection; no sockets or environment.
import "strings";
import "builder";

pub struct Media { mtype: str, subtype: str, params: [str], quality: int }
gc struct Scan { text: str, b: bytes, pos: int }

fn token_byte(c: int) -> bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) ||
        c == 33 || c == 35 || c == 36 || c == 37 || c == 38 || c == 39 || c == 42 ||
        c == 43 || c == 45 || c == 46 || c == 94 || c == 95 || c == 96 || c == 124 || c == 126;
}

fn ows(c: Scan) { while c.pos < len(c.b) && (c.b[c.pos] == 32 || c.b[c.pos] == 9) { c.pos += 1; } }
fn word(c: Scan) -> str {
    let start = c.pos;
    while c.pos < len(c.b) && token_byte(c.b[c.pos] as int) { c.pos += 1; }
    return strings.slice(c.text, start, c.pos);
}

fn quoted(c: Scan) -> result[str, str] {
    c.pos += 1;
    let start = c.pos;
    let escaped = false;
    while c.pos < len(c.b) {
        let ch = c.b[c.pos];
        if ch == 34 {
            let end = c.pos; c.pos += 1;
            if !escaped { return ok(strings.slice(c.text, start, end)); }
            let bb = builder.new_bytes();
            let run = start;
            let i = start;
            while i < end {
                if c.b[i] == 92 {
                    bb.write(c.b[run..i]);
                    i += 1;
                    bb.write(c.b[i..i + 1]);
                    run = i + 1;
                }
                i += 1;
            }
            bb.write(c.b[run..end]);
            return ok(to_str(bb.finish()));
        }
        if ch == 92 {
            escaped = true; c.pos += 1;
            if c.pos >= len(c.b) { return err("unfinished quoted escape"); }
            let next = c.b[c.pos];
            if next != 9 && (next < 32 || next == 127) { return err("control byte in quoted parameter"); }
        } else if ch != 9 && (ch < 32 || ch == 127) { return err("control byte in quoted parameter"); }
        c.pos += 1;
    }
    return err("unterminated quoted parameter");
}

pub fn quality(value: str) -> result[int, str] {
    let b = to_bytes(value);
    if len(b) < 1 || len(b) > 5 || (b[0] != 48 && b[0] != 49) { return err("q must be 0..1 with at most three fractional digits"); }
    let out = 0;
    if b[0] == 49 { out = 1000; }
    if len(b) == 1 { return ok(out); }
    if b[1] != 46 { return err("q must be 0..1 with at most three fractional digits"); }
    let scale = 100;
    let i = 2;
    while i < len(b) {
        if b[i] < 48 || b[i] > 57 || (b[0] == 49 && b[i] != 48) { return err("q must be 0..1 with at most three fractional digits"); }
        if b[0] == 48 { out += (b[i] as int - 48) * scale; }
        scale /= 10; i += 1;
    }
    return ok(out);
}

fn take(c: Scan, wildcards: bool, cap: int, no_params: [str]) -> result[Media, str] {
    ows(c);
    let mtype = strings.to_lower(word(c));
    if len(mtype) == 0 || c.pos >= len(c.b) || c.b[c.pos] != 47 { return err("expected type/subtype without whitespace"); }
    c.pos += 1;
    let subtype = strings.to_lower(word(c));
    if len(subtype) == 0 { return err("expected a subtype"); }
    if !wildcards && (mtype == "*" || subtype == "*") { return err("an offered representation must be concrete"); }
    if mtype == "*" && subtype != "*" { return err("a wildcard type requires */*"); }
    let params = no_params;
    let owned = false;
    let q = 1000;
    let seen_q = false;
    let count = 0;
    ows(c);
    while c.pos < len(c.b) && c.b[c.pos] == 59 {
        count += 1;
        if count > cap { return err("parameters exceed max_params"); }
        c.pos += 1; ows(c);
        if c.pos == len(c.b) || c.b[c.pos] == 44 || c.b[c.pos] == 59 { continue; }
        let name = strings.to_lower(word(c));
        if len(name) == 0 || c.pos >= len(c.b) || c.b[c.pos] != 61 { return err("expected parameter=value without whitespace around ="); }
        c.pos += 1;
        if c.pos >= len(c.b) { return err("parameter has no value"); }
        let is_quoted = c.b[c.pos] == 34;
        let value = "";
        if is_quoted {
            let parsed = quoted(c);
            guard let v = parsed else let e = err_of(parsed) { return err(e); }
            value = v;
        } else {
            value = word(c);
            if len(value) == 0 { return err("parameter has no token or quoted value"); }
        }
        if name == "q" {
            if !wildcards { return err("q is a request preference, not an offered media parameter"); }
            if seen_q { return err("duplicate q parameter"); }
            if is_quoted { return err("q must be an unquoted quality value"); }
            let parsed = quality(value);
            guard let v = parsed else let e = err_of(parsed) { return err(e); }
            q = v; seen_q = true;
        } else {
            let i = 0;
            while i < len(params) { if params[i] == name { return err("duplicate media parameter"); } i += 2; }
            if !owned { params = []; owned = true; }
            if name == "charset" { value = strings.to_lower(value); }
            push(params, name); push(params, value);
        }
        ows(c);
    }
    return ok(Media { mtype: mtype, subtype: subtype, params: params, quality: q });
}

pub fn media(value: str, max_params: int) -> result[Media, str] {
    let c = Scan { text: value, b: to_bytes(value), pos: 0 };
    let no_params: [str] = [];
    let parsed = take(c, false, max_params, no_params);
    guard let m = parsed else let e = err_of(parsed) { return err(e); }
    if c.pos != len(c.b) { return err("unexpected bytes after offered media type"); }
    return ok(m);
}

pub fn ranges(value: str, max_bytes: int, max_ranges: int, max_params: int) -> result[[Media], str] {
    if len(value) > max_bytes { return err("Accept exceeds max_bytes"); }
    let c = Scan { text: value, b: to_bytes(value), pos: 0 };
    let out: [Media] = [];
    let no_params: [str] = [];
    let members = 0;
    while c.pos < len(c.b) {
        ows(c);
        if c.pos == len(c.b) { break; }
        members += 1;
        if members > max_ranges { return err("Accept exceeds max_ranges"); }
        if c.b[c.pos] == 44 { c.pos += 1; continue; }
        let parsed = take(c, true, max_params, no_params);
        guard let m = parsed else let e = err_of(parsed) { return err("range " + to_str(members) + ": " + e); }
        push(out, m);
        if c.pos < len(c.b) {
            if c.b[c.pos] != 44 { return err("expected comma between media ranges"); }
            c.pos += 1;
        }
    }
    return ok(out);
}

fn parameters_match(wanted: [str], offered: [str]) -> bool {
    let i = 0;
    while i < len(wanted) {
        let found = false;
        let j = 0;
        while j < len(offered) {
            if offered[j] == wanted[i] && offered[j + 1] == wanted[i + 1] { found = true; break; }
            j += 2;
        }
        if !found { return false; }
        i += 2;
    }
    return true;
}

// Most-specific range controls an offer's quality, including a q=0 veto.
// Equal qualities prefer specificity, then client order, then offer order.
pub fn choose(header: opt[str], types: [str], subtypes: [str], params: [[str]],
              max_bytes: int, max_ranges: int, max_params: int) -> result[int, str] {
    if len(types) == 0 || len(types) != len(subtypes) || len(types) != len(params) { return err("negotiator has inconsistent offer vectors"); }
    for offered in params {
        if len(offered) % 2 != 0 { return err("negotiator has an incomplete parameter pair"); }
    }
    guard let value = header else { return ok(0); }
    let parsed = ranges(value, max_bytes, max_ranges, max_params);
    guard let list = parsed else let e = err_of(parsed) { return err(e); }
    let best = -1;
    let best_q = 0;
    let best_specific = -1;
    let best_params = -1;
    let best_order = max_ranges;
    let i = 0;
    while i < len(types) {
        let q = 0; let specific = -1; let nparams = -1; let order = max_ranges;
        let j = 0;
        for range_ in list {
            if (range_.mtype == "*" || range_.mtype == types[i]) &&
               (range_.subtype == "*" || range_.subtype == subtypes[i]) && parameters_match(range_.params, params[i]) {
                let s = 2;
                if range_.mtype == "*" { s = 0; } else if range_.subtype == "*" { s = 1; }
                let p = len(range_.params) / 2;
                if s > specific || (s == specific && p > nparams) || (s == specific && p == nparams && range_.quality > q) {
                    q = range_.quality; specific = s; nparams = p; order = j;
                }
            }
            j += 1;
        }
        if q > 0 && (q > best_q || (q == best_q && specific > best_specific) ||
            (q == best_q && specific == best_specific && nparams > best_params) ||
            (q == best_q && specific == best_specific && nparams == best_params && order < best_order)) {
            best = i; best_q = q; best_specific = specific; best_params = nparams; best_order = order;
        }
        i += 1;
    }
    return ok(best);
}

// Combine repeated lines as a list without splitting quoted parameter values.
pub fn header(raw: bytes, max_bytes: int) -> result[opt[str], str] {
    let total = 0;
    let found = false;
    let joined: opt[builder.Str] = none;
    let single = "";
    let i = 0;
    while i < len(raw) {
        let end = i;
        while end < len(raw) && raw[end] != 13 && raw[end] != 10 { end += 1; }
        if end - i >= 7 && raw[i + 6] == 58 && strings.from_bytes_lower(raw, i, i + 6) == "accept" {
            let start = i + 7;
            let stop = end;
            while start < stop && (raw[start] == 32 || raw[start] == 9) { start += 1; }
            while stop > start && (raw[stop - 1] == 32 || raw[stop - 1] == 9) { stop -= 1; }
            let separator = 0;
            if found { separator = 1; }
            if stop - start > max_bytes - total - separator { return err("Accept exceeds max_bytes"); }
            let value = strings.from_bytes(raw, start, stop);
            if found {
                if let sb = joined { sb.write(","); sb.write(value); }
                else {
                    let sb = builder.new_str(); sb.write(single); sb.write(","); sb.write(value);
                    joined = some(sb);
                }
            } else { single = value; }
            total += stop - start + separator;
            found = true;
        }
        i = end;
        if i < len(raw) && raw[i] == 13 { i += 1; }
        if i < len(raw) && raw[i] == 10 { i += 1; }
    }
    if !found { let absent: opt[str] = none; return ok(absent); }
    if let sb = joined { return ok(some(sb.finish())); }
    return ok(some(single));
}
