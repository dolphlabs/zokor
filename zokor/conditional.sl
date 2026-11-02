// Conditional requests (RFC 9110 section 13): answer "not modified" when
// the client already has the current version, and refuse a write made
// against a version that is no longer current.
//
// Reads: a client that sent If-None-Match or If-Modified-Since gets a 304
// with no body when nothing changed -- the bandwidth and the encoding are
// saved, and the client keeps its copy:
//
//     let tag = zokor.etag_of(to_bytes(to_str(doc.version)));
//     if let stop = zokor.preconditions(c, tag, some(doc.updated_at)) {
//         return stop;                              // 304, or 412
//     }
//     let resp = zokor.ok_json(json.encode(doc));
//     return zokor.with_validators(resp, tag, some(doc.updated_at));
//
// Writes: a client that sends If-Match with the tag it read gets a 412
// instead of overwriting someone else's change -- optimistic concurrency
// without a lock. The same call covers both; pass "" for a resource that
// does not exist yet (If-Match then fails, If-None-Match: * succeeds, so
// `If-None-Match: *` on a PUT means "create, never replace").
//
// For a body-only check with no version at hand, `r.etags()` tags every
// 200 GET with a hash of its body and answers a matching If-None-Match
// with 304 (see Router.etags).
//
// Order and rules follow RFC 9110 13.2.2: If-Match, else
// If-Unmodified-Since; then If-None-Match, else If-Modified-Since (GET and
// HEAD only). If-Match compares strongly, If-None-Match weakly. A date
// that is not a valid HTTP date is ignored, as the RFC requires.

import "builder";
import "http";
import "timez";

// A strong entity tag for `data`: its length and 64-bit FNV-1a hash,
// quoted. Pass the response body, or anything that changes exactly when
// the representation does (a row version, a content hash you store). Not
// a cryptographic hash, and it needs not be: a tag only has to change
// when the bytes do, and SHA-256 cost twice as much per byte.
pub fn etag_of(data: bytes) -> str {
    let h: u64 = 14695981039346656037;
    for x in data {
        h = (h ^ (x as u64)) * 1099511628211;
    }
    let sb = builder.new_str();
    sb.write("\"");
    sb.write_int(len(data));
    sb.write("-");
    sb.write(to_str(h));
    sb.write("\"");
    return sb.finish();
}

// `resp` with ETag (when `etag` is not "") and Last-Modified (when known,
// to the second: an HTTP date has no fraction).
pub fn with_validators(resp: http.Response, etag: str,
                       last_modified: opt[timez.Time]) -> http.Response {
    let out = resp;
    if len(etag) > 0 {
        out = http.with_header(out, "etag", etag);
    }
    if let lm = last_modified {
        out = http.with_header(out, "last-modified", lm.http_date());
    }
    return out;
}

// "*" with optional whitespace around it: "any current representation".
fn only_star(b: bytes) -> bool {
    let star = false;
    for x in b {
        if x == 42 && !star {
            star = true;
        } else if x != 32 && x != 9 {
            return false;
        }
    }
    return star;
}

fn trim_ows(v: str) -> str {
    let b = to_bytes(v);
    let s = 0;
    let e = len(b);
    while s < e && (b[s] == 32 || b[s] == 9) {
        s = s + 1;
    }
    while e > s && (b[e - 1] == 32 || b[e - 1] == 9) {
        e = e - 1;
    }
    if s == 0 && e == len(b) {
        return v;
    }
    return to_str(b[s..e]);
}

// Whether the If-Match / If-None-Match value `header` lists `etag`.
// `strong` is If-Match's comparison (a W/ on either side never matches);
// otherwise the opaque parts alone are compared. Scanned in place: a
// list is never built. Malformed text ends the scan -- what came before
// it still counts, nothing after it is guessed at.
fn listed(header: str, etag: str, strong: bool) -> bool {
    if len(etag) == 0 {
        return false;
    }
    let b = to_bytes(header);
    let n = len(b);
    if only_star(b) {
        return true;
    }
    let e = to_bytes(etag);
    let eo = 0;
    if len(e) >= 2 && e[0] == 87 && e[1] == 47 {
        if strong {
            return false;
        }
        eo = 2;
    }
    let elen = len(e) - eo;
    if elen < 2 || e[eo] != 34 || e[len(e) - 1] != 34 {
        return false;
    }
    let i = 0;
    let members = 0;
    while i < n && members < 64 {
        while i < n && (b[i] == 32 || b[i] == 9 || b[i] == 44) {
            i = i + 1;
        }
        if i >= n {
            return false;
        }
        let weak = false;
        if i + 1 < n && b[i] == 87 && b[i + 1] == 47 {
            weak = true;
            i = i + 2;
        }
        if i >= n || b[i] != 34 {
            return false;
        }
        let start = i;
        i = i + 1;
        // etagc: %x21 / %x23-7E / obs-text
        while i < n && b[i] != 34 {
            let x = b[i] as int;
            if x < 0x21 || x == 0x7f {
                return false;
            }
            i = i + 1;
        }
        if i >= n {
            return false;
        }
        i = i + 1;
        if (!strong || !weak) && i - start == elen && tag_bytes_equal(b, start, e, eo, elen) {
            return true;
        }
        members = members + 1;
    }
    return false;
}

fn tag_bytes_equal(a: bytes, ao: int, b: bytes, bo: int, n: int) -> bool {
    let k = 0;
    while k < n {
        if a[ao + k] != b[bo + k] {
            return false;
        }
        k = k + 1;
    }
    return true;
}

fn header_date(v: str) -> opt[timez.Time] {
    if len(v) == 0 {
        return none;
    }
    let r = timez.parse_http_date(trim_ows(v));
    if let t = r {
        return some(t);
    }
    return none;
}

fn is_read(method: str) -> bool {
    return method == "GET" || method == "HEAD";
}

// The 304 for a read whose validators matched: no body, and the
// validators the 200 would have carried.
pub fn not_modified(etag: str, last_modified: opt[timez.Time]) -> http.Response {
    let r = http.Response {
        status: 304,
        status_text: "Not Modified",
        content_type: "",
        location: "",
        extra: [],
        body: to_bytes("")
    };
    return with_validators(r, etag, last_modified);
}

// What a conditional request's headers decide, before the handler does
// its work: some(304) or some(412) to send as is, none to go on. `etag`
// is the current representation's tag ("" when the resource does not
// exist or has none); `last_modified` when it is known. A request with
// no conditional header always gets none.
pub fn preconditions[S](c: Ctx[S], etag: str,
                        last_modified: opt[timez.Time]) -> opt[http.Response] {
    let method = c.req.method;
    let if_match = c.header("if-match");
    if len(if_match) > 0 {
        if !listed(if_match, etag, true) {
            return some(respond(c.errors, "precondition_failed", c.request_id));
        }
    } else {
        if let ius = header_date(c.header("if-unmodified-since")) {
            if let lm = last_modified {
                if lm.unix() > ius.unix() {
                    return some(respond(c.errors, "precondition_failed", c.request_id));
                }
            }
        }
    }
    let if_none = c.header("if-none-match");
    if len(if_none) > 0 {
        if listed(if_none, etag, false) {
            if is_read(method) {
                return some(not_modified(etag, last_modified));
            }
            return some(respond(c.errors, "precondition_failed", c.request_id));
        }
        return none;
    }
    if is_read(method) {
        if let ims = header_date(c.header("if-modified-since")) {
            if let lm = last_modified {
                if lm.unix() <= ims.unix() {
                    return some(not_modified(etag, last_modified));
                }
            }
        }
    }
    return none;
}

// `resp` with an ETag of its body, or the 304 that replaces it when
// `if_none_match` already names that tag. The 304 keeps the 200's other
// headers: a cache refreshes Cache-Control, Vary and the rest from it.
fn tag_response(if_none_match: str, resp: http.Response) -> http.Response {
    let tag = etag_of(resp.body);
    if len(if_none_match) > 0 && listed(if_none_match, tag, false) {
        let nm = http.Response {
            status: 304,
            status_text: "Not Modified",
            content_type: "",
            location: resp.location,
            extra: resp.extra,
            body: to_bytes("")
        };
        push(nm.extra, "etag: " + tag);
        return nm;
    }
    push(resp.extra, "etag: " + tag);
    return resp;
}
