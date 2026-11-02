import "http";
import "strings";

gc struct FsState {
    n: int,
}

fn fs_api(c: Ctx[FsState]) -> http.Response {
    return ok_json("{\"route\":true}");
}

fn fs_router() -> Router[FsState] {
    let r = new_router(FsState { n: 0 });
    r.get("/assets/api", fs_api);
    let mr = files_at("/assets", "testdata/files/public");
    guard let m = mr else let e = err_of(mr) { panic(e); }
    r.files(m);
    return r;
}

fn fs_get(r: Router[FsState], p: str) -> http.Response {
    return r.serve(get_request(p).build());
}

fn test_files_are_served_with_type_and_validators() {
    let r = fs_router();
    let css = fs_get(r, "/assets/app.css");
    assert(resp_status(css) == 200);
    assert(resp_text(css) == "body { color: red; }\n");
    assert(resp_header(css, "content-type") == "text/css; charset=utf-8");
    assert(strings.has_prefix(resp_header(css, "etag"), "\"21-"), resp_header(css, "etag"));
    assert(len(resp_header(css, "last-modified")) == 29);
    assert(resp_header(css, "accept-ranges") == "bytes");
    assert(resp_header(css, "cache-control") == "no-cache");
    assert(resp_header(fs_get(r, "/assets/data.json"), "content-type") == "application/json");
}

fn test_a_directory_answers_its_index() {
    let r = fs_router();
    assert(resp_text(fs_get(r, "/assets")) == "<h1>home</h1>\n");
    assert(resp_text(fs_get(r, "/assets/")) == "<h1>home</h1>\n");
    assert(resp_text(fs_get(r, "/assets/sub/")) == "<h1>sub</h1>\n");
    assert(resp_header(fs_get(r, "/assets/sub"), "content-type") == "text/html; charset=utf-8");
}

fn test_a_route_under_the_prefix_wins() {
    let r = fs_router();
    assert(resp_text(fs_get(r, "/assets/api")) == "{\"route\":true}");
}

fn test_nothing_outside_the_root_or_hidden_is_served() {
    let r = fs_router();
    let tries = [
        "/assets/../files/secret.txt", "/assets/%2e%2e/secret.txt", "/assets/..%2fsecret.txt",
        "/assets/sub/..%2F..%2Fsecret.txt", "/assets/.env", "/assets/%2eenv",
        "/assets/escape.txt", "/assets/sub%5c..%5c..%5csecret.txt", "/assets/digits.txt%00.css",
        "/assets/missing.txt", "/assetsdigits.txt"
    ];
    for p in tries {
        let resp = fs_get(r, p);
        assert(resp_status(resp) == 404, p + " -> " + to_str(resp_status(resp)));
        assert(!strings.contains(resp_text(resp), "outside the root"), p);
        assert(!strings.contains(resp_text(resp), "SECRET"), p);
    }
    // a link that stays inside the root is fine
    assert(resp_text(fs_get(r, "/assets/inside-link.txt")) == "0123456789abcdefghij");
}

fn test_conditional_requests_answer_304() {
    let r = fs_router();
    let first = fs_get(r, "/assets/app.css");
    let tag = resp_header(first, "etag");
    let again = r.serve(get_request("/assets/app.css").header("If-None-Match", tag).build());
    assert(resp_status(again) == 304);
    assert(len(again.body) == 0);
    assert(resp_header(again, "cache-control") == "no-cache");
    let since = r.serve(get_request("/assets/app.css")
        .header("If-Modified-Since", resp_header(first, "last-modified")).build());
    assert(resp_status(since) == 304);
}

fn fs_range(r: Router[FsState], range: str, if_range: str) -> http.Response {
    let rq = get_request("/assets/digits.txt").header("Range", range);
    if len(if_range) > 0 {
        rq = rq.header("If-Range", if_range);
    }
    return r.serve(rq.build());
}

fn test_byte_ranges() {
    let r = fs_router();
    let mid = fs_range(r, "bytes=2-5", "");
    assert(resp_status(mid) == 206);
    assert(resp_text(mid) == "2345");
    assert(resp_header(mid, "content-range") == "bytes 2-5/20");
    assert(resp_text(fs_range(r, "bytes=15-", "")) == "fghij");
    assert(resp_text(fs_range(r, "bytes=-3", "")) == "hij");
    assert(resp_header(fs_range(r, "bytes=10-99", ""), "content-range") == "bytes 10-19/20");
    let past = fs_range(r, "bytes=20-", "");
    assert(resp_status(past) == 416);
    assert(resp_header(past, "content-range") == "bytes */20");
    // several ranges, another unit, garbage: the whole file
    assert(resp_status(fs_range(r, "bytes=0-1,4-5", "")) == 200);
    assert(resp_status(fs_range(r, "lines=1-2", "")) == 200);
    assert(resp_text(fs_range(r, "bytes=abc", "")) == "0123456789abcdefghij");
    // If-Range: the current tag gets the range, a stale one the whole file
    let tag = resp_header(fs_get(r, "/assets/digits.txt"), "etag");
    assert(resp_status(fs_range(r, "bytes=0-0", tag)) == 206);
    assert(resp_status(fs_range(r, "bytes=0-0", "\"stale\"")) == 200);
}

fn test_head_and_other_methods() {
    let r = fs_router();
    let head = r.serve(request(Method.HEAD, "/assets/app.css").build());
    assert(resp_status(head) == 200);
    assert(len(head.body) == 0);
    assert(resp_header(head, "content-type") == "text/css; charset=utf-8");
    let post = r.serve(request(Method.POST, "/assets/app.css").build());
    assert(resp_status(post) == 405);
    assert(resp_header(post, "allow") == "GET, HEAD");
}

fn test_long_cache_for_hashed_assets_and_bad_mounts() {
    let mr = files_at("/static/", "testdata/files/public");
    guard let m = mr else let e = err_of(mr) { panic(e); }
    m.max_age = 31536000;
    m.immutable = true;
    let r = new_router(FsState { n: 0 });
    r.files(m);
    assert(resp_header(fs_get(r, "/static/app.css"), "cache-control") ==
           "public, max-age=31536000, immutable");
    let missing = files_at("/x", "testdata/files/nope");
    assert(strings.contains(err_or_text(missing), "testdata/files/nope"), err_or_text(missing));
    let file = files_at("/x", "testdata/files/secret.txt");
    assert(strings.contains(err_or_text(file), "is not a directory"), err_or_text(file));
    let rel = files_at("x", "testdata/files/public");
    assert(strings.contains(err_or_text(rel), "must start with /"), err_or_text(rel));
}

fn err_or_text(r: result[FileMount, str]) -> str {
    guard let _m = r else let e = err_of(r) {
        return e;
    }
    return "";
}

fn test_parse_range_cases() {
    assert(parse_range("bytes=0-0", 10)[1] == 0);
    assert(parse_range("bytes=-0", 10)[0] == -2);
    assert(parse_range("bytes=-50", 10)[0] == 0);
    assert(parse_range("bytes=5-2", 10)[0] == -1);
    assert(parse_range("bytes=-", 10)[0] == -1);
}
