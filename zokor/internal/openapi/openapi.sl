// OpenAPI route conversion, independent of a router or HTTP connection.
import "strings";
import "../path" as api_path;

pub struct Route { method: str, pattern: str, template: str, shape: str, names: [str] }

pub fn name_ok(name: str) -> bool {
    if len(name) == 0 { return false; }
    for b in to_bytes(name) {
        let c = b as int;
        if !((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 45 || c == 46) { return false; }
    }
    return true;
}

pub fn route(line: str, max_segments: int) -> result[Route, str] {
    let space = strings.find(line, " ");
    if space < 1 { return err("use METHOD /pattern from routes_list"); }
    let verb = strings.slice(line, 0, space);
    if verb != "GET" && verb != "PUT" && verb != "POST" && verb != "DELETE" && verb != "OPTIONS" && verb != "HEAD" && verb != "PATCH" && verb != "TRACE" {
        return err("OpenAPI has no operation for this method; omit the route explicitly");
    }
    let pattern = strings.slice(line, space + 1, len(line));
    if !strings.has_prefix(pattern, "/") { return err("route pattern must start with /"); }
    let segments = 0;
    let in_segment = false;
    for b in to_bytes(pattern) {
        if b == 47 { in_segment = false; }
        else if !in_segment {
            segments += 1; in_segment = true;
            if segments > max_segments { return err("path segments exceed max_collection_entries"); }
        }
        if b <= 32 || b == 127 || b == 63 || b == 35 || b == 123 || b == 125 {
            return err("route pattern cannot contain whitespace, controls, queries, fragments or literal braces");
        }
    }
    let parts: [str] = [];
    let shapes: [str] = [];
    let names: [str] = [];
    let seen: map[str]bool = {};
    for segment in api_path.split(pattern) {
        if len(segment) == 0 { continue; }
        if strings.has_prefix(segment, "*") { return err("a wildcard spans multiple segments; omit the route explicitly"); }
        if strings.has_prefix(segment, ":") {
            let name = strings.slice(segment, 1, len(segment));
            if !name_ok(name) || has(seen, name) { return err("path parameters need distinct names using letters, digits, _, - or ."); }
            seen[name] = true;
            push(names, name);
            push(parts, "{" + name + "}");
            push(shapes, "{}");
        } else {
            push(parts, segment);
            push(shapes, segment);
        }
    }
    return ok(Route { method: strings.to_lower(verb), pattern: pattern,
        template: "/" + strings.join(parts, "/"), shape: "/" + strings.join(shapes, "/"), names: names });
}

// Stable ordering for startup metadata. No map iteration leaks into output.
pub fn ordered(names: [str]) -> [str] {
    let out: [str] = [];
    let scratch: [str] = [];
    for name in names { push(out, name); push(scratch, name); }
    let width = 1;
    while width < len(out) {
        let start = 0;
        while start < len(out) {
            let middle = start + width;
            if middle > len(out) { middle = len(out); }
            let end = middle + width;
            if end > len(out) { end = len(out); }
            let left = start;
            let right = middle;
            let pos = start;
            while pos < end {
                if left < middle && (right >= end || out[left] <= out[right]) {
                    scratch[pos] = out[left]; left += 1;
                } else { scratch[pos] = out[right]; right += 1; }
                pos += 1;
            }
            start = end;
        }
        let previous = out;
        out = scratch; scratch = previous;
        width *= 2;
    }
    return out;
}
