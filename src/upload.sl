// File uploads.
//
// `multipart/form-data` is how a browser posts files, and it is a
// format where being lax is a vulnerability: the client picks the
// delimiter, names the parts and supplies the filenames. So a handler
// states what it will accept, and anything else is a failure with a
// registered code rather than a surprise later:
//
//     fn avatar(c: zokor.Ctx[App]) -> http.Response {
//         let rules = zokor.uploads_allowing(["image/png", "image/jpeg"]);
//         let r = c.form(rules);
//         guard let form = r else let e = err_of(r) {
//             return zokor.respond_with(c.state.errors, e.code, e.detail,
//                                       c.request_id);
//         }
//         guard let f = zokor.file(form, "avatar") else {
//             return zokor.respond(c.state.errors, "bad_request", c.request_id);
//         }
//         // f.filename is already safe to put in a path
//         return zokor.ok_json("{\"bytes\":" + to_str(len(f.data)) + "}");
//     }
//
// The size limits are checked as the body is walked, so an oversized
// upload is refused without a copy of it being handed to a handler.
// What this does NOT do is stream: a body arrives whole, so a service
// that accepts hundreds of megabytes should set `max_total_bytes` and
// let the server refuse the request at read time instead.

import "http";
import "internal/multipart";

pub gc struct UploadRules {
    limits: multipart.Limits,
    // Empty means "anything". Otherwise a part's Content-Type must be
    // one of these, compared without parameters: "image/png" matches
    // "image/png; charset=binary".
    allowed_types: [str],
    // Empty means "anything". Extensions are compared lowercased,
    // with the dot: ".png".
    allowed_extensions: [str],
    // Reject a file part whose Content-Type is absent. On by default:
    // a type the client did not state is a type nobody checked.
    require_content_type: bool,
}

pub gc struct Upload {
    field: str,
    // Sanitised: no directories, no control characters, no leading
    // dot, never empty. `raw_filename` is what the client actually
    // sent, for a log or an error message.
    filename: str,
    raw_filename: str,
    content_type: str,
    data: bytes,
}

pub gc struct Form {
    values: map[str]str,
    files: [Upload],
}

// The reason a form was refused: a registered error code, and a
// sentence naming what was wrong. Handlers pass both to `respond_with`.
pub gc struct FormError {
    code: str,
    detail: str,
}

pub fn default_uploads() -> UploadRules {
    let types: [str] = [];
    let exts: [str] = [];
    return UploadRules {
        limits: multipart.default_limits(),
        allowed_types: types,
        allowed_extensions: exts,
        require_content_type: true
    };
}

pub fn uploads_allowing(types: [str]) -> UploadRules {
    let r = default_uploads();
    r.allowed_types = types;
    return r;
}

pub fn with_max_file_bytes(r: UploadRules, n: int) -> UploadRules {
    r.limits.max_file_bytes = n;
    return r;
}

pub fn with_max_total_bytes(r: UploadRules, n: int) -> UploadRules {
    r.limits.max_total_bytes = n;
    return r;
}

pub fn with_max_files(r: UploadRules, n: int) -> UploadRules {
    r.limits.max_files = n;
    return r;
}

pub fn with_extensions(r: UploadRules, exts: [str]) -> UploadRules {
    r.allowed_extensions = exts;
    return r;
}

// ---------------------------------------------------------------- //
// Parsing a request                                                  //
// ---------------------------------------------------------------- //

pub fn parse_form(content_type: str, body: bytes,
                  rules: UploadRules) -> result[Form, FormError] {
    let br = multipart.boundary_of(content_type);
    guard let boundary = br else let e = err_of(br) {
        return err(FormError { code: "unsupported_media_type", detail: e });
    }
    if len(body) > rules.limits.max_total_bytes {
        return err(FormError {
            code: "payload_too_large",
            detail: "the request body is larger than " +
                    to_str(rules.limits.max_total_bytes) + " bytes"
        });
    }
    let pr = multipart.parse(body, boundary, rules.limits);
    guard let parsed = pr else let e = err_of(pr) {
        return err(FormError { code: code_for(e), detail: e });
    }

    let values: map[str]str = {};
    let files: [Upload] = [];
    let i = 0;
    while i < len(parsed.parts) {
        let p = parsed.parts[i];
        if !multipart.is_file(p) {
            values[p.name] = to_str(p.data);
            i = i + 1;
            continue;
        }
        let ctype = media_type_of(p.content_type);
        if rules.require_content_type && len(ctype) == 0 {
            return err(FormError {
                code: "unsupported_media_type",
                detail: "file '" + p.name + "' was sent without a Content-Type"
            });
        }
        if len(rules.allowed_types) > 0 && !list_has(rules.allowed_types, ctype) {
            return err(FormError {
                code: "unsupported_media_type",
                detail: "file '" + p.name + "' is " + shown(ctype) +
                        ", which is not accepted here"
            });
        }
        let safe = safe_filename(p.filename);
        if len(rules.allowed_extensions) > 0 &&
           !list_has(rules.allowed_extensions, extension_of(safe)) {
            return err(FormError {
                code: "unsupported_media_type",
                detail: "file '" + p.name + "' has extension " +
                        shown(extension_of(safe)) + ", which is not accepted here"
            });
        }
        push(files, Upload {
            field: p.name,
            filename: safe,
            raw_filename: p.filename,
            content_type: ctype,
            data: p.data
        });
        i = i + 1;
    }
    return ok(Form { values: values, files: files });
}

// A size or count failure is a 413; anything else about the body's
// shape is the client sending nonsense.
fn code_for(detail: str) -> str {
    if contains(detail, "larger than") || contains(detail, "too many") {
        return "payload_too_large";
    }
    return "bad_request";
}

fn shown(v: str) -> str {
    if len(v) == 0 {
        return "untyped";
    }
    return "'" + v + "'";
}

// ---------------------------------------------------------------- //
// Reading a form                                                     //
// ---------------------------------------------------------------- //

pub fn value(f: Form, name: str) -> str {
    if has(f.values, name) {
        return f.values[name];
    }
    return "";
}

pub fn has_value(f: Form, name: str) -> bool {
    return has(f.values, name);
}

// The first file posted under a field name, which is the usual case.
pub fn file(f: Form, field: str) -> opt[Upload] {
    let i = 0;
    while i < len(f.files) {
        if f.files[i].field == field {
            return some(f.files[i]);
        }
        i = i + 1;
    }
    return none;
}

// Every file under one field name: `<input multiple>` posts repeats.
pub fn files_for(f: Form, field: str) -> [Upload] {
    let out: [Upload] = [];
    let i = 0;
    while i < len(f.files) {
        if f.files[i].field == field {
            push(out, f.files[i]);
        }
        i = i + 1;
    }
    return out;
}

pub fn total_bytes(f: Form) -> int {
    let n = 0;
    let i = 0;
    while i < len(f.files) {
        n = n + len(f.files[i].data);
        i = i + 1;
    }
    return n;
}

// ---------------------------------------------------------------- //
// Filenames                                                          //
// ---------------------------------------------------------------- //

// A client's filename, made safe to use as ONE path segment.
//
// Everything before the last slash or backslash is dropped, so
// "../../etc/passwd" and "C:\\evil.exe" become "passwd" and "evil.exe".
// Control characters, and the separators themselves, cannot survive. A
// leading dot is dropped so an upload cannot become ".bashrc", and a
// name that is empty after all that becomes "upload", because a handler
// that writes a file needs a name to write.
pub fn safe_filename(raw: str) -> str {
    let b = to_bytes(raw);
    let n = len(b);
    let start = 0;
    let i = 0;
    while i < n {
        if b[i] == 47 || b[i] == 92 {
            start = i + 1;
        }
        i = i + 1;
    }
    let out: bytes = b"";
    i = start;
    while i < n {
        let c = b[i];
        let bad = c < 32 || c == 127 || c == 47 || c == 92 || c == 0;
        if !bad {
            out = out + b[i..i + 1];
        }
        i = i + 1;
    }
    let s = trim_dots(to_str(out));
    if len(s) == 0 {
        return "upload";
    }
    return s;
}

fn trim_dots(s: str) -> str {
    let b = to_bytes(s);
    let n = len(b);
    let a = 0;
    while a < n && (b[a] == 46 || b[a] == 32) {
        a = a + 1;
    }
    let e = n;
    while e > a && b[e - 1] == 32 {
        e = e - 1;
    }
    if a == 0 && e == n {
        return s;
    }
    if a >= e {
        return "";
    }
    return to_str(b[a..e]);
}

// ".png" for "a.png", lowercased; "" when there is no extension.
pub fn extension_of(filename: str) -> str {
    let b = to_bytes(filename);
    let n = len(b);
    let dot = -1;
    let i = 0;
    while i < n {
        if b[i] == 46 {
            dot = i;
        }
        i = i + 1;
    }
    if dot < 0 || dot == n - 1 {
        return "";
    }
    return multipart.lower(to_str(b[dot..n]));
}

// The media type without its parameters: "image/png" from
// "image/png; charset=binary".
pub fn media_type_of(header: str) -> str {
    let b = to_bytes(header);
    let n = len(b);
    let end = n;
    let i = 0;
    while i < n {
        if b[i] == 59 {
            end = i;
            i = n;
        } else {
            i = i + 1;
        }
    }
    return multipart.lower(multipart.trim(to_str(b[0..end])));
}

fn list_has(xs: [str], v: str) -> bool {
    let i = 0;
    while i < len(xs) {
        if multipart.lower(xs[i]) == v {
            return true;
        }
        i = i + 1;
    }
    return false;
}

