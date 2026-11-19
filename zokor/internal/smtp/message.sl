// The message a mail server stores (RFC 5322 with MIME, RFC 2045-2047
// and 2231), built from checked parts. The date, Message-ID and MIME
// boundary come from the caller, so a build is deterministic.
//
// Everything leaves here 7-bit: headers that are not ASCII become
// encoded words, text bodies quoted-printable, attachments base64. A
// server that lacks 8BITMIME or SMTPUTF8 still takes the message as is.

import "builder";
import "encoding";
import "strings";

// An address as a header shows it. `addr` is the bare addr-spec the
// envelope (MAIL FROM, RCPT TO) uses.
pub struct Address { name: str, addr: str }

pub struct Attachment { filename: str, content_type: str, data: bytes }

pub struct Header { name: str, value: str }

pub struct Head {
    from: Address,
    to: [Address],
    cc: [Address],
    reply_to: [Address],
    subject: str,
    // RFC 5322 date-time, e.g. "Tue, 13 Oct 2026 09:30:15 +0000".
    date: str,
    // With its angle brackets.
    message_id: str,
    extra: [Header],
}

// The longest header value (and subject) a caller may pass. A line may
// not pass 998 characters (RFC 5322 2.1.1); this leaves room for the name.
pub fn max_header_value() -> int { return 900; }

// Headers this package writes itself; a caller's extra headers may not
// repeat or override them.
pub fn reserved_header(name: str) -> bool {
    let n = strings.to_lower(name);
    return n == "from" || n == "to" || n == "cc" || n == "bcc" || n == "reply-to" ||
        n == "subject" || n == "date" || n == "message-id" || n == "mime-version" ||
        n == "sender" || n == "return-path" || strings.has_prefix(n, "content-");
}

fn atext(c: int) -> bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) ||
        c == 33 || c == 35 || c == 36 || c == 37 || c == 38 || c == 39 || c == 42 ||
        c == 43 || c == 45 || c == 47 || c == 61 || c == 63 || c == 94 || c == 95 ||
        c == 96 || c == 123 || c == 124 || c == 125 || c == 126;
}

fn has_control(s: str) -> bool {
    for c in to_bytes(s) {
        let v = c as int;
        if v < 32 || v == 127 {
            return true;
        }
    }
    return false;
}

fn is_ascii(s: str) -> bool {
    for c in to_bytes(s) {
        if (c as int) >= 128 {
            return false;
        }
    }
    return true;
}

// A header value a caller supplied: no line break (which would start a
// header of the caller's choosing), no other control character, and
// short enough for one line.
pub fn check_value(v: str) -> result[bool, str] {
    if has_control(v) {
        return err("contains a line break or another control character");
    }
    if len(v) > max_header_value() {
        return err("is longer than " + to_str(max_header_value()) + " bytes");
    }
    return ok(true);
}

// A header name: RFC 5322 ftext (printable ASCII but ':'), and not one
// this package writes.
pub fn check_header_name(name: str) -> result[bool, str] {
    let b = to_bytes(name);
    if len(b) == 0 || len(b) > 76 {
        return err("must be 1 to 76 characters");
    }
    for c in b {
        let v = c as int;
        if v < 33 || v > 126 || v == 58 {
            return err("may hold only printable ASCII without ':'");
        }
    }
    if reserved_header(name) {
        return err("is written by zokor and cannot be set");
    }
    return ok(true);
}

// The bare address: dot-atom local part (RFC 5322 3.4.1), and a domain
// of LDH labels or an address literal. Quoted local parts and non-ASCII
// addresses (SMTPUTF8) are refused rather than half supported.
pub fn check_addr_spec(a: str) -> result[bool, str] {
    let b = to_bytes(a);
    let n = len(b);
    if n == 0 {
        return err("is empty");
    }
    if n > 254 {
        return err("is longer than 254 bytes");
    }
    if !is_ascii(a) {
        return err("is not ASCII; write the domain in its xn-- form (non-ASCII local parts need SMTPUTF8, which is not supported)");
    }
    let at = strings.rfind(a, "@");
    if at <= 0 || at == n - 1 {
        return err("must look like name@example.com");
    }
    if at > 64 {
        return err("has a local part longer than 64 bytes");
    }
    let prev = 46;
    for i in 0..at {
        let c = b[i] as int;
        if c == 46 {
            if prev == 46 {
                return err("has an empty part between dots before the @");
            }
        } else if !atext(c) {
            return err("has a character a mail address cannot hold unquoted: '" + strings.slice(a, i, i + 1) + "'");
        }
        prev = c;
    }
    if prev == 46 {
        return err("has a dot just before the @");
    }
    return check_domain(strings.slice(a, at + 1, n));
}

pub fn check_domain(d: str) -> result[bool, str] {
    let b = to_bytes(d);
    let n = len(b);
    if n == 0 || n > 253 {
        return err("has a domain that is empty or longer than 253 bytes");
    }
    if b[0] == 91 {
        if b[n - 1] != 93 || n < 3 {
            return err("has an address literal without its closing ]");
        }
        for i in 1..n - 1 {
            let c = b[i] as int;
            let ok_c = (c >= 48 && c <= 58) || c == 46 || (c >= 65 && c <= 70) ||
                (c >= 97 && c <= 102) || c == 73 || c == 80 || c == 118 || c == 54;
            if !ok_c {
                return err("has an address literal that is not an IP address");
            }
        }
        return ok(true);
    }
    let label = 0;
    for i in 0..n {
        let c = b[i] as int;
        if c == 46 {
            if label == 0 || b[i - 1] == 45 {
                return err("has a domain with an empty label or one ending in '-'");
            }
            label = 0;
            continue;
        }
        let ldh = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 45;
        if !ldh {
            return err("has a domain with a character other than letters, digits, '-' and '.'");
        }
        if label == 0 && c == 45 {
            return err("has a domain label starting with '-'");
        }
        label += 1;
        if label > 63 {
            return err("has a domain label longer than 63 bytes");
        }
    }
    if label == 0 || b[n - 1] == 45 {
        return err("has a domain ending in '.' or '-'");
    }
    return ok(true);
}

// "ada@example.com" or "Ada Lovelace <ada@example.com>" (the name may be
// quoted). err says what is wrong; the caller adds which field.
pub fn parse_address(s: str) -> result[Address, str] {
    if has_control(s) {
        return err("contains a line break or another control character");
    }
    let t = strings.trim(s);
    let lt = strings.find(t, "<");
    if lt < 0 {
        if strings.contains(t, ">") {
            return err("has a '>' without a '<'");
        }
        let r = check_addr_spec(t);
        guard let _ok = r else let e = err_of(r) { return err(e); }
        return ok(Address { name: "", addr: t });
    }
    if !strings.has_suffix(t, ">") || strings.count(t, "<") != 1 || strings.count(t, ">") != 1 {
        return err("must be name@example.com or Name <name@example.com>");
    }
    let addr = strings.slice(t, lt + 1, len(t) - 1);
    let r = check_addr_spec(addr);
    guard let _ok = r else let e = err_of(r) { return err(e); }
    let name = strings.trim(strings.slice(t, 0, lt));
    if len(name) >= 2 && strings.has_prefix(name, "\"") && strings.has_suffix(name, "\"") {
        name = strings.slice(name, 1, len(name) - 1);
    }
    if strings.contains(name, "\"") || strings.contains(name, "\\") {
        return err("has a display name with a quote or backslash inside it");
    }
    if len(name) > 200 {
        return err("has a display name longer than 200 bytes");
    }
    return ok(Address { name: name, addr: addr });
}

// ---- header encoding ------------------------------------------------------------

// Bytes of input per encoded word: 39 encode to 52 base64 characters,
// so "=?UTF-8?B?...?=" is 64 and a folded line stays near 78.
fn word_bytes() -> int { return 39; }

// RFC 2047 encoded words, split only between UTF-8 characters (6.3: a
// character may not be split across words), joined by folding white
// space, which a reader drops between two encoded words.
pub fn encode_words(s: str) -> str {
    let b = to_bytes(s);
    let n = len(b);
    let out = builder.new_str();
    let start = 0;
    while start < n {
        let end = start + word_bytes();
        if end >= n {
            end = n;
        } else {
            while end > start && ((b[end] as int) & 192) == 128 {
                end -= 1;
            }
            if end == start {
                end = start + word_bytes();
            }
        }
        if start > 0 {
            out.write("\r\n ");
        }
        let chunk = builder.new_bytes();
        for i in start..end {
            chunk.write_byte(b[i] as int);
        }
        out.write("=?UTF-8?B?");
        out.write(encoding.base64_encode(chunk.finish()));
        out.write("?=");
        start = end;
    }
    return out.finish();
}

// An unstructured value (a subject): ASCII as is, folded at spaces to
// keep lines near 78 characters; anything else as encoded words.
pub fn header_text(name_len: int, v: str) -> str {
    if !is_ascii(v) {
        return encode_words(v);
    }
    if name_len + 2 + len(v) <= 78 {
        return v;
    }
    let words = strings.split(v, " ");
    let out = builder.new_str();
    let col = name_len + 2;
    for i in 0..len(words) {
        let w = words[i];
        if i > 0 {
            if col + 1 + len(w) > 78 && col > 1 {
                out.write("\r\n ");
                col = 1;
            } else {
                out.write(" ");
                col += 1;
            }
        }
        out.write(w);
        col += len(w);
    }
    return out.finish();
}

fn phrase(name: str) -> str {
    if !is_ascii(name) {
        return encode_words(name);
    }
    for c in to_bytes(name) {
        let v = c as int;
        if v != 32 && !atext(v) {
            return "\"" + name + "\"";
        }
    }
    return name;
}

pub fn format_address(a: Address) -> str {
    if len(a.name) == 0 {
        return a.addr;
    }
    return phrase(a.name) + " <" + a.addr + ">";
}

// An address list, folded between addresses.
pub fn address_list(name_len: int, xs: [Address]) -> str {
    let out = builder.new_str();
    let col = name_len + 2;
    for i in 0..len(xs) {
        let f = format_address(xs[i]);
        if i > 0 {
            out.write(",");
            col += 1;
            if col + 1 + len(f) > 78 {
                out.write("\r\n ");
                col = 1;
            } else {
                out.write(" ");
                col += 1;
            }
        }
        out.write(f);
        col += len(f);
    }
    return out.finish();
}

// ---- bodies ---------------------------------------------------------------------

fn hex_digit(v: int) -> int {
    if v < 10 {
        return 48 + v;
    }
    return 55 + v;
}

// RFC 2045 6.7 quoted-printable. Line breaks in the text (CRLF, LF or a
// lone CR) become CRLF; lines are cut with soft breaks at 76; '=',
// controls, bytes past ASCII and white space at the end of a line are
// escaped. A line that starts with "." is left to DATA's dot-stuffing.
pub fn quoted_printable(text: str) -> str {
    let b = to_bytes(text);
    let n = len(b);
    let out = builder.new_bytes();
    let col = 0;
    let i = 0;
    while i < n {
        let c = b[i] as int;
        if c == 13 || c == 10 {
            out.write_str("\r\n");
            col = 0;
            if c == 13 && i + 1 < n && b[i + 1] == 10 {
                i += 1;
            }
            i += 1;
            continue;
        }
        let at_eol = i + 1 == n || b[i + 1] == 13 || b[i + 1] == 10;
        let literal = (c >= 33 && c <= 126 && c != 61) || ((c == 32 || c == 9) && !at_eol);
        let w = 3;
        if literal {
            w = 1;
        }
        if col + w > 75 {
            out.write_str("=\r\n");
            col = 0;
        }
        if literal {
            out.write_byte(c);
        } else {
            out.write_byte(61);
            out.write_byte(hex_digit(c / 16));
            out.write_byte(hex_digit(c % 16));
        }
        col += w;
        i += 1;
    }
    return to_str(out.finish());
}

pub fn base64_lines(data: bytes) -> str {
    let s = encoding.base64_encode(data);
    let n = len(s);
    if n <= 76 {
        return s;
    }
    let out = builder.new_str();
    let i = 0;
    while i < n {
        if i > 0 {
            out.write("\r\n");
        }
        let end = i + 76;
        if end > n {
            end = n;
        }
        out.write(strings.slice(s, i, end));
        i = end;
    }
    return out.finish();
}

// A file name for Content-Disposition: one path segment, no control
// characters or quotes. Refused rather than cleaned: the caller chose it.
pub fn check_filename(f: str) -> result[bool, str] {
    if len(f) == 0 || len(f) > 255 {
        return err("must be 1 to 255 bytes");
    }
    if has_control(f) || strings.contains(f, "\"") || strings.contains(f, "/") ||
        strings.contains(f, "\\") || f == "." || f == ".." {
        return err("must be one file name, without '/', '\\', quotes or control characters");
    }
    return ok(true);
}

fn token_byte(c: int) -> bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) ||
        c == 33 || c == 35 || c == 36 || c == 37 || c == 38 || c == 39 || c == 42 ||
        c == 43 || c == 45 || c == 46 || c == 94 || c == 95 || c == 96 || c == 124 || c == 126;
}

// "type/subtype", both RFC 2045 tokens. Parameters are refused: the
// part's parameters are this package's to write.
pub fn check_content_type(ct: str) -> result[bool, str] {
    let slash = strings.find(ct, "/");
    if slash <= 0 || slash == len(ct) - 1 || len(ct) > 127 {
        return err("must be type/subtype, like application/pdf");
    }
    let b = to_bytes(ct);
    for i in 0..len(b) {
        if i != slash && !token_byte(b[i] as int) {
            return err("must be type/subtype with no parameters, like application/pdf");
        }
    }
    return ok(true);
}

// RFC 2231 extended parameter: UTF-8, percent-encoded.
fn ext_value(s: str) -> str {
    let out = builder.new_bytes();
    for c in to_bytes(s) {
        let v = c as int;
        if v < 128 && token_byte(v) && v != 37 && v != 39 && v != 42 {
            out.write_byte(v);
        } else {
            out.write_byte(37);
            out.write_byte(hex_digit(v / 16));
            out.write_byte(hex_digit(v % 16));
        }
    }
    return to_str(out.finish());
}

fn text_part(subtype: str, body: str) -> str {
    return "Content-Type: text/" + subtype + "; charset=utf-8\r\n" +
        "Content-Transfer-Encoding: quoted-printable\r\n\r\n" + quoted_printable(body);
}

fn attachment_part(a: Attachment) -> str {
    let disp = "attachment; filename=\"" + a.filename + "\"";
    let name = "; name=\"" + a.filename + "\"";
    if !is_ascii(a.filename) {
        disp = "attachment;\r\n filename*=UTF-8''" + ext_value(a.filename);
        name = ";\r\n name=\"" + encode_words(a.filename) + "\"";
    }
    return "Content-Type: " + strings.to_lower(a.content_type) + name + "\r\n" +
        "Content-Disposition: " + disp + "\r\n" +
        "Content-Transfer-Encoding: base64\r\n\r\n" + base64_lines(a.data);
}

fn multipart(subtype: str, boundary: str, parts: [str]) -> str {
    let out = builder.new_str();
    out.write("Content-Type: multipart/" + subtype + ";\r\n boundary=\"" + boundary + "\"\r\n\r\n");
    for p in parts {
        out.write("--" + boundary + "\r\n");
        out.write(p);
        out.write("\r\n");
    }
    out.write("--" + boundary + "--");
    return out.finish();
}

// The whole message. `boundary` must hold "=_": that pair never occurs
// in quoted-printable or base64 output, so no body can contain a
// delimiter (RFC 2045 6.7, RFC 2046 5.1.1). The caller makes it unique
// per message. At least one of text and html must be set; the caller
// checked every part.
pub fn build(h: Head, text: str, html: str, atts: [Attachment], boundary: str) -> bytes {
    let out = builder.new_str();
    out.write("Date: " + h.date + "\r\n");
    out.write("From: " + address_list(4, [h.from]) + "\r\n");
    if len(h.to) > 0 {
        out.write("To: " + address_list(2, h.to) + "\r\n");
    }
    if len(h.cc) > 0 {
        out.write("Cc: " + address_list(2, h.cc) + "\r\n");
    }
    if len(h.reply_to) > 0 {
        out.write("Reply-To: " + address_list(8, h.reply_to) + "\r\n");
    }
    out.write("Message-ID: " + h.message_id + "\r\n");
    out.write("Subject: " + header_text(7, h.subject) + "\r\n");
    for x in h.extra {
        out.write(x.name + ": " + header_text(len(x.name), x.value) + "\r\n");
    }
    out.write("MIME-Version: 1.0\r\n");
    let body = "";
    if len(text) > 0 && len(html) > 0 {
        body = multipart("alternative", boundary + "a", [text_part("plain", text), text_part("html", html)]);
    } else if len(html) > 0 {
        body = text_part("html", html);
    } else {
        body = text_part("plain", text);
    }
    if len(atts) > 0 {
        let parts = [body];
        for a in atts {
            push(parts, attachment_part(a));
        }
        body = multipart("mixed", boundary + "m", parts);
    }
    out.write(body);
    out.write("\r\n");
    return to_bytes(out.finish());
}
