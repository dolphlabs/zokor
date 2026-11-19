// SMTP replies and commands (RFC 5321) as pure functions over bytes: no
// sockets, no clock, no randomness, so every rule here is a unit test.
import "builder";
import "encoding";
import "strings";

// One server reply: its three-digit code and the text of each line,
// without the code and separator.
pub struct Reply { code: int, lines: [str] }

// A complete reply and how many bytes of the buffer it took.
pub struct Parsed { reply: Reply, used: int }

fn is_digit(c: int) -> bool { return c >= 48 && c <= 57; }

// Reads one reply starting at `start`. none: the reply is not complete
// yet, read more. err: the server sent something that is not a reply, or
// a reply longer than `max` bytes; the connection cannot be trusted past
// that, so the caller closes it.
pub fn parse_reply(buf: bytes, start: int, max: int) -> result[opt[Parsed], str] {
    let pos = start;
    let code = -1;
    let lines: [str] = [];
    let n = len(buf);
    while true {
        let nl = -1;
        let i = pos;
        while i < n {
            if buf[i] == 10 {
                nl = i;
                break;
            }
            i += 1;
        }
        if nl < 0 {
            if n - start > max {
                return err("smtp: a reply longer than " + to_str(max) + " bytes");
            }
            return ok(none);
        }
        if nl + 1 - start > max {
            return err("smtp: a reply longer than " + to_str(max) + " bytes");
        }
        let end = nl;
        if end > pos && buf[end - 1] == 13 {
            end -= 1;
        }
        if end - pos < 3 {
            return err("smtp: a reply line without a code");
        }
        let d0 = buf[pos] as int;
        let d1 = buf[pos + 1] as int;
        let d2 = buf[pos + 2] as int;
        if d0 < 50 || d0 > 53 || d1 < 48 || d1 > 53 || !is_digit(d2) {
            return err("smtp: a reply line without a valid code");
        }
        let c = (d0 - 48) * 100 + (d1 - 48) * 10 + (d2 - 48);
        if code >= 0 && c != code {
            return err("smtp: the lines of one reply carry different codes");
        }
        code = c;
        let last = true;
        if end - pos > 3 {
            let sep = buf[pos + 3] as int;
            if sep == 45 {
                last = false;
            } else if sep != 32 {
                return err("smtp: a reply line with no space or dash after its code");
            }
        }
        if end - pos > 4 {
            push(lines, strings.from_bytes(buf, pos + 4, end));
        } else {
            push(lines, "");
        }
        pos = nl + 1;
        if last {
            return ok(some(Parsed { reply: Reply { code: code, lines: lines }, used: pos - start }));
        }
    }
    return err("unreachable");
}

// The reply as one line for an error message: "550 5.1.1 no such user".
pub fn reply_text(r: Reply) -> str {
    let b = builder.new_str();
    b.write(to_str(r.code));
    for i in 0..len(r.lines) {
        let t = strings.trim(r.lines[i]);
        if len(t) > 0 {
            b.write(" ");
            b.write(t);
        }
    }
    let s = b.finish();
    if len(s) > 300 {
        return strings.slice(s, 0, 300) + "...";
    }
    return s;
}

// What an EHLO reply advertises, of what this client uses.
pub struct Ext {
    starttls: bool,
    pipelining: bool,
    // 0 when the server names no limit.
    size: int,
    // Upper-case mechanism names: PLAIN, LOGIN, ...
    auth: [str],
}

pub fn no_ext() -> Ext {
    let auth: [str] = [];
    return Ext { starttls: false, pipelining: false, size: 0, auth: auth };
}

// Keywords are case-insensitive (RFC 5321 4.1.1.1). The first line is
// the server's greeting, not a keyword. "AUTH=" is the pre-standard
// spelling some servers still send next to (or instead of) "AUTH ".
pub fn extensions(r: Reply) -> Ext {
    let e = no_ext();
    for i in 1..len(r.lines) {
        let words = strings.split(strings.trim(r.lines[i]), " ");
        if len(words) == 0 {
            continue;
        }
        let kw = strings.to_upper(words[0]);
        if kw == "STARTTLS" {
            e.starttls = true;
        } else if kw == "PIPELINING" {
            e.pipelining = true;
        } else if kw == "SIZE" {
            if len(words) > 1 {
                e.size = to_int(words[1]) ?? 0;
                if e.size < 0 {
                    e.size = 0;
                }
            }
        } else if kw == "AUTH" || strings.has_prefix(kw, "AUTH=") {
            if kw != "AUTH" && !has_word(e.auth, strings.slice(kw, 5, len(kw))) {
                push(e.auth, strings.slice(kw, 5, len(kw)));
            }
            for j in 1..len(words) {
                let m = strings.to_upper(words[j]);
                if len(m) > 0 && !has_word(e.auth, m) {
                    push(e.auth, m);
                }
            }
        }
    }
    return e;
}

fn has_word(xs: [str], w: str) -> bool {
    for x in xs {
        if x == w {
            return true;
        }
    }
    return false;
}

// The mechanism to log in with: PLAIN, else LOGIN, else "" (none this
// client speaks). Both send the password as is, which is why the caller
// only ever authenticates inside TLS.
pub fn pick_auth(e: Ext) -> str {
    if has_word(e.auth, "PLAIN") {
        return "PLAIN";
    }
    if has_word(e.auth, "LOGIN") {
        return "LOGIN";
    }
    return "";
}

// RFC 4616: authorization identity empty, then user and password.
pub fn auth_plain(user: str, pass: str) -> bytes {
    let b = builder.new_bytes();
    b.write_byte(0);
    b.write_str(user);
    b.write_byte(0);
    b.write_str(pass);
    return to_bytes("AUTH PLAIN " + encoding.base64_encode(b.finish()) + "\r\n");
}

pub fn base64_line(s: str) -> bytes {
    return to_bytes(encoding.base64_encode(to_bytes(s)) + "\r\n");
}

pub fn cmd_ehlo(domain: str) -> bytes { return to_bytes("EHLO " + domain + "\r\n"); }
pub fn cmd_helo(domain: str) -> bytes { return to_bytes("HELO " + domain + "\r\n"); }

// SIZE is declared only when the server advertised it (size_ok), so a
// server too small for the message refuses at MAIL, before the upload.
pub fn cmd_mail(addr: str, size: int, size_ok: bool) -> bytes {
    if size_ok && size > 0 {
        return to_bytes("MAIL FROM:<" + addr + "> SIZE=" + to_str(size) + "\r\n");
    }
    return to_bytes("MAIL FROM:<" + addr + ">\r\n");
}

pub fn cmd_rcpt(addr: str) -> bytes { return to_bytes("RCPT TO:<" + addr + ">\r\n"); }

// The message as DATA sends it: every line that starts with "." gets a
// second one (RFC 5321 4.5.2), every line break is CRLF, and the end is
// CRLF "." CRLF. A bare CR or LF in the input becomes CRLF rather than
// reaching a server that might read it as the end of the message.
pub fn data_payload(msg: bytes) -> bytes {
    let b = builder.new_bytes();
    let n = len(msg);
    let line_start = true;
    let i = 0;
    while i < n {
        let c = msg[i] as int;
        if line_start && c == 46 {
            b.write_byte(46);
        }
        line_start = false;
        if c == 13 {
            b.write_str("\r\n");
            if i + 1 < n && msg[i + 1] == 10 {
                i += 1;
            }
            line_start = true;
        } else if c == 10 {
            b.write_str("\r\n");
            line_start = true;
        } else {
            b.write_byte(c);
        }
        i += 1;
    }
    if !line_start {
        b.write_str("\r\n");
    }
    b.write_str(".\r\n");
    return b.finish();
}
