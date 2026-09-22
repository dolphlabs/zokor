// multipart/form-data, parsed from a complete body.
//
// This is the format browsers post files in, and it is a minefield:
// the delimiter is chosen by the client, parts carry their own headers,
// a filename may be absent, quoted, or hostile, and the body may simply
// stop in the middle. Everything here is therefore explicit about what
// it accepts, and every limit is a parameter rather than a constant, so
// a service decides what it can afford rather than the framework.
//
// Cost: the body is scanned once for the delimiter, and the only bytes
// copied are the ones handed back (each part's payload and its header
// values). Nothing is copied per byte, and no part is copied twice.
//
// What is refused, rather than guessed at:
//   * a Content-Type that is not multipart/form-data, or has no boundary
//   * a boundary that is empty, over 70 characters, or badly quoted
//   * a body that ends before the closing delimiter
//   * a part whose headers are unterminated, oversized, or malformed
//   * a part with no name
//   * anything over the caller's limits (count, per-file, total)
//   * Content-Transfer-Encoding other than the ones the web actually
//     uses (7bit/8bit/binary, which all mean "as-is")

import "builder";

pub gc struct Limits {
    max_parts: int,        // total parts, files and fields together
    max_files: int,
    max_file_bytes: int,   // per file
    max_field_bytes: int,  // per non-file field
    max_total_bytes: int,  // sum of every part payload
    max_headers_bytes: int,// per part's header block
    max_filename_bytes: int,
}

pub fn default_limits() -> Limits {
    return Limits {
        max_parts: 64,
        max_files: 16,
        max_file_bytes: 16777216,     // 16 MiB
        max_field_bytes: 1048576,     // 1 MiB
        max_total_bytes: 67108864,    // 64 MiB
        max_headers_bytes: 8192,
        max_filename_bytes: 255
    };
}

pub gc struct Part {
    name: str,          // the form field name
    filename: str,      // "" when the part is not a file
    content_type: str,  // as sent, or "" -- never guessed
    data: bytes,
}

pub gc struct Parsed {
    parts: [Part],
}

pub fn is_file(p: Part) -> bool {
    return len(p.filename) > 0;
}

// ---------------------------------------------------------------- //
// Content-Type                                                       //
// ---------------------------------------------------------------- //

// The boundary from a Content-Type header, or an error saying which
// part of it was wrong. RFC 2046: 1-70 characters, and it may be
// quoted, which is the form Safari and curl both emit for boundaries
// containing punctuation.
pub fn boundary_of(content_type: str) -> result[str, str] {
    let b = to_bytes(content_type);
    let n = len(b);
    let semi = -1;
    let i = 0;
    while i < n {
        if b[i] == 59 {
            semi = i;
            i = n;
        } else {
            i = i + 1;
        }
    }
    let head = n;
    if semi >= 0 {
        head = semi;
    }
    let media = lower(trim(to_str(b[0..head])));
    if media != "multipart/form-data" {
        if media == "" {
            return err("a Content-Type of multipart/form-data is required");
        }
        return err("expected multipart/form-data, got " + media);
    }
    if semi < 0 {
        return err("multipart/form-data without a boundary parameter");
    }
    // parameters, semicolon-separated, boundary=... possibly quoted
    let p = semi + 1;
    while p < n {
        let end = p;
        let in_quote = false;
        while end < n {
            if b[end] == 34 {
                in_quote = !in_quote;
            }
            if b[end] == 59 && !in_quote {
                end = end;
                break;
            }
            end = end + 1;
        }
        let param = trim(to_str(b[p..end]));
        let eq = index_of_byte(param, 61);
        if eq > 0 {
            let key = lower(trim(slice_str(param, 0, eq)));
            if key == "boundary" {
                let raw = trim(slice_str(param, eq + 1, len(param)));
                let val = unquote(raw);
                if len(val) == 0 {
                    return err("multipart boundary is empty");
                }
                if len(val) > 70 {
                    return err("multipart boundary is longer than 70 characters");
                }
                if len(raw) >= 2 && starts_with(raw, "\"") && !ends_with(raw, "\"") {
                    return err("multipart boundary is not closed by a quote");
                }
                return ok(val);
            }
        }
        p = end + 1;
    }
    return err("multipart/form-data without a boundary parameter");
}

// ---------------------------------------------------------------- //
// The body                                                           //
// ---------------------------------------------------------------- //

// Splits a complete body into its parts.
//
// The delimiter is CRLF + "--" + boundary; the first one may appear at
// the very start with no leading CRLF (which is what every client
// sends), and the last is followed by "--". Anything before the first
// delimiter or after the closing one is preamble and epilogue, which
// the format says to ignore.
pub fn parse(body: bytes, boundary: str, lim: Limits) -> result[Parsed, str] {
    let dash = to_bytes("--" + boundary);
    let n = len(body);
    let dn = len(dash);
    if n < dn + 2 {
        return err("multipart body is too short to contain its boundary");
    }
    let parts: [Part] = [];
    let total = 0;
    let nfiles = 0;

    // find the first delimiter: at position 0, or after a CRLF
    let pos = first_delimiter(body, dash);
    if pos < 0 {
        return err("multipart body has no opening boundary");
    }
    let closed = false;
    while pos >= 0 {
        let after = pos + dn;
        // closing delimiter: "--boundary--"
        if after + 1 < n && body[after] == 45 && body[after + 1] == 45 {
            closed = true;
            pos = -1;
            continue;
        }
        // the delimiter line ends with CRLF (LF alone is tolerated:
        // some clients, and every hand-written test fixture, send it)
        let start = skip_line_end(body, after);
        if start < 0 {
            return err("multipart boundary is not followed by a line ending");
        }
        let next = next_delimiter(body, dash, start);
        if next < 0 {
            return err("multipart body ends without its closing boundary");
        }
        // the payload ends at the CRLF that precedes the next delimiter
        let payload_end = next;
        if payload_end >= 2 && body[payload_end - 2] == 13 &&
           body[payload_end - 1] == 10 {
            payload_end = payload_end - 2;
        } else if payload_end >= 1 && body[payload_end - 1] == 10 {
            payload_end = payload_end - 1;
        }
        if payload_end < start {
            payload_end = start;
        }

        let pr = parse_part(body, start, payload_end, lim);
        guard let part = pr else let e = err_of(pr) {
            return err(e);
        }
        if len(parts) >= lim.max_parts {
            return err("too many parts: at most " + to_str(lim.max_parts) +
                       " are accepted");
        }
        let size = len(part.data);
        if is_file(part) {
            nfiles = nfiles + 1;
            if nfiles > lim.max_files {
                return err("too many files: at most " +
                           to_str(lim.max_files) + " are accepted");
            }
            if size > lim.max_file_bytes {
                return err("file '" + part.filename + "' is larger than " +
                           to_str(lim.max_file_bytes) + " bytes");
            }
        } else {
            if size > lim.max_field_bytes {
                return err("field '" + part.name + "' is larger than " +
                           to_str(lim.max_field_bytes) + " bytes");
            }
        }
        total = total + size;
        if total > lim.max_total_bytes {
            return err("upload is larger than " +
                       to_str(lim.max_total_bytes) + " bytes in total");
        }
        push(parts, part);
        pos = next;
    }
    if !closed {
        return err("multipart body ends without its closing boundary");
    }
    return ok(Parsed { parts: parts });
}

// A delimiter at the very start, or the first one after a line ending.
fn first_delimiter(body: bytes, dash: bytes) -> int {
    if matches_at(body, dash, 0) {
        return 0;
    }
    return next_delimiter(body, dash, 0);
}

// The next delimiter at or after `from`, which must sit at the start of
// a line: this is what stops a byte sequence inside a file's contents
// from ending the part.
fn next_delimiter(body: bytes, dash: bytes, from: int) -> int {
    let n = len(body);
    let i = from;
    while i < n {
        if body[i] == 10 && matches_at(body, dash, i + 1) {
            return i + 1;
        }
        i = i + 1;
    }
    return -1;
}

fn matches_at(body: bytes, pat: bytes, at: int) -> bool {
    let n = len(body);
    let m = len(pat);
    if at < 0 || at + m > n {
        return false;
    }
    let i = 0;
    while i < m {
        if body[at + i] != pat[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}

// Past the CRLF (or lone LF) that ends a delimiter line, skipping the
// transport padding RFC 2046 allows between the two.
fn skip_line_end(body: bytes, at: int) -> int {
    let n = len(body);
    let i = at;
    while i < n && (body[i] == 32 || body[i] == 9) {
        i = i + 1;
    }
    if i + 1 < n && body[i] == 13 && body[i + 1] == 10 {
        return i + 2;
    }
    if i < n && body[i] == 10 {
        return i + 1;
    }
    return -1;
}

// ---------------------------------------------------------------- //
// One part                                                           //
// ---------------------------------------------------------------- //

fn parse_part(body: bytes, start: int, end: int, lim: Limits) -> result[Part, str] {
    // headers end at the first blank line
    let i = start;
    let hdr_end = -1;
    let body_start = -1;
    while i < end {
        if body[i] == 10 {
            let j = i + 1;
            if j < end && body[j] == 13 && j + 1 < end && body[j + 1] == 10 {
                hdr_end = i;
                body_start = j + 2;
                i = end;
                continue;
            }
            if j < end && body[j] == 10 {
                hdr_end = i;
                body_start = j + 1;
                i = end;
                continue;
            }
        }
        i = i + 1;
    }
    if body_start < 0 {
        return err("a multipart part has no blank line after its headers");
    }
    if hdr_end - start > lim.max_headers_bytes {
        return err("a multipart part's headers are larger than " +
                   to_str(lim.max_headers_bytes) + " bytes");
    }

    let name = "";
    let filename = "";
    let ctype = "";
    let seen_disposition = false;
    let line_start = start;
    let k = start;
    while k <= hdr_end {
        if k == hdr_end || body[k] == 10 {
            let line_end = k;
            if line_end > line_start && body[line_end - 1] == 13 {
                line_end = line_end - 1;
            }
            if line_end > line_start {
                let line = to_str(body[line_start..line_end]);
                let colon = index_of_byte(line, 58);
                if colon <= 0 {
                    return err("a multipart part has a malformed header line");
                }
                let hname = lower(trim(slice_str(line, 0, colon)));
                let hval = trim(slice_str(line, colon + 1, len(line)));
                if hname == "content-disposition" {
                    seen_disposition = true;
                    let dr = disposition(hval);
                    guard let d = dr else let e = err_of(dr) {
                        return err(e);
                    }
                    name = d.name;
                    filename = d.filename;
                } else if hname == "content-type" {
                    ctype = hval;
                } else if hname == "content-transfer-encoding" {
                    let enc = lower(hval);
                    if enc != "7bit" && enc != "8bit" && enc != "binary" {
                        return err("unsupported Content-Transfer-Encoding '" +
                                   hval + "'");
                    }
                }
            }
            line_start = k + 1;
        }
        k = k + 1;
    }
    if !seen_disposition {
        return err("a multipart part has no Content-Disposition header");
    }
    if len(name) == 0 {
        return err("a multipart part has no name");
    }
    if len(filename) > lim.max_filename_bytes {
        return err("a filename is longer than " +
                   to_str(lim.max_filename_bytes) + " bytes");
    }
    let data: bytes = b"";
    if end > body_start {
        data = body[body_start..end];
    }
    return ok(Part {
        name: name,
        filename: filename,
        content_type: ctype,
        data: data
    });
}

gc struct Disposition {
    name: str,
    filename: str,
}

// `form-data; name="file"; filename="a.txt"`, with the quoting the web
// actually uses. RFC 5987's `filename*=UTF-8''...` is decoded when it
// appears, because browsers send it for non-ASCII names and the plain
// `filename` beside it is then mojibake.
fn disposition(v: str) -> result[Disposition, str] {
    let parts = split_params(v);
    if len(parts) == 0 {
        return err("a multipart part has an empty Content-Disposition");
    }
    if lower(trim(parts[0])) != "form-data" {
        return err("a multipart part is not form-data (got '" +
                   trim(parts[0]) + "')");
    }
    let name = "";
    let filename = "";
    let ext_filename = "";
    let i = 1;
    while i < len(parts) {
        let p = trim(parts[i]);
        let eq = index_of_byte(p, 61);
        if eq > 0 {
            let key = lower(trim(slice_str(p, 0, eq)));
            let val = trim(slice_str(p, eq + 1, len(p)));
            if key == "name" {
                name = unquote(val);
            } else if key == "filename" {
                filename = unquote(val);
            } else if key == "filename*" {
                ext_filename = decode_ext_value(unquote(val));
            }
        }
        i = i + 1;
    }
    if len(ext_filename) > 0 {
        filename = ext_filename;
    }
    return ok(Disposition { name: name, filename: filename });
}

// Semicolon-separated parameters, respecting quotes so a filename with
// a semicolon in it stays one parameter.
fn split_params(v: str) -> [str] {
    let out: [str] = [];
    let b = to_bytes(v);
    let n = len(b);
    let start = 0;
    let in_quote = false;
    let i = 0;
    while i <= n {
        if i == n || (b[i] == 59 && !in_quote) {
            push(out, to_str(b[start..i]));
            start = i + 1;
        } else if b[i] == 34 {
            in_quote = !in_quote;
        }
        i = i + 1;
    }
    return out;
}

// RFC 5987: charset'language'percent-encoded-value.
fn decode_ext_value(v: str) -> str {
    let b = to_bytes(v);
    let n = len(b);
    let first = -1;
    let second = -1;
    let i = 0;
    while i < n {
        if b[i] == 39 {
            if first < 0 {
                first = i;
            } else if second < 0 {
                second = i;
            }
        }
        i = i + 1;
    }
    if second < 0 {
        return percent_decode(v);
    }
    return percent_decode(to_str(b[second + 1..n]));
}

// ---------------------------------------------------------------- //
// Small string helpers, kept here so this package depends on nothing //
// ---------------------------------------------------------------- //

// "%20" and "+" decoding. Returns the input unchanged when there is
// nothing to decode, which is the usual case.
//
// The clean stretches between escapes are copied as slices and each
// escape is one byte, through a builder, so this is linear. (It used to
// append one byte at a time with `+`: 128 KB of escapes took two
// seconds.)
pub fn percent_decode(s: str) -> str {
    let b = to_bytes(s);
    let n = len(b);
    let i = 0;
    while i < n {
        if b[i] == 37 || b[i] == 43 {
            break;
        }
        i = i + 1;
    }
    if i == n {
        return s;
    }
    let out = builder.new_bytes();
    let start = 0;
    i = 0;
    while i < n {
        let c = b[i];
        if c == 43 {
            if i > start {
                out.write(b[start..i]);
            }
            out.write_byte(32);
            i = i + 1;
            start = i;
            continue;
        }
        if c == 37 && i + 2 < n {
            let hi = hex_val(b[i + 1]);
            let lo = hex_val(b[i + 2]);
            if hi >= 0 && lo >= 0 {
                if i > start {
                    out.write(b[start..i]);
                }
                out.write_byte(hi * 16 + lo);
                i = i + 3;
                start = i;
                continue;
            }
        }
        i = i + 1;
    }
    if n > start {
        out.write(b[start..n]);
    }
    return to_str(out.finish());
}

fn hex_val(c: int) -> int {
    if c >= 48 && c <= 57 { return c - 48; }
    if c >= 97 && c <= 102 { return c - 87; }
    if c >= 65 && c <= 70 { return c - 55; }
    return -1;
}

pub fn lower(s: str) -> str {
    let b = to_bytes(s);
    let i = 0;
    while i < len(b) {
        if b[i] >= 65 && b[i] <= 90 {
            b[i] = b[i] + 32;
        }
        i = i + 1;
    }
    return to_str(b);
}

pub fn trim(s: str) -> str {
    let b = to_bytes(s);
    let n = len(b);
    let a = 0;
    while a < n && (b[a] == 32 || b[a] == 9 || b[a] == 13 || b[a] == 10) {
        a = a + 1;
    }
    let e = n;
    while e > a && (b[e - 1] == 32 || b[e - 1] == 9 || b[e - 1] == 13 ||
                    b[e - 1] == 10) {
        e = e - 1;
    }
    if a == 0 && e == n {
        return s;
    }
    return to_str(b[a..e]);
}

fn unquote(s: str) -> str {
    let b = to_bytes(s);
    let n = len(b);
    if n >= 2 && b[0] == 34 && b[n - 1] == 34 {
        // a backslash escape inside a quoted string, which RFC 2616
        // allows and some clients emit for a quote in a filename
        let out: bytes = b"";
        let i = 1;
        while i < n - 1 {
            if b[i] == 92 && i + 1 < n - 1 {
                out = out + b[i + 1..i + 2];
                i = i + 2;
                continue;
            }
            out = out + b[i..i + 1];
            i = i + 1;
        }
        return to_str(out);
    }
    return s;
}

fn index_of_byte(s: str, c: int) -> int {
    let b = to_bytes(s);
    let i = 0;
    while i < len(b) {
        if b[i] == c {
            return i;
        }
        i = i + 1;
    }
    return -1;
}

fn slice_str(s: str, from: int, to: int) -> str {
    let b = to_bytes(s);
    if from >= len(b) || from >= to {
        return "";
    }
    let e = to;
    if e > len(b) {
        e = len(b);
    }
    return to_str(b[from..e]);
}

fn starts_with(s: str, p: str) -> bool {
    let a = to_bytes(s);
    let b = to_bytes(p);
    if len(b) > len(a) {
        return false;
    }
    let i = 0;
    while i < len(b) {
        if a[i] != b[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn ends_with(s: str, p: str) -> bool {
    let a = to_bytes(s);
    let b = to_bytes(p);
    if len(b) > len(a) {
        return false;
    }
    let off = len(a) - len(b);
    let i = 0;
    while i < len(b) {
        if a[off + i] != b[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}
