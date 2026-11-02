fn test_quality_uses_exact_thousandths_and_refuses_ambiguity() {
    assert((quality("0.001") ?? -1) == 1 && (quality("0.") ?? -1) == 0 && (quality("1.000") ?? -1) == 1000);
    for raw in ["", "1.001", "0.0001", ".5", "01", "-1", "2", "0e0"] {
        let parsed = quality(raw); guard let _q = parsed else { continue; } panic("bad q accepted: " + raw);
    }
}

fn test_ranges_keep_quoted_commas_escapes_and_parameters_after_q() {
    let parsed = ranges("TEXT/PLAIN;q=0.7;title=\"a,b\\\"c\";charset=UTF-8, text/*", 8192, 64, 32);
    guard let rs = parsed else let e = err_of(parsed) { panic(e); }
    assert(len(rs) == 2 && rs[0].mtype == "text" && rs[0].quality == 700);
    assert(rs[0].params[1] == "a,b\"c" && rs[0].params[3] == "utf-8");
}

fn test_specific_ranges_override_wildcard_quality_and_q_zero() {
    let header: opt[str] = some("text/*;q=1, text/html;q=0, application/json;q=0.5");
    assert((choose(header, ["text", "application"], ["html", "json"], [[], []], 8192, 64, 32) ?? -2) == 1);
    let no_header: opt[str] = none;
    assert((choose(no_header, ["text"], ["plain"], [[]], 8192, 64, 32) ?? -2) == 0);
    assert((choose(some(""), ["text"], ["plain"], [[]], 8192, 64, 32) ?? -2) == -1);
}

fn test_parser_refuses_bad_quotes_duplicate_parameters_and_limits() {
    for raw in ["text /plain", "*/json", "text/html;q=0;q=1", "text/html;q=\"1\"", "text/plain;level=1;level=2", "text/plain; title=\"broken", "text/plain;level =1", "text/plain\n"] {
        let parsed = ranges(raw, 8192, 64, 32); guard let _v = parsed else { continue; } panic("bad range accepted: " + raw);
    }
    let bytes_ = ranges("text/plain", 3, 64, 32);
    let count = ranges(",,,text/plain", 8192, 2, 32);
    let params_ = ranges("text/plain;a=1;b=2", 8192, 64, 1);
    assert(err_of(bytes_) == "Accept exceeds max_bytes");
    assert(err_of(count) == "Accept exceeds max_ranges");
    assert(err_of(params_) == "range 1: parameters exceed max_params");
}

fn test_header_combines_lines_preserving_quoted_whitespace_and_empty_values() {
    let combined = header(b"Accept: text/plain;title=\"a, b\"\r\nACCEPT: application/json\r\n", 100);
    guard let h = combined else { panic("header rejected"); }
    assert((h ?? "missing") == "text/plain;title=\"a, b\",application/json");
    let empty = header(b"Accept:\r\n", 1);
    guard let e = empty else { panic("empty rejected"); }
    assert((e ?? "missing") == "");
    let absent = header(b"X-Accept: ignored\r\n", 1);
    guard let a = absent else { panic("absent rejected"); }
    assert((a ?? "missing") == "missing");
    let bad = header(b"Accept: text/plain\r\nAccept: text/html\r\n", 10);
    guard let _b = bad else { return; } panic("combined header limit bypassed");
}
fn test_parameter_specificity_controls_the_quality_of_an_offer() {
    let h: opt[str] = some("text/*;q=0.3, text/html;q=0.7, text/html;level=1, text/html;level=2;q=0.4, */*;q=0.1");
    let picked = choose(h, ["text", "text", "text", "image"], ["html", "html", "html", "jpeg"],
        [["level", "2"], [], ["level", "1"], []], 8192, 64, 32);
    assert((picked ?? -1) == 2);
    let ties = choose(some("text/html, application/json"), ["application", "text"], ["json", "html"], [[], []], 8192, 64, 32);
    assert((ties ?? -1) == 1);
}
