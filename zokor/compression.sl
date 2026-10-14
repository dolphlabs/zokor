// Response compression: gzip through slang's `compress` (zlib), for
// clients that accept it, on bodies worth it.
//
//     r.compress(zokor.compression());           // defaults below
//
// A response is gzipped when all hold:
//   - the request's Accept-Encoding allows gzip (`gzip`, `x-gzip` or `*`
//     with a q above 0; `gzip;q=0` refuses it);
//   - it is a 2xx other than 204 and 206, to a method other than HEAD;
//   - its body is at least `min_size` bytes (1 KB: below that the gzip
//     header and the CPU cost more than they save);
//   - its content type is in `types` (text, JSON, JavaScript, XML, SVG,
//     form data, and the +json / +xml suffixes) -- never an image, video,
//     archive or anything already compressed;
//   - it has no Content-Encoding of its own.
// It then carries `Content-Encoding: gzip`, and a strong ETag becomes
// weak (`W/`): the gzipped bytes are not the bytes the tag was made from.
// Every response that could have been gzipped -- sent plain to a client
// that did not ask -- carries `Vary: Accept-Encoding` too, so a cache
// never hands one variant to the other's client.
//
// BREACH: over TLS, compressing a response that holds a secret (a CSRF
// token, a session id) next to input the attacker controls lets them
// guess the secret from response sizes. Turn compression on for APIs
// whose responses do not mix the two, or keep such routes on a router
// without it.

import "compress";
import "http";
import "strings";

pub gc struct Compression {
    // Smallest body worth compressing.
    min_size: int,
    // zlib level: 1 fastest, 9 smallest. On API JSON, measured: 14 KB
    // took 36 us at 1 (10% of the size), 74 us at 5 (10%), 176 us at 9
    // (9%) -- level 1 keeps nearly all the saving for half the CPU.
    level: int,
    // Media types (no parameters), or "text/*"-style prefixes.
    types: [str],
}

pub fn compression() -> Compression {
    return Compression {
        min_size: 1024,
        level: 1,
        types: ["text/*", "application/json", "application/javascript",
                "application/xml", "application/x-www-form-urlencoded",
                "image/svg+xml", "application/wasm"]
    };
}

// Whether an Accept-Encoding value allows gzip.
pub fn accepts_gzip(header: str) -> bool {
    if len(header) == 0 {
        return false;
    }
    let gzip_q = -1;
    let star_q = -1;
    for part in strings.split(header, ",") {
        let item = strings.trim(part);
        let semi = strings.find(item, ";");
        let name = item;
        let q = 1000;
        if semi >= 0 {
            name = strings.trim(strings.slice(item, 0, semi));
            q = q_of(strings.slice(item, semi + 1, len(item)));
        }
        let lower = strings.to_lower(name);
        if lower == "gzip" || lower == "x-gzip" {
            gzip_q = q;
        } else if lower == "*" {
            star_q = q;
        }
    }
    if gzip_q >= 0 {
        return gzip_q > 0;
    }
    return star_q > 0;
}

// The q of a ";q=0.5" parameter list, in thousandths; 1000 when absent,
// 0 when malformed (a value that cannot be read is no consent).
fn q_of(params: str) -> int {
    for p in strings.split(params, ";") {
        let kv = strings.trim(p);
        if !strings.has_prefix(strings.to_lower(kv), "q=") {
            continue;
        }
        let v = strings.slice(kv, 2, len(kv));
        if v == "1" || v == "1.0" || v == "1.00" || v == "1.000" {
            return 1000;
        }
        if !strings.has_prefix(v, "0") {
            return 0;
        }
        if v == "0" {
            return 0;
        }
        if !strings.has_prefix(v, "0.") || len(v) > 5 {
            return 0;
        }
        let digits = strings.slice(v, 2, len(v));
        let n = 0;
        let i = 0;
        for b in to_bytes(digits) {
            let x = b as int;
            if x < 48 || x > 57 {
                return 0;
            }
            n = n * 10 + (x - 48);
            i = i + 1;
        }
        while i < 3 {
            n = n * 10;
            i = i + 1;
        }
        return n;
    }
    return 1000;
}

fn compressible_type(content_type: str, types: [str]) -> bool {
    let ct = strings.to_lower(content_type);
    let semi = strings.find(ct, ";");
    if semi >= 0 {
        ct = strings.trim(strings.slice(ct, 0, semi));
    }
    if len(ct) == 0 {
        return false;
    }
    if strings.has_suffix(ct, "+json") || strings.has_suffix(ct, "+xml") {
        return true;
    }
    for t in types {
        if strings.has_suffix(t, "/*") {
            if strings.has_prefix(ct, strings.slice(t, 0, len(t) - 1)) {
                return true;
            }
        } else if ct == t {
            return true;
        }
    }
    return false;
}

// The content type of `resp`, from its field or a raw header line.
fn content_type_of(resp: http.Response) -> str {
    if len(resp.content_type) > 0 {
        return resp.content_type;
    }
    return http.resp_header(resp, "content-type") ?? "";
}

// `resp`, gzipped when `z` and the request allow it.
fn maybe_gzip(z: Compression, accept: str, method: str, resp: http.Response) -> http.Response {
    if method == "HEAD" || resp.status < 200 || resp.status > 299 || resp.status == 204 ||
       resp.status == 206 {
        return resp;
    }
    if len(resp.body) < z.min_size || http.has_resp_header(resp, "content-encoding") {
        return resp;
    }
    if !compressible_type(content_type_of(resp), z.types) {
        return resp;
    }
    // This resource has a gzipped variant: every variant says so, so a
    // cache keys on Accept-Encoding whichever one it stores first.
    if !accepts_gzip(accept) {
        return add_vary(resp, "Accept-Encoding");
    }
    let gr = compress.gzip_level(resp.body, z.level);
    guard let gz = gr else {
        return resp;      // zlib refused: send it as it is
    }
    if len(gz) >= len(resp.body) {
        return resp;
    }
    let out = http.Response {
        status: resp.status,
        status_text: resp.status_text,
        content_type: resp.content_type,
        location: resp.location,
        extra: weak_etag_lines(resp.extra),
        body: gz
    };
    out = http.with_header(out, "content-encoding", "gzip");
    return add_vary(out, "Accept-Encoding");
}

// The header lines with a strong ETag made weak.
fn weak_etag_lines(lines: [str]) -> [str] {
    let out: [str] = [];
    for line in lines {
        if strings.has_prefix(strings.to_lower(line), "etag:") {
            let v = strings.trim(strings.slice(line, 5, len(line)));
            if !strings.has_prefix(v, "W/") {
                push(out, "etag: W/" + v);
                continue;
            }
        }
        push(out, line);
    }
    return out;
}

// Vary with `field` added: to an existing Vary line, or a new one.
fn add_vary(resp: http.Response, field: str) -> http.Response {
    let i = 0;
    while i < len(resp.extra) {
        let line = resp.extra[i];
        if strings.has_prefix(strings.to_lower(line), "vary:") {
            let v = strings.trim(strings.slice(line, 5, len(line)));
            if v == "*" || strings.contains(strings.to_lower(v), strings.to_lower(field)) {
                return resp;
            }
            resp.extra[i] = "vary: " + v + ", " + field;
            return resp;
        }
        i = i + 1;
    }
    return http.with_header(resp, "vary", field);
}
