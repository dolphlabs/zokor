import "encoding";
import "net";
import "strings";
import "time";
import "timez";

// A scripted SMTP server on a loopback port, one connection per test.
// It records every command line, and the message DATA carried.
gc struct FakeSmtp {
    port: int,
    // "tls": TLS from the first byte; "starttls": offered; "": neither.
    tls: str,
    ehlo_lines: [str],
    reject_rcpt: str,
    reject_mail: str,
    greeting: str,
    // Sent in clear straight after STARTTLS's 220, before the handshake.
    inject: str,
    log: [str],
    data: str,
    done: chan[bool],
}

// Bytes read and not yet returned as a line.
gc struct FakeIn { pending: bytes, in_tls: bool }

fn fake(tls: str) -> FakeSmtp {
    let log: [str] = [];
    let ehlo = ["PIPELINING", "SIZE 100000", "AUTH PLAIN LOGIN"];
    if tls == "starttls" {
        push(ehlo, "STARTTLS");
    }
    return FakeSmtp {
        port: 0, tls: tls, ehlo_lines: ehlo, reject_rcpt: "", reject_mail: "",
        greeting: "220 fake.test ESMTP", inject: "", log: log, data: "", done: make_chan(1)
    };
}

// Listens on a free port and serves one connection in its own task.
fn serve(f: FakeSmtp) {
    let lr = link_listen(0);
    guard let ln = lr else let e = err_of(lr) { panic("listen: " + to_str(e)); }
    f.port = ln.port();
    spawn serve_fake(f, ln);
}

fn server_ctx() -> rawptr {
    let r: result[rawptr, str] = net.tls_server_ctx("testdata/tls/cert.pem", "testdata/tls/key.pem");
    guard let c = r else let e = err_of(r) { panic("server ctx: " + e); }
    return c;
}

fn fdl() -> until { return until_of(time.mono() + 2000000000); }

fn fc_send(c: &mut link, s: str) {
    let data = to_bytes(s);
    let a = arena_new(len(data) + 64);
    let out = a.wire(len(data));
    for i in 0..len(data) {
        out[i] = data[i];
    }
    let _w = c.send(out, fdl());
}

// The next line without its CRLF; none once the client is gone.
fn fc_line(c: &mut link, inb: FakeIn) -> opt[str] {
    while true {
        let n = len(inb.pending);
        for i in 0..n {
            if inb.pending[i] == 10 {
                let end = i;
                if end > 0 && inb.pending[end - 1] == 13 {
                    end -= 1;
                }
                let line = strings.from_bytes(inb.pending, 0, end);
                inb.pending = inb.pending[i + 1..];
                return some(line);
            }
        }
        let a = arena_new(8192);
        let buf = a.wire(4096);
        let rr = c.recv(buf, fdl());
        guard let got = rr else { return none; }
        if got == 0 {
            return none;
        }
        inb.pending = inb.pending + to_bytes(buf[0..got]);
    }
    return none;
}

fn ehlo_reply(f: FakeSmtp, in_tls: bool) -> str {
    let s = "250-fake.test\r\n";
    for l in f.ehlo_lines {
        if l == "STARTTLS" && in_tls {
            continue;
        }
        s = s + "250-" + l + "\r\n";
    }
    return s + "250 HELP\r\n";
}

fn serve_fake(f: FakeSmtp, ln: link) {
    let l = ln;
    let ar = l.accept(fdl());
    guard let c = ar else { chan_send(f.done, false); return; }
    let inb = FakeIn { pending: b"", in_tls: false };
    let ctx: rawptr = nullptr;
    if f.tls != "" {
        ctx = server_ctx();
    }
    if f.tls == "tls" {
        let tr = c.tls_accept(ctx, fdl());
        guard let _t = tr else { chan_send(f.done, false); return; }
        inb.in_tls = true;
    }
    fc_send(&mut c, f.greeting + "\r\n");
    while true {
        guard let line = fc_line(&mut c, inb) else { break; }
        push(f.log, line);
        let up = strings.to_upper(line);
        if strings.has_prefix(up, "EHLO") {
            fc_send(&mut c, ehlo_reply(f, inb.in_tls));
        } else if up == "STARTTLS" {
            fc_send(&mut c, "220 go ahead\r\n" + f.inject);
            let tr = c.tls_accept(ctx, fdl());
            guard let _t = tr else { break; }
            inb.in_tls = true;
            inb.pending = b"";
        } else if strings.has_prefix(up, "AUTH PLAIN ") {
            if strings.slice(line, 11, len(line)) == "AHVzZXIAcCBhOnNz" {
                fc_send(&mut c, "235 2.7.0 ok\r\n");
            } else {
                fc_send(&mut c, "535 5.7.8 bad credentials\r\n");
            }
        } else if strings.has_prefix(up, "MAIL FROM:") {
            if f.reject_mail != "" {
                fc_send(&mut c, f.reject_mail + "\r\n");
            } else {
                fc_send(&mut c, "250 2.1.0 ok\r\n");
            }
        } else if strings.has_prefix(up, "RCPT TO:") {
            if f.reject_rcpt != "" && strings.contains(line, f.reject_rcpt) {
                fc_send(&mut c, "550 5.1.1 no such user\r\n");
            } else {
                fc_send(&mut c, "250 2.1.5 ok\r\n");
            }
        } else if up == "DATA" {
            fc_send(&mut c, "354 end with .\r\n");
            let body = "";
            while true {
                guard let dl = fc_line(&mut c, inb) else { break; }
                if dl == "." {
                    break;
                }
                body = body + dl + "\r\n";
            }
            f.data = body;
            fc_send(&mut c, "250 2.0.0 Ok: queued as Q1\r\n");
        } else if up == "QUIT" {
            fc_send(&mut c, "221 bye\r\n");
            break;
        } else {
            fc_send(&mut c, "502 5.5.1 unknown\r\n");
        }
    }
    chan_send(f.done, true);
}

fn finish(f: FakeSmtp) {
    chan_recv(f.done);
}

fn mailer_of(url: str) -> Mailer {
    let r = new_mailer(url, "testdata/tls/ca.pem");
    guard let m = r else let e = err_of(r) { panic("new_mailer: " + e); }
    m.helo = "client.test";
    m.timeout = 3000000000;
    m.from = "Shop <shop@x.test>";
    return m;
}

fn sent(r: result[MailSent, MailError]) -> MailSent {
    guard let s = r else let e = err_of(r) { panic("send: " + e.detail); }
    return s;
}

fn failed(r: result[MailSent, MailError]) -> MailError {
    guard let _s = r else let e = err_of(r) { return e; }
    panic("send succeeded");
}

fn logged(f: FakeSmtp, prefix: str) -> int {
    let n = 0;
    for l in f.log {
        if strings.has_prefix(l, prefix) {
            n += 1;
        }
    }
    return n;
}

// The password is "p a:ss": percent-encoded in the URL, sent as is.
fn starttls_url(f: FakeSmtp) -> str {
    return "smtp://user:p%20a%3Ass@localhost:" + to_str(f.port);
}

fn test_mail_plain_loopback_delivers() {
    let f = fake("");
    serve(f);
    let m = mailer_of("smtp+plain://127.0.0.1:" + to_str(f.port));
    let mail = new_mail("Ada <ada@y.test>", "Hello", "Hi Ada.\n.leading dot");
    mail.bcc = ["hidden@y.test", "ADA@y.test"];
    let s = sent(m.send(mail));
    finish(f);
    assert(s.recipients == 2, "recipients " + to_str(s.recipients));
    assert(s.reply == "250 2.0.0 Ok: queued as Q1", s.reply);
    assert(strings.has_prefix(s.message_id, "<") && strings.has_suffix(s.message_id, "@x.test>"), s.message_id);
    assert(f.log[0] == "EHLO client.test", f.log[0]);
    assert(logged(f, "MAIL FROM:<shop@x.test> SIZE=") == 1, inspect(f.log));
    assert(logged(f, "RCPT TO:") == 2, inspect(f.log));
    assert(logged(f, "AUTH") == 0);
    // DATA arrives dot-stuffed; the fake reads it raw.
    assert(strings.contains(f.data, "\r\n..leading dot\r\n"), f.data);
    assert(strings.contains(f.data, "To: Ada <ada@y.test>\r\n"));
    assert(strings.contains(f.data, "Message-ID: " + s.message_id + "\r\n"));
    assert(!strings.contains(f.data, "hidden"), "bcc leaked into the message");
    assert(f.log[len(f.log) - 1] == "QUIT");
}

fn test_mail_starttls_then_login() {
    let f = fake("starttls");
    serve(f);
    let s = sent(mailer_of(starttls_url(f)).send(new_mail("ada@y.test", "Hi", "body")));
    finish(f);
    assert(s.recipients == 1);
    // EHLO again inside TLS, then login, never before.
    assert(f.log[0] == "EHLO client.test" && f.log[1] == "STARTTLS" && f.log[2] == "EHLO client.test", inspect(f.log));
    assert(strings.has_prefix(f.log[3], "AUTH PLAIN "), inspect(f.log));
}

fn test_mail_implicit_tls() {
    let f = fake("tls");
    serve(f);
    let s = sent(mailer_of("smtps://user:p%20a%3Ass@localhost:" + to_str(f.port)).send(new_mail("ada@y.test", "Hi", "b")));
    finish(f);
    assert(s.recipients == 1 && logged(f, "STARTTLS") == 0 && logged(f, "AUTH PLAIN") == 1);
}

// A server (or a man in the middle) that drops STARTTLS from EHLO gets
// no mail and no password.
fn test_mail_refuses_a_server_without_starttls() {
    let f = fake("");
    serve(f);
    let e = failed(mailer_of(starttls_url(f)).send(new_mail("ada@y.test", "Hi", "b")));
    finish(f);
    assert(e.permanent && strings.contains(e.detail, "does not offer STARTTLS"), e.detail);
    assert(logged(f, "AUTH") == 0 && logged(f, "MAIL") == 0, inspect(f.log));
}

fn test_mail_refuses_replies_injected_before_the_handshake() {
    let f = fake("starttls");
    f.inject = "250 injected\r\n";
    serve(f);
    let e = failed(mailer_of(starttls_url(f)).send(new_mail("ada@y.test", "Hi", "b")));
    finish(f);
    assert(strings.contains(e.detail, "before the TLS handshake"), e.detail);
    assert(logged(f, "AUTH") == 0);
}

fn test_mail_verifies_the_server_certificate() {
    let f = fake("tls");
    serve(f);
    // The system roots do not trust the test CA.
    let r = new_mailer("smtps://localhost:" + to_str(f.port), "");
    guard let m = r else let e = err_of(r) { panic(e); }
    m.from = "shop@x.test";
    m.timeout = 3000000000;
    let e = failed(m.send(new_mail("ada@y.test", "Hi", "b")));
    finish(f);
    assert(e.code == 0 && !e.permanent && strings.contains(e.detail, "connect"), e.detail);
    assert(len(f.log) == 0);
}

fn test_mail_wrong_password_is_permanent() {
    let f = fake("tls");
    serve(f);
    let e = failed(mailer_of("smtps://user:wrong@localhost:" + to_str(f.port)).send(new_mail("ada@y.test", "Hi", "b")));
    finish(f);
    assert(e.code == 535 && e.permanent, e.detail);
    assert(!strings.contains(e.detail, "wrong"));
}

fn test_mail_refused_recipient_names_its_field() {
    let f = fake("");
    f.reject_rcpt = "gone@";
    serve(f);
    let mail = new_mail("ada@y.test", "Hi", "b");
    mail.cc = ["gone@y.test"];
    let e = failed(mailer_of("smtp+plain://localhost:" + to_str(f.port)).send(mail));
    finish(f);
    assert(e.code == 550 && e.permanent, e.detail);
    assert(strings.contains(e.detail, "RCPT TO cc[0]: 550 5.1.1 no such user"), e.detail);
    assert(logged(f, "DATA") == 0, inspect(f.log));
}

fn test_mail_temporary_refusal_is_retryable() {
    let f = fake("");
    f.reject_mail = "451 4.3.0 try again later";
    serve(f);
    let e = failed(mailer_of("smtp+plain://localhost:" + to_str(f.port)).send(new_mail("ada@y.test", "Hi", "b")));
    finish(f);
    assert(e.code == 451 && !e.permanent, e.detail);
    assert(strings.has_prefix(e.detail, "smtp: MAIL FROM: 451"), e.detail);
}

fn test_mail_greeting_refusal() {
    let f = fake("");
    f.greeting = "554 5.3.2 not accepting";
    serve(f);
    let e = failed(mailer_of("smtp+plain://localhost:" + to_str(f.port)).send(new_mail("ada@y.test", "Hi", "b")));
    finish(f);
    assert(e.code == 554 && e.permanent, e.detail);
}

fn test_mail_too_big_for_the_server() {
    let f = fake("");
    serve(f);
    let e = failed(mailer_of("smtp+plain://localhost:" + to_str(f.port)).send(new_mail("ada@y.test", "Hi", strings.repeat("x", 120000))));
    finish(f);
    assert(e.permanent && strings.contains(e.detail, "at most 100000"), e.detail);
    assert(logged(f, "MAIL") == 0);
}

fn test_mail_times_out() {
    let lr: result[i32, str] = net.listen(0);
    guard let lfd = lr else { panic("listen"); }
    let port = net.port(lfd) ?? 0;
    // Accepted by the kernel, never answered.
    let m = mailer_of("smtp+plain://127.0.0.1:" + to_str(port));
    m.timeout = 200000000;
    let e = failed(m.send(new_mail("ada@y.test", "Hi", "b")));
    net.close(lfd);
    assert(!e.permanent && strings.contains(e.detail, "timeout"), e.detail);
}

fn fixed_now() -> timez.Time {
    let r = timez.utc(2026, 10, 13, 9, 30, 15, 0);
    guard let t = r else { panic("time"); }
    return t;
}

fn test_mail_checks_every_field_at_once() {
    let m = mailer_of("smtp+plain://localhost:25");
    m.from = "";
    let mail = new_mail("not-an-address", "a\r\nBcc: evil@x.test", "");
    mail.cc = ["ok@y.test", "bad@"];
    mail.attach("../etc/passwd", "text/plain", b"x");
    mail.attach("a.pdf", "application/pdf; x=y", b"x");
    mail.header("Bcc", "evil@x.test");
    mail.header("X-Ok", "line\nbreak");
    let r = prepare(m, mail, fixed_now(), strings.bytes_zero(24));
    guard let _p = r else let e = err_of(r) {
        let keys: [str] = [];
        for p in e.problems {
            push(keys, p.key);
        }
        assert(strings.join(keys, ",") ==
            "from,to[0],cc[1],subject,text,attachments[0].filename,attachments[1].content_type,headers[0].name,headers[1].value",
            strings.join(keys, ","));
        assert(e.permanent && e.code == 0 && strings.has_prefix(e.detail, "mail is invalid: from is not set"), e.detail);
        return;
    }
    panic("an invalid mail was prepared");
}

fn prepare_err(m: Mailer, mail: Mail) -> str {
    let r = prepare(m, mail, fixed_now(), strings.bytes_zero(24));
    guard let _p = r else let e = err_of(r) { return e.detail; }
    panic("prepared an invalid mail");
}

fn test_mail_recipient_limits() {
    let m = mailer_of("smtp+plain://localhost:25");
    let none_ = new_mail("x@y.test", "s", "b");
    none_.to = [];
    assert(strings.contains(prepare_err(m, none_), "at least one recipient"));
    let many = new_mail("x@y.test", "s", "b");
    for i in 0..100 {
        push(many.bcc, "u" + to_str(i) + "@y.test");
    }
    assert(strings.contains(prepare_err(m, many), "101 recipients"));
}

fn test_mail_prepare_is_deterministic() {
    let m = mailer_of("smtp+plain://localhost:25");
    let mail = new_mail("ada@y.test", "Hi", "b");
    mail.html = "<p>b</p>";
    let r = prepare(m, mail, fixed_now(), strings.bytes_zero(24));
    guard let p = r else let e = err_of(r) { panic(e.detail); }
    let s = to_str(p.data);
    assert(p.message_id == "<00000000000000000000000000000000@x.test>", p.message_id);
    assert(strings.has_prefix(s, "Date: Tue, 13 Oct 2026 09:30:15 +0000\r\nFrom: Shop <shop@x.test>\r\n"), s);
    assert(strings.contains(s, "boundary=\"=_0000000000000000a\""), s);
    assert(p.from == "shop@x.test" && len(p.rcpts) == 1 && p.fields[0] == "to[0]");
}

fn url_err(url: str) -> str {
    let r = new_mailer(url, "");
    guard let _m = r else let e = err_of(r) { return e; }
    panic("accepted " + url);
}

fn test_mailer_urls() {
    let a = mailer_of("smtps://u%40x:p%2Fw@mail.example.com");
    assert(a.security == MailSecurity.Tls && a.port == 465 && a.user == "u@x" && a.pass == "p/w" && a.host == "mail.example.com");
    let b = mailer_of("smtp://smtp.example.com:2525/");
    assert(b.security == MailSecurity.StartTls && b.port == 2525 && b.user == "");
    let c = mailer_of("smtp+plain://[::1]:1025");
    assert(c.security == MailSecurity.Plain && c.host == "::1" && c.port == 1025);
    assert(strings.contains(url_err("http://x.com"), "smtps://"));
    assert(strings.contains(url_err("smtp+plain://mail.example.com"), "this machine"));
    assert(strings.contains(url_err("smtp+plain://u:p@localhost"), "never sends credentials"));
    assert(strings.contains(url_err("smtp://x.com:0"), "port"));
    assert(strings.contains(url_err("smtp://x.com:abc"), "port"));
    assert(strings.contains(url_err("smtp://x.com/path"), "no path"));
    assert(strings.contains(url_err("smtp://:p@x.com"), "empty user"));
    assert(strings.contains(url_err("smtp://u:%zz@x.com"), "percent"));
    assert(strings.contains(url_err("smtp://bad_host!:25"), "host"));
    // No error repeats the password.
    assert(!strings.contains(url_err("smtp://u:hunter2@x.com/p"), "hunter2"));
}

fn url_or_err(r: result[Mailer, str]) -> str {
    guard let _m = r else let e = err_of(r) { return e; }
    return "";
}

fn test_mailer_from_config() {
    assert(!has_mailer(cfg_of("SERVICE_NAME=api\n")));
    let none_ = mailer_from_config(cfg_of("SERVICE_NAME=api\n"));
    assert(url_or_err(none_) == "SMTP_URL is not set");
    let c = cfg_of("SMTP_URL=smtp://u:p@mail.example.com\nSMTP_FROM=App <app@example.com>\nSMTP_HELO=api.example.com\nSMTP_TIMEOUT=5s\n");
    assert(has_mailer(c));
    let r = mailer_from_config(c);
    guard let m = r else let e = err_of(r) { panic(e); }
    assert(m.from == "App <app@example.com>" && m.helo == "api.example.com" && m.timeout == 5000000000);
    let bad = mailer_from_config(cfg_of("SMTP_URL=smtp://mail.example.com\nSMTP_FROM=nope\nSMTP_HELO=bad host\n"));
    let e = url_or_err(bad);
    assert(strings.contains(e, "SMTP_FROM") && strings.contains(e, "SMTP_HELO"), e);
}
