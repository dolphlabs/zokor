import "compress";
import "http";
import "strings";

gc struct GzState {
    size: int,
}

fn gz_json(c: Ctx[GzState]) -> http.Response {
    return ok_json("{\"items\":\"" + strings.repeat("abcdefgh", c.state.size / 8) + "\"}");
}

fn gz_png(c: Ctx[GzState]) -> http.Response {
    return bytes_of(200, "image/png", to_bytes(strings.repeat("x", 4096)));
}

fn gz_varied(c: Ctx[GzState]) -> http.Response {
    return with_header(gz_json(c), "vary", "Origin");
}

fn gz_router(size: int) -> Router[GzState] {
    let r = new_router(GzState { size: size });
    r.get("/json", gz_json);
    r.head("/json", gz_json);
    r.get("/png", gz_png);
    r.get("/varied", gz_varied);
    r.compress(compression());
    return r;
}

fn gz_get(r: Router[GzState], p: str, accept: str) -> http.Response {
    let rq = get_request(p);
    if len(accept) > 0 {
        rq = rq.header("Accept-Encoding", accept);
    }
    return r.serve(rq.build());
}

fn test_accept_encoding_is_read_with_its_q_values() {
    assert(accepts_gzip("gzip"));
    assert(accepts_gzip("GZIP"));
    assert(accepts_gzip("x-gzip"));
    assert(accepts_gzip("br, deflate, gzip;q=0.5"));
    assert(accepts_gzip("gzip; q=0.001"));
    assert(accepts_gzip("*"));
    assert(!accepts_gzip(""));
    assert(!accepts_gzip("br"));
    assert(!accepts_gzip("gzip;q=0"));
    assert(!accepts_gzip("gzip;q=0.000"));
    assert(!accepts_gzip("*;q=0"));
    // naming gzip wins over the wildcard, either way
    assert(!accepts_gzip("gzip;q=0, *"));
    assert(accepts_gzip("*;q=0, gzip"));
    // a q that cannot be read is not consent
    assert(!accepts_gzip("gzip;q=abc"));
    assert(!accepts_gzip("gzip;q=2"));
}

fn test_json_is_gzipped_for_a_client_that_accepts_it() {
    let r = gz_router(4096);
    let plain = gz_get(r, "/json", "");
    let gz = gz_get(r, "/json", "gzip, deflate, br");
    assert(resp_header(plain, "content-encoding") == "");
    assert(resp_header(gz, "content-encoding") == "gzip");
    assert(resp_header(gz, "vary") == "Accept-Encoding");
    assert(len(gz.body) < len(plain.body));
    let ur = compress.gunzip(gz.body, 1 << 20);
    guard let back = ur else let e = err_of(ur) { panic(e); }
    assert(back == plain.body);
    // the plain variant says it varies too, so a cache that stores it
    // first still keys on Accept-Encoding
    assert(resp_header(plain, "vary") == "Accept-Encoding");
    assert(resp_header(gz_get(gz_router(64), "/json", ""), "vary") == "");
}

fn test_what_is_not_worth_it_or_not_compressible_is_left_alone() {
    let small = gz_router(64);
    assert(resp_header(gz_get(small, "/json", "gzip"), "content-encoding") == "");
    let r = gz_router(4096);
    assert(resp_header(gz_get(r, "/png", "gzip"), "content-encoding") == "");
    assert(resp_header(gz_get(r, "/json", "gzip;q=0"), "content-encoding") == "");
    let head = r.serve(request(Method.HEAD, "/json").header("Accept-Encoding", "gzip").build());
    assert(resp_header(head, "content-encoding") == "");
}

fn test_an_existing_vary_is_extended() {
    let r = gz_router(4096);
    let resp = gz_get(r, "/varied", "gzip");
    assert(resp_header(resp, "content-encoding") == "gzip");
    assert(resp_header(resp, "vary") == "Origin, Accept-Encoding", resp_header(resp, "vary"));
}

fn test_a_strong_etag_becomes_weak_when_gzipped() {
    let r = gz_router(4096);
    r.etags();
    let gz = gz_get(r, "/json", "gzip");
    let tag = resp_header(gz, "etag");
    assert(strings.has_prefix(tag, "W/\""), tag);
    // and still answers a conditional request with 304
    let again = r.serve(get_request("/json").header("Accept-Encoding", "gzip")
        .header("If-None-Match", tag).build());
    assert(resp_status(again) == 304);
}
