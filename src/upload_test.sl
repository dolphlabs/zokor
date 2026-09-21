import "http";

fn form_body(boundary: str, lines: [str]) -> bytes {
    let out = "";
    let i = 0;
    while i < len(lines) {
        out = out + lines[i] + "\r\n";
        i = i + 1;
    }
    return to_bytes(out);
}

fn one_png(name: str, filename: str) -> bytes {
    return form_body("X", [
        "--X",
        "Content-Disposition: form-data; name=\"" + name + "\"; filename=\"" + filename + "\"",
        "Content-Type: image/png",
        "",
        "PNGDATA",
        "--X--"
    ]);
}

fn ct() -> str {
    return "multipart/form-data; boundary=X";
}

fn parsed(body: bytes, rules: UploadRules) -> Form {
    let r = parse_form(ct(), body, rules);
    guard let f = r else let e = err_of(r) {
        panic("expected a form, got " + e.code + ": " + e.detail);
    }
    return f;
}

fn failure(body: bytes, rules: UploadRules) -> FormError {
    let r = parse_form(ct(), body, rules);
    guard let _f = r else let e = err_of(r) {
        return e;
    }
    panic("expected a failure");
}

fn test_fields_and_files() {
    let b = form_body("X", [
        "--X",
        "Content-Disposition: form-data; name=\"title\"",
        "",
        "Holiday",
        "--X",
        "Content-Disposition: form-data; name=\"photo\"; filename=\"p.png\"",
        "Content-Type: image/png",
        "",
        "PNGDATA",
        "--X--"
    ]);
    let f = parsed(b, default_uploads());
    assert(value(f, "title") == "Holiday");
    assert(has_value(f, "title"));
    assert(!has_value(f, "nope"));
    assert(value(f, "nope") == "");
    assert(len(f.files) == 1);
    guard let up = file(f, "photo") else {
        panic("expected the photo");
    }
    assert(up.filename == "p.png");
    assert(up.content_type == "image/png");
    assert(to_str(up.data) == "PNGDATA");
    assert(total_bytes(f) == 7);
    guard let _missing = file(f, "other") else {
        return;
    }
    panic("a file that was not posted was found");
}

fn test_multiple_files_under_one_field() {
    let b = form_body("X", [
        "--X",
        "Content-Disposition: form-data; name=\"docs\"; filename=\"a.txt\"",
        "Content-Type: text/plain",
        "",
        "A",
        "--X",
        "Content-Disposition: form-data; name=\"docs\"; filename=\"b.txt\"",
        "Content-Type: text/plain",
        "",
        "BB",
        "--X--"
    ]);
    let f = parsed(b, default_uploads());
    let docs = files_for(f, "docs");
    assert(len(docs) == 2);
    assert(docs[0].filename == "a.txt");
    assert(docs[1].filename == "b.txt");
    assert(total_bytes(f) == 3);
    assert(len(files_for(f, "other")) == 0);
}

fn test_content_type_allowlist() {
    let rules = uploads_allowing(["image/png", "image/jpeg"]);
    let ok_form = parsed(one_png("photo", "p.png"), rules);
    assert(len(ok_form.files) == 1);

    let gif = form_body("X", [
        "--X",
        "Content-Disposition: form-data; name=\"photo\"; filename=\"p.gif\"",
        "Content-Type: image/gif",
        "",
        "GIF",
        "--X--"
    ]);
    let e = failure(gif, rules);
    assert(e.code == "unsupported_media_type");
    assert(e.detail == "file 'photo' is 'image/gif', which is not accepted here");
}

fn test_content_type_parameters_are_ignored_when_matching() {
    let b = form_body("X", [
        "--X",
        "Content-Disposition: form-data; name=\"photo\"; filename=\"p.png\"",
        "Content-Type: IMAGE/PNG; charset=binary",
        "",
        "PNGDATA",
        "--X--"
    ]);
    let f = parsed(b, uploads_allowing(["image/png"]));
    guard let up = file(f, "photo") else {
        panic("expected the photo");
    }
    assert(up.content_type == "image/png");
}

fn test_untyped_file_is_refused_by_default() {
    let b = form_body("X", [
        "--X",
        "Content-Disposition: form-data; name=\"f\"; filename=\"a.bin\"",
        "",
        "DATA",
        "--X--"
    ]);
    let e = failure(b, default_uploads());
    assert(e.code == "unsupported_media_type");
    assert(e.detail == "file 'f' was sent without a Content-Type");

    let lax = default_uploads();
    lax.require_content_type = false;
    let f = parsed(b, lax);
    assert(len(f.files) == 1);
    assert(f.files[0].content_type == "");
}

fn test_extension_allowlist() {
    let rules = with_extensions(default_uploads(), [".png", ".jpg"]);
    assert(len(parsed(one_png("photo", "p.png"), rules).files) == 1);
    let e = failure(one_png("photo", "p.svg"), rules);
    assert(e.code == "unsupported_media_type");
    assert(e.detail == "file 'photo' has extension '.svg', which is not accepted here");
}

fn test_size_limits_map_to_413() {
    let small = with_max_file_bytes(default_uploads(), 3);
    let e = failure(one_png("photo", "p.png"), small);
    assert(e.code == "payload_too_large");
    assert(e.detail == "file 'p.png' is larger than 3 bytes");

    let tiny_total = with_max_total_bytes(default_uploads(), 2);
    let e2 = failure(one_png("photo", "p.png"), tiny_total);
    assert(e2.code == "payload_too_large");

    let one_file = with_max_files(default_uploads(), 1);
    let two = form_body("X", [
        "--X",
        "Content-Disposition: form-data; name=\"a\"; filename=\"a.png\"",
        "Content-Type: image/png",
        "",
        "A",
        "--X",
        "Content-Disposition: form-data; name=\"b\"; filename=\"b.png\"",
        "Content-Type: image/png",
        "",
        "B",
        "--X--"
    ]);
    let e3 = failure(two, one_file);
    assert(e3.code == "payload_too_large");
    assert(e3.detail == "too many files: at most 1 are accepted");
}

fn test_wrong_media_type_and_malformed_body() {
    let r = parse_form("application/json", to_bytes("{}"), default_uploads());
    guard let _f = r else let e = err_of(r) {
        assert(e.code == "unsupported_media_type");
        let r2 = parse_form(ct(), to_bytes("not multipart at all"),
                            default_uploads());
        guard let _f2 = r2 else let e2 = err_of(r2) {
            assert(e2.code == "bad_request");
            return;
        }
        panic("a body with no boundary was accepted");
    }
    panic("application/json was accepted as a form");
}

fn test_filenames_are_made_safe() {
    assert(safe_filename("../../etc/passwd") == "passwd");
    assert(safe_filename("C:\\Windows\\evil.exe") == "evil.exe");
    assert(safe_filename("/absolute/path.txt") == "path.txt");
    assert(safe_filename(".bashrc") == "bashrc");
    assert(safe_filename("..") == "upload");
    assert(safe_filename("") == "upload");
    assert(safe_filename("   ") == "upload");
    assert(safe_filename("ok name.png") == "ok name.png");
    assert(safe_filename("résumé.pdf") == "résumé.pdf");
}

fn test_the_raw_filename_is_kept_for_reporting() {
    let f = parsed(one_png("photo", "../../etc/passwd"), default_uploads());
    guard let up = file(f, "photo") else {
        panic("expected the file");
    }
    assert(up.filename == "passwd");
    assert(up.raw_filename == "../../etc/passwd");
}

fn test_extension_and_media_helpers() {
    assert(extension_of("a.PNG") == ".png");
    assert(extension_of("archive.tar.gz") == ".gz");
    assert(extension_of("noext") == "");
    assert(extension_of("trailing.") == "");
    assert(media_type_of("image/png; charset=binary") == "image/png");
    assert(media_type_of("  IMAGE/PNG  ") == "image/png");
    assert(media_type_of("") == "");
}

fn upload_req(method: str, body: bytes, content_type: str) -> http.Request {
    let h: map[str]str = {};
    h["content-type"] = content_type;
    return http.Request {
        method: method,
        path: "/upload",
        version: "HTTP/1.1",
        headers: h,
        body: body
    };
}

gc struct UpState { n: int }

fn test_ctx_form_and_upload() {
    let st = UpState { n: 0 };
    let empty: map[str]str = {};
    let c = Ctx[UpState] {
        state: st,
        req: upload_req("POST", one_png("photo", "p.png"), ct()),
        params: empty,
        route: "/upload",
        request_id: "r1"
    };
    let r = c.upload(uploads_allowing(["image/png"]));
    guard let f = r else {
        panic("expected the upload to parse");
    }
    assert(len(f.files) == 1);

    // a GET with a body is not an upload
    let c2 = Ctx[UpState] {
        state: st,
        req: upload_req("GET", one_png("photo", "p.png"), ct()),
        params: empty,
        route: "/upload",
        request_id: "r2"
    };
    let r2 = c2.upload(default_uploads());
    guard let _f2 = r2 else let e = err_of(r2) {
        assert(e.code == "method_not_allowed");
        // but `form` itself does not care about the verb
        let r3 = c2.form(uploads_allowing(["image/png"]));
        guard let _f3 = r3 else {
            panic("form should not check the method");
        }
        return;
    }
    panic("a GET upload was accepted");
}
