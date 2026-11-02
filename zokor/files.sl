// Static files: a directory served under a path prefix, safely.
//
//     let m = zokor.files_at("/assets", "./public") ?? panic_mount();
//     m.max_age = 31536000;        // hashed file names: cache for a year
//     m.immutable = true;
//     r.files(m);
//
// A GET or HEAD under the prefix that no route claims is a file:
//   - traversal-safe: an encoded separator (%2f, %5c), a "..", "." or
//     dot-file segment (.env, .git), a backslash or a NUL is a 404, and
//     the file's real path -- every symlink resolved -- must be inside the
//     mount's real root, or it is a 404 too: a link cannot lead out;
//   - a directory answers its `index` file (index.html);
//   - conditional: ETag from size and modification time, Last-Modified,
//     304 and 412 as RFC 9110 has them (preconditions);
//   - ranges: one `Range: bytes=` range is a 206 with Content-Range (and
//     If-Range honoured); an unsatisfiable one a 416; several ranges get
//     the whole file, as the RFC allows;
//   - Content-Type by extension (unknown: application/octet-stream, which
//     nosniff keeps from being rendered), Cache-Control from `max_age`
//     (0: `no-cache`, revalidate every time), Accept-Ranges.
// Files are read whole (or the range) into memory, up to `max_size`; the
// read blocks a worker, so a mount suits an app's own assets -- put a CDN
// in front of large or busy ones.

import "fs";
import "http";
import "strings";
import "timez";

pub gc struct FileMount {
    // "/assets": no trailing slash; "" mounts at the root.
    prefix: str,
    // The directory's real path, resolved once.
    root: str,
    // Served for a directory; "" serves no index (404).
    index: str,
    // Cache-Control max-age in seconds; 0 sends "no-cache".
    max_age: int,
    // Adds "immutable": for file names that change with their content.
    immutable: bool,
    // Bigger files are refused with 500 rather than read into memory.
    max_size: int,
}

// A mount of `dir` under `prefix`. err when `dir` is not a directory.
pub fn files_at(prefix: str, dir: str) -> result[FileMount, str] {
    let p = prefix;
    while strings.has_suffix(p, "/") {
        p = strings.slice(p, 0, len(p) - 1);
    }
    if len(p) > 0 && !strings.has_prefix(p, "/") {
        return err("mount prefix '" + prefix + "' must start with /");
    }
    let rr = fs.realpath(dir);
    guard let root = rr else let e = err_of(rr) {
        return err("static files directory '" + dir + "': " + e);
    }
    let fr = fs.open(root);
    guard let fd = fr else let e = err_of(fr) {
        return err("static files directory '" + dir + "': " + e);
    }
    let st = fs.fstat(fd);
    fs.close(fd);
    if len(st) != 4 || st[0] != 1 {
        return err("static files directory '" + dir + "' is not a directory");
    }
    return ok(FileMount {
        prefix: p,
        root: root,
        index: "index.html",
        max_age: 0,
        immutable: false,
        max_size: 64 * 1024 * 1024
    });
}

// The part of `p` under `m`'s prefix ("/css/app.css"), or none.
fn mount_rest(m: FileMount, p: str) -> opt[str] {
    if len(m.prefix) == 0 {
        return some(p);
    }
    if p == m.prefix {
        return some("/");
    }
    if strings.has_prefix(p, m.prefix + "/") {
        return some(strings.slice(p, len(m.prefix), len(p)));
    }
    return none;
}

// Whether the raw (still percent-encoded) path could name something it
// should not: an encoded separator, or after decoding a backslash, a
// NUL, or a ".", ".." or dot-file segment.
fn unsafe_path(raw: str, decoded: str) -> bool {
    let lower = strings.to_lower(raw);
    if strings.contains(lower, "%2f") || strings.contains(lower, "%5c") ||
       strings.contains(lower, "%00") {
        return true;
    }
    if strings.contains(decoded, "\\") {
        return true;
    }
    for b in to_bytes(decoded) {
        if (b as int) == 0 {
            return true;
        }
    }
    for seg in strings.split(decoded, "/") {
        if strings.has_prefix(seg, ".") {
            return true;
        }
    }
    return false;
}

pub fn content_type_for(name: str) -> str {
    let dot = strings.rfind(name, ".");
    if dot < 0 {
        return "application/octet-stream";
    }
    let ext = strings.to_lower(strings.slice(name, dot + 1, len(name)));
    if ext == "html" || ext == "htm" { return "text/html; charset=utf-8"; }
    if ext == "css" { return "text/css; charset=utf-8"; }
    if ext == "js" || ext == "mjs" { return "text/javascript; charset=utf-8"; }
    if ext == "json" || ext == "map" { return "application/json"; }
    if ext == "txt" { return "text/plain; charset=utf-8"; }
    if ext == "csv" { return "text/csv; charset=utf-8"; }
    if ext == "xml" { return "application/xml"; }
    if ext == "svg" { return "image/svg+xml"; }
    if ext == "png" { return "image/png"; }
    if ext == "jpg" || ext == "jpeg" { return "image/jpeg"; }
    if ext == "gif" { return "image/gif"; }
    if ext == "webp" { return "image/webp"; }
    if ext == "avif" { return "image/avif"; }
    if ext == "ico" { return "image/x-icon"; }
    if ext == "woff2" { return "font/woff2"; }
    if ext == "woff" { return "font/woff"; }
    if ext == "ttf" { return "font/ttf"; }
    if ext == "wasm" { return "application/wasm"; }
    if ext == "pdf" { return "application/pdf"; }
    if ext == "mp4" { return "video/mp4"; }
    if ext == "webm" { return "video/webm"; }
    if ext == "mp3" { return "audio/mpeg"; }
    if ext == "zip" { return "application/zip"; }
    if ext == "gz" { return "application/gzip"; }
    return "application/octet-stream";
}

// The answer for a GET or HEAD of `rest` (the path under the mount).
fn serve_file[S](m: FileMount, c: Ctx[S], rest: str) -> http.Response {
    let raw = path.strip_query(c.req.path);
    let decoded = path.percent_decode(rest);
    if unsafe_path(raw, decoded) {
        return respond(c.errors, "not_found", c.request_id);
    }
    let want = m.root + decoded;
    let rr = fs.realpath(want);
    guard let real = rr else {
        return respond(c.errors, "not_found", c.request_id);
    }
    if real != m.root && !strings.has_prefix(real, m.root + "/") {
        return respond(c.errors, "not_found", c.request_id);
    }
    let fr = fs.open(real);
    guard let fd = fr else {
        return respond(c.errors, "not_found", c.request_id);
    }
    let st = fs.fstat(fd);
    if len(st) == 4 && st[0] == 1 {
        fs.close(fd);
        if len(m.index) == 0 {
            return respond(c.errors, "not_found", c.request_id);
        }
        let ir = fs.realpath(real + "/" + m.index);
        guard let ireal = ir else {
            return respond(c.errors, "not_found", c.request_id);
        }
        if !strings.has_prefix(ireal, m.root + "/") {
            return respond(c.errors, "not_found", c.request_id);
        }
        let ifr = fs.open(ireal);
        guard let ifd = ifr else {
            return respond(c.errors, "not_found", c.request_id);
        }
        return answer_file(m, c, ifd, ireal);
    }
    return answer_file(m, c, fd, real);
}

// Reads `n` bytes from `off`, or what the file has; closes nothing.
fn read_span(fd: i32, off: int, n: int) -> result[bytes, str] {
    let sb = builder.new_bytes();
    let got = 0;
    while got < n {
        let want = n - got;
        if want > 65536 {
            want = 65536;
        }
        let pr = fs.pread(fd, off + got, want);
        guard let chunk = pr else let e = err_of(pr) {
            return err(e);
        }
        if len(chunk) == 0 {
            break;
        }
        sb.write(chunk);
        got = got + len(chunk);
    }
    return ok(sb.finish());
}

fn answer_file[S](m: FileMount, c: Ctx[S], fd: i32, real: str) -> http.Response {
    let st = fs.fstat(fd);
    if len(st) != 4 || st[0] != 0 {
        fs.close(fd);
        return respond(c.errors, "not_found", c.request_id);
    }
    let size = st[1];
    if size > m.max_size {
        fs.close(fd);
        return respond_with(c.errors, "internal", "a static file is larger than the mount's max_size",
                            c.request_id);
    }
    let mtime = timez.Time { sec: st[2], nsec: 0 };
    let tag = "\"" + to_str(size) + "-" + to_str(st[2]) + "-" + to_str(st[3]) + "\"";
    if let stop = preconditions(c, tag, some(mtime)) {
        fs.close(fd);
        return file_headers(m, stop, real);
    }
    let start = 0;
    let end = size;      // exclusive
    let partial = false;
    let rh = c.header("range");
    if len(rh) > 0 && size > 0 && if_range_ok(c.header("if-range"), tag, mtime) {
        let sp = parse_range(rh, size);
        if sp[0] == -2 {
            fs.close(fd);
            let r416 = respond(c.errors, "range_not_satisfiable", c.request_id);
            return http.with_header(r416, "content-range", "bytes */" + to_str(size));
        }
        if sp[0] >= 0 {
            start = sp[0];
            end = sp[1] + 1;
            partial = true;
        }
    }
    let br = read_span(fd, start, end - start);
    fs.close(fd);
    guard let body = br else let e = err_of(br) {
        return respond_with(c.errors, "internal", "reading a static file: " + e, c.request_id);
    }
    let resp = bytes_of(200, content_type_for(real), body);
    if partial {
        resp.status = 206;
        resp.status_text = "Partial Content";
        resp = http.with_header(resp, "content-range",
                                "bytes " + to_str(start) + "-" + to_str(end - 1) + "/" + to_str(size));
    }
    resp = with_validators(resp, tag, some(mtime));
    return file_headers(m, resp, real);
}

fn file_headers(m: FileMount, resp: http.Response, real: str) -> http.Response {
    let out = http.with_header(resp, "accept-ranges", "bytes");
    let cc = "no-cache";
    if m.max_age > 0 {
        cc = "public, max-age=" + to_str(m.max_age);
        if m.immutable {
            cc = cc + ", immutable";
        }
    }
    return http.with_header(out, "cache-control", cc);
}

// Whether a Range applies: no If-Range, or one naming the current tag
// (compared strongly) or a date at or after the modification time.
fn if_range_ok(if_range: str, tag: str, mtime: timez.Time) -> bool {
    let v = strings.trim(if_range);
    if len(v) == 0 {
        return true;
    }
    if strings.has_prefix(v, "\"") {
        return v == tag;
    }
    if strings.has_prefix(v, "W/") {
        return false;
    }
    let dr = timez.parse_http_date(v);
    if let d = dr {
        return d.unix() >= mtime.unix();
    }
    return false;
}

// One byte range of a file of `size`: [first, last] inclusive; [-1, -1]
// when the header is not one usable range (several, another unit,
// malformed: the whole file is sent); [-2, -2] when it cannot be
// satisfied (416).
pub fn parse_range(header: str, size: int) -> [int] {
    let h = strings.trim(header);
    if !strings.has_prefix(h, "bytes=") {
        return [-1, -1];
    }
    let spec = strings.trim(strings.slice(h, 6, len(h)));
    if strings.contains(spec, ",") {
        return [-1, -1];
    }
    let dash = strings.find(spec, "-");
    if dash < 0 {
        return [-1, -1];
    }
    let a = strings.trim(strings.slice(spec, 0, dash));
    let b = strings.trim(strings.slice(spec, dash + 1, len(spec)));
    if len(a) == 0 {
        // the last b bytes
        let nr = to_int(b);
        guard let n = nr else { return [-1, -1]; }
        if n <= 0 {
            return [-2, -2];
        }
        if n > size {
            n = size;
        }
        return [size - n, size - 1];
    }
    let fr = to_int(a);
    guard let first = fr else { return [-1, -1]; }
    if first < 0 {
        return [-1, -1];
    }
    if first >= size {
        return [-2, -2];
    }
    if len(b) == 0 {
        return [first, size - 1];
    }
    let lr = to_int(b);
    guard let last = lr else { return [-1, -1]; }
    if last < first {
        return [-1, -1];
    }
    if last >= size {
        last = size - 1;
    }
    return [first, last];
}
