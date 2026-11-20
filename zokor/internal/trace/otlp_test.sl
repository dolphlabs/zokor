import "strings";

fn sample_span() -> SpanData {
    return SpanData {
        trace_id: "4bf92f3577b34da6a3ce929d0e0e4736", span_id: "00f067aa0ba902b7",
        parent_id: "", name: "GET /orgs/:id", kind: KIND_SERVER,
        start_ns: 1700000000000000000, end_ns: 1700000000500000000,
        attrs: [attr_str("http.route", "/orgs/:id"), attr_int("http.response.status_code", 200)],
        failed: false, message: ""
    };
}

fn has_text(hay: str, needle: str) -> bool {
    return strings.contains(hay, needle);
}

fn test_span_json_has_the_required_fields() {
    let j = span_json(sample_span());
    assert(has_text(j, "\"traceId\":\"4bf92f3577b34da6a3ce929d0e0e4736\""));
    assert(has_text(j, "\"spanId\":\"00f067aa0ba902b7\""));
    assert(has_text(j, "\"name\":\"GET /orgs/:id\""));
    assert(has_text(j, "\"kind\":2"));
}

fn test_span_json_writes_big_integers_as_strings() {
    let j = span_json(sample_span());
    assert(has_text(j, "\"startTimeUnixNano\":\"1700000000000000000\""));
    assert(has_text(j, "\"endTimeUnixNano\":\"1700000000500000000\""));
    assert(has_text(j, "{\"key\":\"http.response.status_code\",\"value\":{\"intValue\":\"200\"}}"));
}

fn test_span_json_omits_an_empty_parent_and_a_good_status() {
    let j = span_json(sample_span());
    assert(!has_text(j, "parentSpanId"));
    assert(!has_text(j, "status\""));
}

fn test_span_json_includes_a_parent_and_a_failure() {
    let s = sample_span();
    s.parent_id = "b7ad6b7169203331";
    s.failed = true;
    s.message = "upstream said no";
    let j = span_json(s);
    assert(has_text(j, "\"parentSpanId\":\"b7ad6b7169203331\""));
    assert(has_text(j, "\"status\":{\"code\":2,\"message\":\"upstream said no\"}"));
}

fn test_span_json_escapes_what_it_did_not_write() {
    let s = sample_span();
    s.name = "quote \" and \\ and \n";
    let j = span_json(s);
    assert(has_text(j, "quote \\\" and \\\\ and \\n"));
}

fn test_export_json_wraps_spans_with_the_service_name() {
    let j = export_json("orders", ["{\"a\":1}", "{\"b\":2}"]);
    assert(has_text(j, "{\"key\":\"service.name\",\"value\":{\"stringValue\":\"orders\"}}"));
    assert(has_text(j, "\"spans\":[{\"a\":1},{\"b\":2}]"));
    assert(has_text(j, "\"scope\":{\"name\":\"zokor\"}"));
}

fn test_sampled_at_the_extremes_ignores_the_id() {
    assert(!sampled("ffffffffffffffffffffffffffffffff", 0.0));
    assert(sampled("ffffffffffffffffffffffffffffffff", 1.0));
}

fn test_sampled_compares_the_ids_last_bits() {
    assert(sampled("ffffffffffffffffffffffff00000001", 0.5));
    assert(!sampled("0000000000000000000000000ffffffe", 0.5));
}

// The promise that keeps a trace whole across services.
fn test_sampled_is_the_same_answer_every_time() {
    assert(sampled("abcdef0123456789abcdef0123456789", 0.3) ==
           sampled("abcdef0123456789abcdef0123456789", 0.3));
}

fn test_url_host_keeps_only_the_host() {
    assert(url_host("https://api.example.com/v1/users?token=secret") == "api.example.com");
    assert(url_host("http://user:pass@db.example.com:8080/x") == "db.example.com:8080");
    assert(url_host("https://example.com") == "example.com");
    assert(url_host("https://example.com?a=1") == "example.com");
    assert(url_host("https://example.com#frag") == "example.com");
}
