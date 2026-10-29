// Pagination: offset pages and keyset (cursor) pages, one envelope for
// both, so a client reads every list the same way:
//
//     {"data":[...],"page":{"limit":20,"offset":40,"next":"...","prev":"...","total":123}}
//
// and the same links in a Link header (RFC 8288), other query parameters
// kept: Link: </orders?status=open&limit=20&offset=60>; rel="next", ...
//
// Offset pages are the simple kind -- `?limit=20&offset=40` -- and fine
// for small tables and admin screens. Keyset pages -- `?limit=20&cursor=`
// -- stay fast and stable on large, changing tables: the cursor names
// the last row seen, so the next query is `WHERE (created, id) <
// ($1, $2) ORDER BY created DESC, id DESC LIMIT $3`, an index range,
// and an insert between requests neither skips nor repeats a row.
//
//     let pr = zokor.page_of(c, 20, 100);         // ?limit, ?offset or ?cursor
//     guard let p = pr else let bad = err_of(pr) { return bad; }  // 422, named
//     // ... query p.fetch() rows (one more than the page: tells if there is a next)
//     return zokor.cursor_page(c, p, rows, order_key);
//
//     fn order_key(o: Order) -> [str] { return [o.created, to_str(o.id)]; }
//
// A cursor is opaque to the client (base64url of the key's parts) and is
// decoded with `cursor_parts(p)`; a client can forge one, but only to
// read another position of a list it may read anyway -- authorise the
// list, never a cursor. Never put a secret in a cursor.

import "builder";
import "encoding";
import "http";
import "json";
import "strings";

// What the request asked for, checked.
pub struct Page {
    limit: int,
    // Rows to skip, for an offset page. 0 for a cursor page.
    offset: int,
    // The cursor the client sent: "" on the first page, or for offset
    // pages.
    cursor: str,
    by_cursor: bool,
}

impl Page {
    // How many rows to ask the database for: one more than the page, so
    // the response knows whether there is a next page without a count.
    pub fn fetch(self: Page) -> int {
        return self.limit + 1;
    }
}

// The largest offset accepted: past this, an offset page asks the
// database to read and throw away more rows than a request should cost
// -- use cursor pages.
fn max_offset() -> int {
    return 1000000;
}

// The page `c` asks for: `limit` (default `default_limit`, at most
// `max_limit`), and either `offset` or `cursor`. err is a 422 naming each
// bad parameter, ready to return.
pub fn page_of[S](c: Ctx[S], default_limit: int, max_limit: int) -> result[Page, http.Response] {
    let problems: [FieldError] = [];
    let limit = default_limit;
    let ltext = c.query("limit");
    if len(ltext) > 0 {
        let lr = to_int(ltext);
        if let n = lr {
            limit = n;
        } else {
            limit = -1;
        }
        if limit < 1 || limit > max_limit {
            push(problems, field("limit", "must be a whole number from 1 to " + to_str(max_limit)));
        }
    }
    let offset = 0;
    let otext = c.query("offset");
    if len(otext) > 0 {
        let orr = to_int(otext);
        if let n = orr {
            offset = n;
        } else {
            offset = -1;
        }
        if offset < 0 || offset > max_offset() {
            push(problems, field("offset", "must be a whole number from 0 to " +
                                 to_str(max_offset()) + "; for deeper pages use cursor"));
        }
    }
    let cursor = c.query("cursor");
    if len(cursor) > 0 && len(otext) > 0 {
        push(problems, field("cursor", "use offset or cursor, not both"));
    }
    if len(cursor) > 0 {
        let pr = decode_cursor(cursor);
        if let _parts = pr {
        } else {
            push(problems, field("cursor", "is not a cursor this API issued"));
        }
    }
    if len(problems) > 0 {
        return err(respond_fields(c.errors, "validation_failed", problems, c.request_id));
    }
    return ok(Page {
        limit: limit,
        offset: offset,
        cursor: cursor,
        by_cursor: len(cursor) > 0
    });
}

// The opaque cursor for a row whose sort key is `parts`.
pub fn encode_cursor(parts: [str]) -> str {
    return encoding.base64url_encode(to_bytes(json.encode(parts)));
}

// The key parts of a cursor, err when it is not one encode_cursor made.
pub fn decode_cursor(cursor: str) -> result[[str], str] {
    if len(cursor) > 4096 {
        return err("cursor is too long");
    }
    let br = encoding.base64url_decode(cursor);
    guard let raw = br else {
        return err("cursor is not base64url");
    }
    let pr: result[[str], str] = json.decode(to_str(raw));
    guard let parts = pr else {
        return err("cursor does not hold a key");
    }
    return ok(parts);
}

// The key parts of the cursor `p` came with ([] on the first page).
// page_of already checked it decodes.
pub fn cursor_parts(p: Page) -> [str] {
    let none_yet: [str] = [];
    if len(p.cursor) == 0 {
        return none_yet;
    }
    return decode_cursor(p.cursor) ?? none_yet;
}

// An offset page of `rows` -- up to p.fetch() of them; one past the
// limit means there is a next page -- in the envelope, with Link.
// `total`, when the handler counted, is reported as it is.
pub fn offset_page[S, T](c: Ctx[S], p: Page, rows: [T], total: opt[int]) -> http.Response {
    let more = len(rows) > p.limit;
    let shown = first_n(rows, p.limit);
    let next = "";
    if more {
        next = to_str(p.offset + p.limit);
    }
    let prev = "";
    if p.offset > 0 {
        let back = p.offset - p.limit;
        if back < 0 {
            back = 0;
        }
        prev = to_str(back);
    }
    let sb = builder.new_str();
    sb.write("{\"data\":");
    sb.write(json.encode(shown));
    sb.write(",\"page\":{\"limit\":");
    sb.write_int(p.limit);
    sb.write(",\"offset\":");
    sb.write_int(p.offset);
    sb.write(",\"next\":");
    sb.write(json_int_or_null(next));
    sb.write(",\"prev\":");
    sb.write(json_int_or_null(prev));
    sb.write(",\"total\":");
    if let t = total {
        sb.write_int(t);
    } else {
        sb.write("null");
    }
    sb.write("}}");
    let resp = ok_json(sb.finish());
    let links: [str] = [];
    if len(next) > 0 {
        push(links, link_line(c, p.limit, "offset", next, "next"));
    }
    if len(prev) > 0 {
        push(links, link_line(c, p.limit, "offset", prev, "prev"));
    }
    return with_links(resp, links);
}

// A keyset page of `rows` -- up to p.fetch(); one past the limit means
// there is a next page, whose cursor is `key` of the last row shown.
pub fn cursor_page[S, T](c: Ctx[S], p: Page, rows: [T], key: fn(T) -> [str]) -> http.Response {
    let more = len(rows) > p.limit;
    let shown = first_n(rows, p.limit);
    let next = "";
    if more && len(shown) > 0 {
        next = encode_cursor(key(shown[len(shown) - 1]));
    }
    let sb = builder.new_str();
    sb.write("{\"data\":");
    sb.write(json.encode(shown));
    sb.write(",\"page\":{\"limit\":");
    sb.write_int(p.limit);
    sb.write(",\"cursor\":");
    sb.write(json_str_or_null(p.cursor));
    sb.write(",\"next\":");
    sb.write(json_str_or_null(next));
    sb.write(",\"total\":null}}");
    let resp = ok_json(sb.finish());
    let links: [str] = [];
    if len(next) > 0 {
        push(links, link_line(c, p.limit, "cursor", next, "next"));
    }
    return with_links(resp, links);
}

fn first_n[T](rows: [T], n: int) -> [T] {
    if len(rows) <= n {
        return rows;
    }
    let out: [T] = [];
    let i = 0;
    while i < n {
        push(out, rows[i]);
        i = i + 1;
    }
    return out;
}

fn json_int_or_null(s: str) -> str {
    if len(s) == 0 {
        return "null";
    }
    return s;
}

fn json_str_or_null(s: str) -> str {
    if len(s) == 0 {
        return "null";
    }
    return json.encode(s);
}

// `<path?other&limit=L&name=value>; rel="rel"`: the request's own query,
// without the pagination parameters, then the new ones. A cursor is
// base64url and an offset a number, so neither needs escaping.
fn link_line[S](c: Ctx[S], limit: int, name: str, value: str, rel: str) -> str {
    let sb = builder.new_str();
    sb.write("<");
    sb.write(c.path());
    sb.write("?");
    let qs = path.query_of(c.req.path);
    if len(qs) > 0 {
        for pair in strings.split(qs, "&") {
            let eq = strings.find(pair, "=");
            let pname = pair;
            if eq >= 0 {
                pname = strings.slice(pair, 0, eq);
            }
            if len(pair) == 0 || pname == "limit" || pname == "offset" || pname == "cursor" {
                continue;
            }
            sb.write(pair);
            sb.write("&");
        }
    }
    sb.write("limit=");
    sb.write_int(limit);
    sb.write("&");
    sb.write(name);
    sb.write("=");
    sb.write(value);
    sb.write(">; rel=\"");
    sb.write(rel);
    sb.write("\"");
    return sb.finish();
}

fn with_links(resp: http.Response, links: [str]) -> http.Response {
    if len(links) == 0 {
        return resp;
    }
    return http.with_header(resp, "link", strings.join(links, ", "));
}
