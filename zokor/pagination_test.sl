import "http";
import "strings";

gc struct PgState {
    items: [PgRow],
}

struct PgRow {
    id: int,
    name: str,
}

fn pg_rows(n: int) -> [PgRow] {
    let out: [PgRow] = [];
    let i = 1;
    while i <= n {
        push(out, PgRow { id: i, name: "item-" + to_str(i) });
        i = i + 1;
    }
    return out;
}

// what a handler's query would return: rows from `start`, at most `n`
fn pg_slice(all: [PgRow], start: int, n: int) -> [PgRow] {
    let out: [PgRow] = [];
    let i = start;
    while i < len(all) && len(out) < n {
        push(out, all[i]);
        i = i + 1;
    }
    return out;
}

fn pg_by_offset(c: Ctx[PgState]) -> http.Response {
    let pr = page_of(c, 2, 3);
    guard let p = pr else let bad = err_of(pr) { return bad; }
    let rows = pg_slice(c.state.items, p.offset, p.fetch());
    return offset_page(c, p, rows, some(len(c.state.items)));
}

fn pg_key(r: PgRow) -> [str] {
    return [to_str(r.id)];
}

fn pg_by_cursor(c: Ctx[PgState]) -> http.Response {
    let pr = page_of(c, 2, 3);
    guard let p = pr else let bad = err_of(pr) { return bad; }
    // keyset: rows with id greater than the cursor's
    let after = 0;
    let parts = cursor_parts(p);
    if len(parts) == 1 {
        after = to_int(parts[0]) ?? 0;
    }
    let rows = pg_slice(c.state.items, after, p.fetch());
    return cursor_page(c, p, rows, pg_key);
}

fn pg_router() -> Router[PgState] {
    let r = new_router(PgState { items: pg_rows(5) });
    r.get("/items", pg_by_offset);
    r.get("/feed", pg_by_cursor);
    return r;
}

fn pg_get(r: Router[PgState], p: str) -> http.Response {
    return r.serve(get_request(p).build());
}

fn test_offset_pages_carry_next_prev_total_and_links() {
    let r = pg_router();
    let first = pg_get(r, "/items?status=open");
    assert(resp_status(first) == 200);
    assert(resp_text(first) == "{\"data\":[{\"id\":1,\"name\":\"item-1\"},{\"id\":2,\"name\":\"item-2\"}]," +
           "\"page\":{\"limit\":2,\"offset\":0,\"next\":2,\"prev\":null,\"total\":5}}", resp_text(first));
    assert(resp_header(first, "link") == "</items?status=open&limit=2&offset=2>; rel=\"next\"",
           resp_header(first, "link"));
    let mid = pg_get(r, "/items?limit=2&offset=2&status=open");
    assert(strings.contains(resp_text(mid), "\"next\":4,\"prev\":0,"), resp_text(mid));
    assert(resp_header(mid, "link") == "</items?status=open&limit=2&offset=4>; rel=\"next\", " +
           "</items?status=open&limit=2&offset=0>; rel=\"prev\"", resp_header(mid, "link"));
    let last = pg_get(r, "/items?limit=2&offset=4");
    assert(strings.contains(resp_text(last), "{\"id\":5,\"name\":\"item-5\"}],\"page\":{\"limit\":2," +
           "\"offset\":4,\"next\":null,\"prev\":2,"), resp_text(last));
}

fn test_cursor_pages_walk_the_whole_list_once() {
    let r = pg_router();
    let seen: [str] = [];
    let url = "/feed?limit=2";
    let hops = 0;
    while hops < 10 {
        let resp = pg_get(r, url);
        assert(resp_status(resp) == 200, resp_text(resp));
        let body = resp_text(resp);
        let i = 1;
        while i <= 5 {
            if strings.contains(body, "\"id\":" + to_str(i) + ",") {
                push(seen, to_str(i));
            }
            i = i + 1;
        }
        let link_text = resp_header(resp, "link");
        if len(link_text) == 0 {
            assert(strings.contains(body, "\"next\":null"), body);
            break;
        }
        // </feed?limit=2&cursor=...>; rel="next"
        url = strings.slice(link_text, 1, strings.find(link_text, ">"));
        hops = hops + 1;
    }
    assert(strings.join(seen, ",") == "1,2,3,4,5", strings.join(seen, ","));
}

fn test_bad_page_parameters_are_named() {
    let r = pg_router();
    let big = pg_get(r, "/items?limit=500");
    assert(resp_status(big) == 422);
    assert(strings.contains(resp_text(big), "must be a whole number from 1 to 3"), resp_text(big));
    let neg = pg_get(r, "/items?offset=-1");
    assert(resp_status(neg) == 422);
    assert(strings.contains(resp_text(neg), "\"offset\""), resp_text(neg));
    let word = pg_get(r, "/items?limit=lots");
    assert(resp_status(word) == 422);
    let both = pg_get(r, "/feed?offset=2&cursor=" + encode_cursor(["2"]));
    assert(strings.contains(resp_text(both), "use offset or cursor, not both"), resp_text(both));
    let forged = pg_get(r, "/feed?cursor=not-a-cursor!!");
    assert(resp_status(forged) == 422);
    assert(strings.contains(resp_text(forged), "is not a cursor this API issued"), resp_text(forged));
}

fn test_cursors_round_trip_any_text() {
    let parts = ["2026-10-13T09:30:15Z", "id with spaces, commas and \"quotes\"", ""];
    let c = encode_cursor(parts);
    assert(!strings.contains(c, "=") && !strings.contains(c, "+") && !strings.contains(c, "/"), c);
    let back = decode_cursor(c) ?? [];
    assert(len(back) == 3 && back[1] == parts[1] && back[2] == "");
    assert(is_err_parts(decode_cursor("@@@")));
    assert(is_err_parts(decode_cursor(strings.repeat("A", 5000))));
}

fn is_err_parts(r: result[[str], str]) -> bool {
    if let _p = r {
        return false;
    }
    return true;
}
