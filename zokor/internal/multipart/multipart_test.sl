fn crlf(lines: [str]) -> bytes {
    let out = "";
    let i = 0;
    while i < len(lines) {
        out = out + lines[i] + "\r\n";
        i = i + 1;
    }
    return to_bytes(out);
}

fn body_one_file() -> bytes {
    return crlf([
        "--X",
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"a.txt\"",
        "Content-Type: text/plain",
        "",
        "hello",
        "--X--"
    ]);
}

fn parsed_or_panic(b: bytes, boundary: str) -> Parsed {
    let r = parse(b, boundary, default_limits());
    guard let p = r else let e = err_of(r) {
        panic("expected a parse, got: " + e);
    }
    return p;
}

fn reason(b: bytes, boundary: str, lim: Limits) -> str {
    let r = parse(b, boundary, lim);
    guard let _p = r else let e = err_of(r) {
        return e;
    }
    return "";
}

fn test_boundary_of() {
    guard let b1 = boundary_of("multipart/form-data; boundary=X") else {
        panic("plain boundary");
    }
    assert(b1 == "X");
    guard let b2 = boundary_of("multipart/form-data; boundary=\"a;b\"") else {
        panic("quoted boundary");
    }
    assert(b2 == "a;b");
    guard let b3 = boundary_of("MULTIPART/FORM-DATA; charset=utf-8; boundary=Y") else {
        panic("case and extra params");
    }
    assert(b3 == "Y");
    guard let b4 = boundary_of("multipart/form-data;boundary=Z ") else {
        panic("no space after semicolon");
    }
    assert(b4 == "Z");
}

fn test_boundary_rejections() {
    let r1 = boundary_of("application/json");
    guard let _a = r1 else let e = err_of(r1) {
        assert(e == "expected multipart/form-data, got application/json");
        let r2 = boundary_of("multipart/form-data");
        guard let _b = r2 else let e2 = err_of(r2) {
            assert(e2 == "multipart/form-data without a boundary parameter");
            let r3 = boundary_of("multipart/form-data; boundary=");
            guard let _c = r3 else let e3 = err_of(r3) {
                assert(e3 == "multipart boundary is empty");
                return;
            }
            panic("empty boundary accepted");
        }
        panic("missing boundary accepted");
    }
    panic("wrong media type accepted");
}

fn test_boundary_too_long() {
    let long = "";
    let i = 0;
    while i < 71 {
        long = long + "a";
        i = i + 1;
    }
    let r = boundary_of("multipart/form-data; boundary=" + long);
    guard let _b = r else let e = err_of(r) {
        assert(e == "multipart boundary is longer than 70 characters");
        return;
    }
    panic("a 71-character boundary was accepted");
}

fn test_one_file() {
    let p = parsed_or_panic(body_one_file(), "X");
    assert(len(p.parts) == 1);
    let f = p.parts[0];
    assert(f.name == "avatar");
    assert(f.filename == "a.txt");
    assert(f.content_type == "text/plain");
    assert(to_str(f.data) == "hello");
    assert(is_file(f));
}

fn test_fields_and_files_together() {
    let b = crlf([
        "--X",
        "Content-Disposition: form-data; name=\"title\"",
        "",
        "My holiday",
        "--X",
        "Content-Disposition: form-data; name=\"tags\"",
        "",
        "a,b,c",
        "--X",
        "Content-Disposition: form-data; name=\"photo\"; filename=\"p.jpg\"",
        "Content-Type: image/jpeg",
        "",
        "JPEGDATA",
        "--X--"
    ]);
    let p = parsed_or_panic(b, "X");
    assert(len(p.parts) == 3);
    assert(p.parts[0].name == "title");
    assert(to_str(p.parts[0].data) == "My holiday");
    assert(!is_file(p.parts[0]));
    assert(p.parts[1].name == "tags");
    assert(is_file(p.parts[2]));
    assert(p.parts[2].content_type == "image/jpeg");
    assert(to_str(p.parts[2].data) == "JPEGDATA");
}

fn test_empty_file_and_empty_field() {
    let b = crlf([
        "--X",
        "Content-Disposition: form-data; name=\"empty\"; filename=\"e.txt\"",
        "",
        "",
        "--X",
        "Content-Disposition: form-data; name=\"blank\"",
        "",
        "",
        "--X--"
    ]);
    let p = parsed_or_panic(b, "X");
    assert(len(p.parts) == 2);
    assert(len(p.parts[0].data) == 0);
    assert(is_file(p.parts[0]));
    assert(len(p.parts[1].data) == 0);
}

fn test_binary_payload_survives_intact() {
    let head = to_bytes("--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"b.bin\"\r\n\r\n");
    let payload: bytes = b"....";
    payload[0] = 0;
    payload[1] = 13;
    payload[2] = 10;
    payload[3] = 255;
    let tail = to_bytes("\r\n--X--\r\n");
    let p = parsed_or_panic(head + payload + tail, "X");
    assert(len(p.parts) == 1);
    let d = p.parts[0].data;
    assert(len(d) == 4);
    assert(d[0] == 0);
    assert(d[1] == 13);
    assert(d[2] == 10);
    assert(d[3] == 255);
}

// The delimiter only counts at the start of a line, so a file whose
// contents contain the boundary text does not end early.
fn test_boundary_text_inside_a_file() {
    let b = crlf([
        "--X",
        "Content-Disposition: form-data; name=\"f\"; filename=\"t.txt\"",
        "",
        "a --X b",
        "--X--"
    ]);
    let p = parsed_or_panic(b, "X");
    assert(len(p.parts) == 1);
    assert(to_str(p.parts[0].data) == "a --X b");
}

fn test_preamble_and_epilogue_are_ignored() {
    let b = to_bytes("ignored preamble\r\n") + body_one_file() +
            to_bytes("\r\nignored epilogue\r\n");
    let p = parsed_or_panic(b, "X");
    assert(len(p.parts) == 1);
    assert(to_str(p.parts[0].data) == "hello");
}

fn test_quoted_and_escaped_names() {
    let b = crlf([
        "--X",
        "Content-Disposition: form-data; name=\"weird;name\"; filename=\"a\\\"b.txt\"",
        "",
        "v",
        "--X--"
    ]);
    let p = parsed_or_panic(b, "X");
    assert(p.parts[0].name == "weird;name");
    assert(p.parts[0].filename == "a\"b.txt");
}

fn test_rfc5987_filename() {
    let b = crlf([
        "--X",
        "Content-Disposition: form-data; name=\"f\"; filename=\"mojibake\"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf",
        "",
        "v",
        "--X--"
    ]);
    let p = parsed_or_panic(b, "X");
    assert(p.parts[0].filename == "résumé.pdf");
}

fn test_header_order_and_case_do_not_matter() {
    let b = crlf([
        "--X",
        "CONTENT-TYPE: text/csv",
        "content-disposition: form-data; name=\"f\"; filename=\"a.csv\"",
        "X-Other: ignored",
        "",
        "1,2",
        "--X--"
    ]);
    let p = parsed_or_panic(b, "X");
    assert(p.parts[0].content_type == "text/csv");
    assert(p.parts[0].filename == "a.csv");
}

fn test_truncated_body_is_rejected() {
    let b = crlf([
        "--X",
        "Content-Disposition: form-data; name=\"f\"; filename=\"a.txt\"",
        "",
        "half written"
    ]);
    assert(reason(b, "X", default_limits()) ==
           "multipart body ends without its closing boundary");
}

fn test_missing_opening_boundary() {
    let b = to_bytes("no boundaries here at all, just text\r\n");
    assert(reason(b, "X", default_limits()) ==
           "multipart body has no opening boundary");
}

fn test_part_without_disposition_or_name() {
    let b1 = crlf(["--X", "Content-Type: text/plain", "", "v", "--X--"]);
    assert(reason(b1, "X", default_limits()) ==
           "a multipart part has no Content-Disposition header");
    let b2 = crlf([
        "--X",
        "Content-Disposition: form-data; filename=\"a.txt\"",
        "",
        "v",
        "--X--"
    ]);
    assert(reason(b2, "X", default_limits()) == "a multipart part has no name");
}

fn test_headers_without_a_blank_line() {
    let b = crlf([
        "--X",
        "Content-Disposition: form-data; name=\"f\"",
        "--X--"
    ]);
    assert(reason(b, "X", default_limits()) ==
           "a multipart part has no blank line after its headers");
}

fn test_malformed_header_line() {
    let b = crlf([
        "--X",
        "Content-Disposition: form-data; name=\"f\"",
        "this line has no colon",
        "",
        "v",
        "--X--"
    ]);
    assert(reason(b, "X", default_limits()) ==
           "a multipart part has a malformed header line");
}

fn test_unsupported_transfer_encoding() {
    let b = crlf([
        "--X",
        "Content-Disposition: form-data; name=\"f\"; filename=\"a.txt\"",
        "Content-Transfer-Encoding: base64",
        "",
        "aGk=",
        "--X--"
    ]);
    assert(reason(b, "X", default_limits()) ==
           "unsupported Content-Transfer-Encoding 'base64'");
}

fn small_limits() -> Limits {
    return Limits {
        max_parts: 2,
        max_files: 1,
        max_file_bytes: 4,
        max_field_bytes: 3,
        max_total_bytes: 6,
        max_headers_bytes: 200,
        max_filename_bytes: 5
    };
}

fn test_limits_are_enforced() {
    let big_file = crlf([
        "--X",
        "Content-Disposition: form-data; name=\"f\"; filename=\"a.txt\"",
        "",
        "toolong",
        "--X--"
    ]);
    assert(reason(big_file, "X", small_limits()) ==
           "file 'a.txt' is larger than 4 bytes");

    let big_field = crlf([
        "--X",
        "Content-Disposition: form-data; name=\"f\"",
        "",
        "toolong",
        "--X--"
    ]);
    assert(reason(big_field, "X", small_limits()) ==
           "field 'f' is larger than 3 bytes");

    let many = crlf([
        "--X", "Content-Disposition: form-data; name=\"a\"", "", "1",
        "--X", "Content-Disposition: form-data; name=\"b\"", "", "2",
        "--X", "Content-Disposition: form-data; name=\"c\"", "", "3",
        "--X--"
    ]);
    assert(reason(many, "X", small_limits()) ==
           "too many parts: at most 2 are accepted");

    let two_files = crlf([
        "--X", "Content-Disposition: form-data; name=\"a\"; filename=\"a\"", "", "1",
        "--X", "Content-Disposition: form-data; name=\"b\"; filename=\"b\"", "", "2",
        "--X--"
    ]);
    assert(reason(two_files, "X", small_limits()) ==
           "too many files: at most 1 are accepted");

    let long_name = crlf([
        "--X",
        "Content-Disposition: form-data; name=\"f\"; filename=\"toolong.txt\"",
        "",
        "v",
        "--X--"
    ]);
    assert(reason(long_name, "X", small_limits()) ==
           "a filename is longer than 5 bytes");
}

fn test_total_size_is_enforced() {
    let b = crlf([
        "--X", "Content-Disposition: form-data; name=\"a\"", "", "123",
        "--X", "Content-Disposition: form-data; name=\"b\"", "", "456",
        "--X", "Content-Disposition: form-data; name=\"c\"", "", "789",
        "--X--"
    ]);
    let lim = Limits {
        max_parts: 10,
        max_files: 10,
        max_file_bytes: 100,
        max_field_bytes: 100,
        max_total_bytes: 5,
        max_headers_bytes: 200,
        max_filename_bytes: 100
    };
    assert(reason(b, "X", lim) == "upload is larger than 5 bytes in total");
}

fn test_lf_only_bodies_are_tolerated() {
    let b = to_bytes("--X\nContent-Disposition: form-data; name=\"f\"\n\nvalue\n--X--\n");
    let p = parsed_or_panic(b, "X");
    assert(len(p.parts) == 1);
    assert(to_str(p.parts[0].data) == "value");
}
