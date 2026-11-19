// Sending mail over SMTP, to any server that speaks it: SES, Mailgun,
// Postmark, Postfix, Gmail, or Mailpit on a laptop.
//
// The protocol and the message format are internal/smtp, pure functions
// with their own tests; this file is the I/O around them: one
// connection per message, every step under one deadline, TLS always
// verified, and credentials sent only inside TLS. Everything a mail can
// get wrong is checked before a connection opens, and every problem is
// reported at once, each naming its field.
//
// Off by default, like every dependency: no SMTP_URL, no mailer.
//
//   SMTP_URL      smtps://user:pass@host:465  TLS from the first byte
//                 smtp://user:pass@host:587   STARTTLS, required: a server
//                                             that does not offer it is
//                                             refused, never used in clear
//                 smtp+plain://localhost:1025 no TLS, loopback hosts only
//                 and never with credentials (Mailpit, MailHog)
//   SMTP_FROM     the From of a mail that names none
//   SMTP_HELO     the name this host gives in EHLO (default: its hostname)
//   SMTP_TIMEOUT  one deadline for a whole send (default 30s)
//   SMTP_CA_FILE  roots to verify the server with (default: the system's)

import "builder";
import "crypto";
import "encoding";
import "internal/smtp";
import "net";
import "os";
import "strings";
import "time";
import "timez";

pub enum MailSecurity { Tls, StartTls, Plain }

pub gc struct Mailer {
    host: str,
    port: int,
    security: MailSecurity,
    user: str,
    pass: str,
    // The From of a mail that names none; "" when SMTP_FROM is unset.
    from: str,
    helo: str,
    // Nanoseconds for one whole send: connect, TLS, login and upload.
    timeout: int,
    // The longest server reply read before the connection is dropped.
    max_reply: int,
    tls_ctx: rawptr,
}

pub struct MailAttachment { filename: str, content_type: str, data: bytes }

pub struct MailHeader { name: str, value: str }

// One message. Addresses are "ada@example.com" or "Ada <ada@example.com>".
// bcc recipients get the mail but appear in no header.
pub gc struct Mail {
    from: str,
    to: [str],
    cc: [str],
    bcc: [str],
    reply_to: [str],
    subject: str,
    // Plain text, HTML, or both (sent as alternatives). At least one.
    text: str,
    html: str,
    attachments: [MailAttachment],
    // Extra headers, such as List-Unsubscribe. The ones zokor writes
    // (From, To, Subject, Date, Content-*, ...) are refused here.
    headers: [MailHeader],
}

pub struct MailSent {
    // With its angle brackets, as the Message-ID header carries it.
    message_id: str,
    // Envelope recipients the server accepted (duplicates sent once).
    recipients: int,
    // The server's answer to the message, often naming its queue id.
    reply: str,
}

pub gc struct MailError {
    // The SMTP reply code, or 0 when the failure was not a server reply.
    code: int,
    // true: sending the same mail again fails the same way, so a job
    // should stop retrying. A 4xx reply, a timeout or a dropped
    // connection is false.
    permanent: bool,
    detail: str,
    // For a mail that failed its checks: every field at fault
    // ("to[1]", "attachments[0].filename", ...) with what is wrong.
    problems: [Problem],
}

// The most envelope recipients one mail may have: the number every
// server must accept (RFC 5321 4.5.3.1.8). Larger lists go in batches.
pub fn max_recipients() -> int { return 100; }

pub fn new_mail(to: str, subject: str, text: str) -> Mail {
    let none_: [str] = [];
    let atts: [MailAttachment] = [];
    let hs: [MailHeader] = [];
    return Mail {
        from: "", to: [to], cc: none_, bcc: [], reply_to: [], subject: subject,
        text: text, html: "", attachments: atts, headers: hs
    };
}

impl Mail {
    pub fn attach(self: Mail, filename: str, content_type: str, data: bytes) -> Mail {
        push(self.attachments, MailAttachment { filename: filename, content_type: content_type, data: data });
        return self;
    }

    pub fn header(self: Mail, name: str, value: str) -> Mail {
        push(self.headers, MailHeader { name: name, value: value });
        return self;
    }
}

// ---- configuration --------------------------------------------------------------

fn has_nul(s: str) -> bool {
    for c in to_bytes(s) {
        if c == 0 {
            return true;
        }
    }
    return false;
}

fn is_loopback(host: str) -> bool {
    return host == "localhost" || host == "::1" || strings.has_prefix(host, "127.");
}

// A mailer from an SMTP_URL-style string (see the top of this file).
// The TLS context is made here, once, and shared by every send. err
// never repeats the password.
pub fn new_mailer(url: str, ca_file: str) -> result[Mailer, str] {
    let security = MailSecurity.StartTls;
    let port = 587;
    let rest = "";
    if strings.has_prefix(url, "smtps://") {
        security = MailSecurity.Tls;
        port = 465;
        rest = strings.slice(url, 8, len(url));
    } else if strings.has_prefix(url, "smtp://") {
        rest = strings.slice(url, 7, len(url));
    } else if strings.has_prefix(url, "smtp+plain://") {
        security = MailSecurity.Plain;
        port = 25;
        rest = strings.slice(url, 13, len(url));
    } else {
        return err("must start with smtps://, smtp:// or smtp+plain://");
    }
    if strings.has_suffix(rest, "/") {
        rest = strings.slice(rest, 0, len(rest) - 1);
    }
    if strings.contains(rest, "/") || strings.contains(rest, "?") || strings.contains(rest, "#") {
        return err("must be scheme://[user:pass@]host[:port] with no path or query");
    }
    let user = "";
    let pass = "";
    let at = strings.rfind(rest, "@");
    if at >= 0 {
        let info = strings.slice(rest, 0, at);
        rest = strings.slice(rest, at + 1, len(rest));
        let colon = strings.find(info, ":");
        let raw_user = info;
        let raw_pass = "";
        if colon >= 0 {
            raw_user = strings.slice(info, 0, colon);
            raw_pass = strings.slice(info, colon + 1, len(info));
        }
        let ur = encoding.url_decode(raw_user);
        guard let u = ur else { return err("has a user name that is not valid percent-encoding"); }
        let pr = encoding.url_decode(raw_pass);
        guard let p = pr else { return err("has a password that is not valid percent-encoding"); }
        if len(u) == 0 {
            return err("has credentials with an empty user name");
        }
        if has_nul(u) || has_nul(p) {
            return err("has credentials holding a NUL byte");
        }
        user = u;
        pass = p;
    }
    let host = rest;
    if strings.has_prefix(rest, "[") {
        let close = strings.find(rest, "]");
        if close < 0 {
            return err("has an IPv6 host without its closing ]");
        }
        host = strings.slice(rest, 1, close);
        let after = strings.slice(rest, close + 1, len(rest));
        if len(after) > 0 {
            if !strings.has_prefix(after, ":") {
                return err("has text after the IPv6 host");
            }
            let pr = to_int(strings.slice(after, 1, len(after)));
            guard let p = pr else { return err("has a port that is not a number"); }
            port = p;
        }
    } else {
        let colon = strings.rfind(rest, ":");
        if colon >= 0 {
            host = strings.slice(rest, 0, colon);
            let pr = to_int(strings.slice(rest, colon + 1, len(rest)));
            guard let p = pr else { return err("has a port that is not a number"); }
            port = p;
        }
        let hr = smtp.check_domain(host);
        guard let _h = hr else { return err("has a host that is not a valid name or address"); }
    }
    if len(host) == 0 {
        return err("has no host");
    }
    if port < 1 || port > 65535 {
        return err("has a port outside 1-65535");
    }
    let ctx: rawptr = nullptr;
    if security == MailSecurity.Plain {
        if !is_loopback(host) {
            return err("smtp+plain:// is for a server on this machine only; use smtps:// or smtp:// (STARTTLS)");
        }
        if len(user) > 0 {
            return err("smtp+plain:// never sends credentials; use smtps:// or smtp://");
        }
    } else {
        let cr = net.tls_client_ctx(ca_file);
        guard let c = cr else let e = err_of(cr) { return err("TLS: " + e); }
        ctx = c;
    }
    return ok(Mailer {
        host: host, port: port, security: security, user: user, pass: pass, from: "",
        helo: default_helo(), timeout: 30000000000, max_reply: 65536, tls_ctx: ctx
    });
}

// This host's name if it is a valid domain, else "localhost". Some
// servers score a bad EHLO name as spam; SMTP_HELO overrides it.
fn default_helo() -> str {
    let hr = os.hostname();
    guard let h = hr else { return "localhost"; }
    let cr = smtp.check_domain(h);
    guard let _ok = cr else { return "localhost"; }
    return h;
}

// The mailer SMTP_URL and its companions describe; err when SMTP_URL is
// unset or wrong. Problems with the companions are reported together.
pub fn mailer_from_config(cfg: Config) -> result[Mailer, str] {
    let url = optional_dsn(cfg, "SMTP_URL", "");
    if len(url) == 0 {
        return err("SMTP_URL is not set");
    }
    let mr = new_mailer(url, str_or(cfg, "SMTP_CA_FILE", ""));
    guard let m = mr else let e = err_of(mr) { return err("SMTP_URL " + e); }
    let problems: [str] = [];
    let from = str_or(cfg, "SMTP_FROM", "");
    if len(from) > 0 {
        let ar = smtp.parse_address(from);
        if let _a = ar {
            m.from = from;
        } else let e = err_of(ar) {
            push(problems, "SMTP_FROM " + e);
        }
    }
    let helo = str_or(cfg, "SMTP_HELO", "");
    if len(helo) > 0 {
        if smtp.check_domain(helo) ?? false {
            m.helo = helo;
        } else {
            push(problems, "SMTP_HELO must be a domain name");
        }
    }
    m.timeout = duration_or(cfg, "SMTP_TIMEOUT", 30000000000);
    if m.timeout <= 0 {
        push(problems, "SMTP_TIMEOUT must be positive");
    }
    if len(problems) > 0 {
        return err(strings.join(problems, "; "));
    }
    return ok(m);
}

pub fn has_mailer(cfg: Config) -> bool {
    return len(optional_dsn(cfg, "SMTP_URL", "")) > 0;
}

// ---- checking and building ------------------------------------------------------

gc struct Prepared {
    from: str,
    rcpts: [str],
    // The field each envelope recipient came from, for errors.
    fields: [str],
    data: bytes,
    message_id: str,
}

fn problem(ps: [Problem], key: str, reason: str) {
    push(ps, Problem { key: key, reason: reason, shown: "" });
}

fn note(ps: [Problem], key: str, r: result[bool, str]) {
    if let _ok = r {
        return;
    } else let e = err_of(r) {
        problem(ps, key, e);
    }
}

fn invalid(ps: [Problem]) -> MailError {
    let b = builder.new_str();
    b.write("mail is invalid: ");
    for i in 0..len(ps) {
        if i > 0 {
            b.write("; ");
        }
        b.write(ps[i].key + " " + ps[i].reason);
    }
    return MailError { code: 0, permanent: true, detail: b.finish(), problems: ps };
}

fn mail_fail(code: int, permanent: bool, detail: str) -> MailError {
    let ps: [Problem] = [];
    return MailError { code: code, permanent: permanent, detail: detail, problems: ps };
}

fn addresses(ps: [Problem], field: str, xs: [str]) -> [smtp.Address] {
    let out: [smtp.Address] = [];
    for i in 0..len(xs) {
        let r = smtp.parse_address(xs[i]);
        if let a = r {
            push(out, a);
        } else let e = err_of(r) {
            problem(ps, field + "[" + to_str(i) + "]", e);
        }
    }
    return out;
}

fn hex(b: bytes) -> str { return encoding.hex_encode(b); }

// Every check, then the message itself. `random` is 24 bytes: 16 for the
// Message-ID, 8 for the MIME boundary.
fn prepare(m: Mailer, mail: Mail, now: timez.Time, random: bytes) -> result[Prepared, MailError] {
    let ps: [Problem] = [];
    let from_s = mail.from;
    if len(from_s) == 0 {
        from_s = m.from;
    }
    let from = smtp.Address { name: "", addr: "" };
    if len(from_s) == 0 {
        problem(ps, "from", "is not set: set it on the mail or set SMTP_FROM");
    } else {
        let fr = smtp.parse_address(from_s);
        if let a = fr {
            from = a;
        } else let e = err_of(fr) {
            problem(ps, "from", e);
        }
    }
    let to = addresses(ps, "to", mail.to);
    let cc = addresses(ps, "cc", mail.cc);
    let bcc = addresses(ps, "bcc", mail.bcc);
    let reply_to = addresses(ps, "reply_to", mail.reply_to);
    let total = len(mail.to) + len(mail.cc) + len(mail.bcc);
    if total == 0 {
        problem(ps, "to", "needs at least one recipient in to, cc or bcc");
    } else if total > max_recipients() {
        problem(ps, "to", "has " + to_str(total) + " recipients with cc and bcc; the most is " +
            to_str(max_recipients()) + ", send the rest in another mail");
    }
    note(ps, "subject", smtp.check_value(mail.subject));
    if len(mail.text) == 0 && len(mail.html) == 0 {
        problem(ps, "text", "is empty and so is html; a mail needs a body");
    }
    let atts: [smtp.Attachment] = [];
    for i in 0..len(mail.attachments) {
        let a = mail.attachments[i];
        let key = "attachments[" + to_str(i) + "]";
        note(ps, key + ".filename", smtp.check_filename(a.filename));
        note(ps, key + ".content_type", smtp.check_content_type(a.content_type));
        push(atts, smtp.Attachment { filename: a.filename, content_type: a.content_type, data: a.data });
    }
    let extra: [smtp.Header] = [];
    for i in 0..len(mail.headers) {
        let h = mail.headers[i];
        let key = "headers[" + to_str(i) + "]";
        note(ps, key + ".name", smtp.check_header_name(h.name));
        note(ps, key + ".value", smtp.check_value(h.value));
        push(extra, smtp.Header { name: h.name, value: h.value });
    }
    if len(ps) > 0 {
        return err(invalid(ps));
    }
    // One RCPT per address: a server delivers a repeated one twice.
    let rcpts: [str] = [];
    let fields: [str] = [];
    let seen: map[str]bool = {};
    let lists = [to, cc, bcc];
    let names = ["to", "cc", "bcc"];
    for li in 0..3 {
        let xs = lists[li];
        for i in 0..len(xs) {
            let k = strings.to_lower(xs[i].addr);
            if has(seen, k) {
                continue;
            }
            seen[k] = true;
            push(rcpts, xs[i].addr);
            push(fields, names[li] + "[" + to_str(i) + "]");
        }
    }
    let domain = strings.slice(from.addr, strings.rfind(from.addr, "@") + 1, len(from.addr));
    let message_id = "<" + hex(random[0..16]) + "@" + domain + ">";
    let date = strings.replace(now.http_date(), " GMT", " +0000");
    let head = smtp.Head {
        from: from, to: to, cc: cc, reply_to: reply_to, subject: mail.subject,
        date: date, message_id: message_id, extra: extra
    };
    let msg = smtp.build(head, mail.text, mail.html, atts, "=_" + hex(random[16..24]));
    return ok(Prepared { from: from.addr, rcpts: rcpts, fields: fields, data: msg, message_id: message_id });
}

// ---- the session ----------------------------------------------------------------

gc struct Wire {
    fd: i32,
    ssl: rawptr,
    buf: bytes,
    pos: int,
    deadline: until,
    max_reply: int,
}

fn wire_close(w: Wire) {
    if w.ssl != nullptr {
        // Closes the socket too.
        net.tls_close(w.ssl);
        w.ssl = nullptr;
        w.fd = -1;
    }
    if w.fd >= 0 {
        net.close(w.fd);
        w.fd = -1;
    }
}

fn wire_send(w: Wire, data: bytes) -> result[bool, MailError] {
    let off = 0;
    while off < len(data) {
        let chunk = data;
        if off > 0 {
            chunk = data[off..];
        }
        let r: result[i32, str] = err("");
        if w.ssl != nullptr {
            r = net.tls_send_until(w.ssl, chunk, w.deadline);
        } else {
            r = net.send_until(w.fd, chunk, w.deadline);
        }
        guard let n = r else let e = err_of(r) { return err(mail_fail(0, false, "smtp: write: " + e)); }
        if n <= 0 {
            return err(mail_fail(0, false, "smtp: write: the server closed the connection"));
        }
        off += n as int;
    }
    return ok(true);
}

fn wire_reply(w: Wire) -> result[smtp.Reply, MailError] {
    while true {
        let pr = smtp.parse_reply(w.buf, w.pos, w.max_reply);
        guard let o = pr else let e = err_of(pr) { return err(mail_fail(0, false, e)); }
        if let p = o {
            w.pos += p.used;
            if w.pos == len(w.buf) {
                w.buf = b"";
                w.pos = 0;
            }
            return ok(p.reply);
        }
        let r: result[bytes, str] = err("");
        if w.ssl != nullptr {
            r = net.tls_recv_until(w.ssl, 4096, w.deadline);
        } else {
            r = net.recv_until(w.fd, 4096, w.deadline);
        }
        guard let chunk = r else let e = err_of(r) { return err(mail_fail(0, false, "smtp: read: " + e)); }
        if len(chunk) == 0 {
            return err(mail_fail(0, false, "smtp: the server closed the connection"));
        }
        if w.pos > 0 {
            w.buf = w.buf[w.pos..];
            w.pos = 0;
        }
        w.buf = w.buf + chunk;
    }
    return err(mail_fail(0, false, "unreachable"));
}

// A reply with the code class wanted (2 for 2xx, 3 for 3xx), else the
// error a caller returns: permanent for 5xx.
fn expect(w: Wire, class: int, step: str) -> result[smtp.Reply, MailError] {
    let rr = wire_reply(w);
    guard let r = rr else let e = err_of(rr) { return err(e); }
    if r.code / 100 != class {
        return err(mail_fail(r.code, r.code >= 500, "smtp: " + step + ": " + smtp.reply_text(r)));
    }
    return ok(r);
}

fn command(w: Wire, line: bytes, class: int, step: str) -> result[smtp.Reply, MailError] {
    let sr = wire_send(w, line);
    guard let _s = sr else let e = err_of(sr) { return err(e); }
    return expect(w, class, step);
}

fn hello(w: Wire, helo: str, plain_ok: bool) -> result[smtp.Ext, MailError] {
    let sr = wire_send(w, smtp.cmd_ehlo(helo));
    guard let _s = sr else let e = err_of(sr) { return err(e); }
    let rr = wire_reply(w);
    guard let r = rr else let e = err_of(rr) { return err(e); }
    if r.code / 100 == 2 {
        return ok(smtp.extensions(r));
    }
    // A server without ESMTP: HELO, and no extensions at all, which is
    // only usable when nothing (TLS, login) was needed from them.
    if !plain_ok || r.code < 500 {
        return err(mail_fail(r.code, r.code >= 500, "smtp: EHLO: " + smtp.reply_text(r)));
    }
    let hr = command(w, smtp.cmd_helo(helo), 2, "HELO");
    guard let _h = hr else let e = err_of(hr) { return err(e); }
    return ok(smtp.no_ext());
}

fn login(w: Wire, m: Mailer, ext: smtp.Ext) -> result[bool, MailError] {
    let mech = smtp.pick_auth(ext);
    if mech == "PLAIN" {
        let r = command(w, smtp.auth_plain(m.user, m.pass), 2, "AUTH PLAIN");
        guard let _r = r else let e = err_of(r) { return err(e); }
        return ok(true);
    }
    if mech == "LOGIN" {
        let r1 = command(w, to_bytes("AUTH LOGIN\r\n"), 3, "AUTH LOGIN");
        guard let _a = r1 else let e = err_of(r1) { return err(e); }
        let r2 = command(w, smtp.base64_line(m.user), 3, "AUTH LOGIN");
        guard let _b = r2 else let e = err_of(r2) { return err(e); }
        let r3 = command(w, smtp.base64_line(m.pass), 2, "AUTH LOGIN");
        guard let _c = r3 else let e = err_of(r3) { return err(e); }
        return ok(true);
    }
    return err(mail_fail(0, true, "smtp: the server offers no login this client speaks (PLAIN or LOGIN); it offers: " +
        strings.join(ext.auth, " ")));
}

fn dial(m: Mailer, deadline: until) -> result[Wire, MailError] {
    let w = Wire { fd: -1, ssl: nullptr, buf: b"", pos: 0, deadline: deadline, max_reply: m.max_reply };
    if m.security == MailSecurity.Tls {
        let tr = net.tls_dial_until(m.host, m.port, m.tls_ctx, deadline);
        guard let ssl = tr else let e = err_of(tr) { return err(mail_fail(0, false, "smtp: connect: " + e)); }
        w.ssl = ssl;
        return ok(w);
    }
    let dr = net.dial_until(m.host, m.port, deadline);
    guard let fd = dr else let e = err_of(dr) { return err(mail_fail(0, false, "smtp: connect: " + e)); }
    w.fd = fd;
    return ok(w);
}

fn session(w: Wire, m: Mailer, p: Prepared) -> result[MailSent, MailError] {
    let gr = expect(w, 2, "greeting");
    guard let _g = gr else let e = err_of(gr) { return err(e); }
    let plain_ok = m.security != MailSecurity.StartTls && len(m.user) == 0;
    let er = hello(w, m.helo, plain_ok);
    guard let ext0 = er else let e = err_of(er) { return err(e); }
    let ext = ext0;
    if m.security == MailSecurity.StartTls {
        if !ext.starttls {
            return err(mail_fail(0, true, "smtp: the server does not offer STARTTLS; refusing to send in clear " +
                "(smtp+plain:// is for a server on this machine)"));
        }
        let sr = command(w, to_bytes("STARTTLS\r\n"), 2, "STARTTLS");
        guard let _s = sr else let e = err_of(sr) { return err(e); }
        // Bytes after the 220 were sent in clear before the handshake: a
        // man in the middle injecting replies (CVE-2011-0411's class).
        if w.pos != len(w.buf) {
            return err(mail_fail(0, false, "smtp: the server sent data before the TLS handshake"));
        }
        let ur = net.tls_upgrade_until(w.fd as int, m.host, m.tls_ctx, w.deadline);
        guard let ssl = ur else let e = err_of(ur) { return err(mail_fail(0, false, "smtp: TLS: " + e)); }
        w.ssl = ssl;
        // What the server said in clear is forgotten (RFC 3207 4.2).
        let er2 = hello(w, m.helo, false);
        guard let ext2 = er2 else let e = err_of(er2) { return err(e); }
        ext = ext2;
    }
    if len(m.user) > 0 {
        let lr = login(w, m, ext);
        guard let _l = lr else let e = err_of(lr) { return err(e); }
    }
    if ext.size > 0 && len(p.data) > ext.size {
        return err(mail_fail(0, true, "smtp: the message is " + to_str(len(p.data)) + " bytes; the server takes at most " +
            to_str(ext.size)));
    }
    // MAIL and every RCPT in one write when the server pipelines (RFC
    // 2920); DATA waits for their answers, so a refused recipient can
    // still stop the send before any of the message goes out.
    let mail_cmd = smtp.cmd_mail(p.from, len(p.data), ext.size > 0);
    if ext.pipelining {
        let batch = builder.new_bytes();
        batch.write(mail_cmd);
        for r in p.rcpts {
            batch.write(smtp.cmd_rcpt(r));
        }
        let sr = wire_send(w, batch.finish());
        guard let _s = sr else let e = err_of(sr) { return err(e); }
        // Every answer is read, so the first refusal is the one reported
        // (a refused MAIL makes each RCPT a 503 that says nothing).
        let bad = false;
        let first_bad = mail_fail(0, false, "");
        for i in 0..len(p.rcpts) + 1 {
            let step = "MAIL FROM";
            if i > 0 {
                step = "RCPT TO " + p.fields[i - 1];
            }
            let rr = expect(w, 2, step);
            guard let _r = rr else let e = err_of(rr) {
                if e.code == 0 {
                    return err(e);
                }
                if !bad {
                    bad = true;
                    first_bad = e;
                }
                continue;
            }
        }
        if bad {
            return err(first_bad);
        }
    } else {
        let mr = command(w, mail_cmd, 2, "MAIL FROM");
        guard let _m = mr else let e = err_of(mr) { return err(e); }
        for i in 0..len(p.rcpts) {
            let rr = command(w, smtp.cmd_rcpt(p.rcpts[i]), 2, "RCPT TO " + p.fields[i]);
            guard let _r = rr else let e = err_of(rr) { return err(e); }
        }
    }
    let dr = command(w, to_bytes("DATA\r\n"), 3, "DATA");
    guard let _d = dr else let e = err_of(dr) { return err(e); }
    let ur = wire_send(w, smtp.data_payload(p.data));
    guard let _u = ur else let e = err_of(ur) { return err(e); }
    let fr = expect(w, 2, "message");
    guard let final = fr else let e = err_of(fr) { return err(e); }
    // Delivered. QUIT is a courtesy: its answer changes nothing.
    wire_send(w, to_bytes("QUIT\r\n"));
    return ok(MailSent { message_id: p.message_id, recipients: len(p.rcpts), reply: smtp.reply_text(final) });
}

impl Mailer {
    // Sends one mail within the mailer's timeout.
    pub fn send(self: Mailer, mail: Mail) -> result[MailSent, MailError] {
        return self.send_until(mail, until_of(time.mono() + self.timeout));
    }

    pub fn send_until(self: Mailer, mail: Mail, deadline: until) -> result[MailSent, MailError] {
        let rr = crypto.rand(24);
        guard let random = rr else let e = err_of(rr) { return err(mail_fail(0, false, "smtp: random: " + e)); }
        let pr = prepare(self, mail, timez.now(), random);
        guard let p = pr else let e = err_of(pr) { return err(e); }
        let wr = dial(self, deadline);
        guard let w = wr else let e = err_of(wr) { return err(e); }
        let r = session(w, self, p);
        wire_close(w);
        return r;
    }
}
