import "encoding";
import "strings";

fn parsed(buf: str) -> Parsed {
    let r = parse_reply(to_bytes(buf), 0, 4096);
    guard let o = r else let e = err_of(r) { panic("parse_reply: " + e); }
    guard let p = o else { panic("parse_reply: incomplete"); }
    return p;
}

fn refused(buf: str) -> str {
    let r = parse_reply(to_bytes(buf), 0, 64);
    guard let _o = r else let e = err_of(r) { return e; }
    panic("accepted: " + buf);
}

fn test_reply_single_and_multiline() {
    let p = parsed("220 mx.example.com ESMTP ready\r\nleftover");
    assert(p.reply.code == 220 && len(p.reply.lines) == 1 && p.reply.lines[0] == "mx.example.com ESMTP ready");
    assert(p.used == 32, "used " + to_str(p.used));
    let m = parsed("250-mx.example.com\r\n250-PIPELINING\r\n250-SIZE 1000\r\n250 STARTTLS\r\n");
    assert(m.reply.code == 250 && len(m.reply.lines) == 4 && m.reply.lines[3] == "STARTTLS");
    // A bare code ends a reply; a bare LF ends a line.
    let b = parsed("250\n");
    assert(b.reply.code == 250 && b.reply.lines[0] == "");
}

fn test_reply_waits_for_the_last_line() {
    for partial in ["", "25", "250-a\r\n", "250-a\r\n250 b"] {
        let r = parse_reply(to_bytes(partial), 0, 4096);
        guard let o = r else let e = err_of(r) { panic(e); }
        if let _p = o { panic("complete too early: " + partial); }
    }
    // From an offset, as the reader resumes after an earlier reply.
    let r = parse_reply(to_bytes("220 hi\r\n250 ok\r\n"), 8, 4096);
    guard let o = r else { panic("offset parse failed"); }
    guard let p = o else { panic("offset parse incomplete"); }
    assert(p.reply.code == 250 && p.used == 8);
}

fn test_reply_refuses_what_is_not_a_reply() {
    assert(strings.contains(refused("hello\r\n"), "code"));
    assert(strings.contains(refused("650 no\r\n"), "code"));
    assert(strings.contains(refused("2x0 no\r\n"), "code"));
    assert(strings.contains(refused("250-a\r\n251 b\r\n"), "different codes"));
    assert(strings.contains(refused("250_a\r\n"), "space or dash"));
    // Longer than max, complete or not.
    assert(strings.contains(refused("250 " + strings.repeat("x", 80) + "\r\n"), "longer"));
    assert(strings.contains(refused("250-" + strings.repeat("x", 80)), "longer"));
}

fn test_extensions() {
    let p = parsed("250-mx\r\n250-pipelining\r\n250-SIZE 35882577\r\n250-AUTH LOGIN plain XOAUTH2\r\n250-AUTH=LOGIN\r\n250 STARTTLS\r\n");
    let e = extensions(p.reply);
    assert(e.starttls && e.pipelining && e.size == 35882577);
    assert(len(e.auth) == 3 && e.auth[0] == "LOGIN" && e.auth[1] == "PLAIN", inspect(e.auth));
    assert(pick_auth(e) == "PLAIN");
    let only_login = extensions(parsed("250-mx\r\n250 AUTH LOGIN\r\n").reply);
    assert(pick_auth(only_login) == "LOGIN" && !only_login.starttls);
    let none_ = extensions(parsed("250-mx\r\n250 AUTH CRAM-MD5\r\n").reply);
    assert(pick_auth(none_) == "");
    // The greeting line is never read as a keyword.
    assert(!extensions(parsed("250 STARTTLS\r\n").reply).starttls);
}

fn test_auth_and_commands() {
    let plain = to_str(auth_plain("ada", "s3cret"));
    assert(plain == "AUTH PLAIN AGFkYQBzM2NyZXQ=\r\n", plain);
    assert(to_str(cmd_mail("a@b.co", 1200, true)) == "MAIL FROM:<a@b.co> SIZE=1200\r\n");
    assert(to_str(cmd_mail("a@b.co", 1200, false)) == "MAIL FROM:<a@b.co>\r\n");
    assert(to_str(cmd_rcpt("c@d.co")) == "RCPT TO:<c@d.co>\r\n");
}

fn test_data_payload_stuffs_dots_and_ends_the_message() {
    assert(to_str(data_payload(to_bytes("a\r\n.b\r\n..c\r\n"))) == "a\r\n..b\r\n...c\r\n.\r\n");
    assert(to_str(data_payload(to_bytes(".\r\nx"))) == "..\r\nx\r\n.\r\n");
    // A bare LF or CR cannot end the message early.
    assert(to_str(data_payload(to_bytes("a\n.\nb\r.\r"))) == "a\r\n..\r\nb\r\n..\r\n.\r\n");
    assert(to_str(data_payload(b"")) == ".\r\n");
}

fn addr_err(s: str) -> str {
    let r = parse_address(s);
    guard let _a = r else let e = err_of(r) { return e; }
    panic("accepted address: " + s);
}

fn test_addresses() {
    let a = parse_address("ada@example.com") ?? Address { name: "x", addr: "" };
    assert(a.name == "" && a.addr == "ada@example.com");
    let b = parse_address("  Ada Lovelace <ada.l+x@mail.example.co.uk> ") ?? Address { name: "", addr: "" };
    assert(b.name == "Ada Lovelace" && b.addr == "ada.l+x@mail.example.co.uk");
    let q = parse_address("\"Lovelace, Ada\" <ada@example.com>") ?? Address { name: "", addr: "" };
    assert(q.name == "Lovelace, Ada");
    assert((parse_address("dev@localhost") ?? Address { name: "", addr: "" }).addr == "dev@localhost");
    assert((parse_address("x@[127.0.0.1]") ?? Address { name: "", addr: "" }).addr == "x@[127.0.0.1]");
    assert(strings.contains(addr_err("ada@example.com\r\nBcc: evil@x.com"), "line break"));
    assert(strings.contains(addr_err("ada@exam ple.com"), "domain"));
    assert(strings.contains(addr_err("ada"), "name@example.com"));
    assert(strings.contains(addr_err("a..b@example.com"), "empty part"));
    assert(strings.contains(addr_err(".a@example.com"), "empty part"));
    assert(strings.contains(addr_err("a.@example.com"), "dot just before"));
    assert(strings.contains(addr_err("a b@example.com"), "unquoted"));
    assert(strings.contains(addr_err("ada@-x.com"), "'-'"));
    assert(strings.contains(addr_err("ada@x.com."), "ending"));
    assert(strings.contains(addr_err("ada@exämple.com"), "xn--"));
    assert(strings.contains(addr_err("Ada <ada@x.com"), "Name <"));
    assert(strings.contains(addr_err("A\"da <ada@x.com>"), "quote"));
    assert(strings.contains(addr_err("a<b>c@x.com>"), "Name <"));
    assert(strings.contains(addr_err(strings.repeat("a", 65) + "@x.com"), "64"));
}

fn test_header_checks() {
    assert(check_value("plain") ?? false);
    assert(!(check_value("a\r\nBcc: x@y.z") ?? false));
    assert(!(check_value("a\nb") ?? false));
    assert(!(check_value(strings.repeat("x", 901)) ?? false));
    assert(check_header_name("List-Unsubscribe") ?? false);
    for bad in ["", "Bad Name", "a:b", "From", "bcc", "Content-Type", "MIME-Version", "Message-ID"] {
        assert(!(check_header_name(bad) ?? false), "accepted header name " + bad);
    }
    assert(check_filename("report.pdf") ?? false);
    for bad in ["", "../x", "a/b", "a\\b", "a\"b", "a\r\nb", ".."] {
        assert(!(check_filename(bad) ?? false), "accepted filename " + bad);
    }
    assert(check_content_type("application/pdf") ?? false);
    for bad in ["pdf", "text/plain; charset=x", "/x", "x/", "a/b\r\nX: y"] {
        assert(!(check_content_type(bad) ?? false), "accepted content type " + bad);
    }
}

fn test_header_text_folds_ascii_and_encodes_the_rest() {
    assert(header_text(7, "Welcome") == "Welcome");
    let long = strings.repeat("word ", 30) + "end";
    let f = header_text(7, long);
    assert(strings.contains(f, "\r\n "));
    // Unfolding (dropping each CRLF) gives back the value.
    assert(strings.replace(f, "\r\n", "") == long);
    for line in strings.split(f, "\r\n") {
        assert(len(line) <= 78, "line of " + to_str(len(line)));
    }
    let e = header_text(7, "Grüße aus Köln");
    assert(e == "=?UTF-8?B?" + encoding.base64_encode(to_bytes("Grüße aus Köln")) + "?=", e);
    // Long non-ASCII text is split between characters, never inside one.
    let jp = strings.repeat("日本語", 10);
    let w = encode_words(jp);
    let back = "";
    for part in strings.split(w, "\r\n ") {
        assert(strings.has_prefix(part, "=?UTF-8?B?") && strings.has_suffix(part, "?="));
        let inner = strings.slice(part, 10, len(part) - 2);
        let d = encoding.base64_decode(inner) ?? b"";
        assert(len(d) <= 39 && len(d) % 3 == 0, "chunk of " + to_str(len(d)));
        back = back + to_str(d);
    }
    assert(back == jp);
}

fn test_address_list_and_display_names() {
    let xs = [Address { name: "Ada", addr: "ada@x.com" }, Address { name: "Lovelace, A.", addr: "l@x.com" },
              Address { name: "", addr: "bare@x.com" }, Address { name: "Zoë", addr: "z@x.com" }];
    let s = address_list(2, xs);
    assert(strings.has_prefix(s, "Ada <ada@x.com>, \"Lovelace, A.\" <l@x.com>,"), s);
    assert(strings.contains(s, "bare@x.com"));
    assert(strings.contains(s, "=?UTF-8?B?" + encoding.base64_encode(to_bytes("Zoë")) + "?= <z@x.com>"), s);
    for line in strings.split(s, "\r\n") {
        assert(len(line) <= 78);
    }
}

fn test_quoted_printable() {
    assert(quoted_printable("plain text") == "plain text");
    assert(quoted_printable("a=b") == "a=3Db");
    assert(quoted_printable("é") == "=C3=A9");
    // Trailing white space before a break or the end is escaped.
    assert(quoted_printable("a \nb\t") == "a=20\r\nb=09");
    assert(quoted_printable("x\r\ny\rz") == "x\r\ny\r\nz");
    let long = quoted_printable(strings.repeat("a", 200));
    for line in strings.split(long, "\r\n") {
        assert(len(line) <= 76, "line of " + to_str(len(line)));
    }
    assert(strings.replace(long, "=\r\n", "") == strings.repeat("a", 200));
    // A soft break never splits an escape.
    let esc = quoted_printable(strings.repeat("é", 40));
    for line in strings.split(esc, "\r\n") {
        assert(len(line) <= 76);
        let body = line;
        if strings.has_suffix(body, "=") {
            body = strings.slice(body, 0, len(body) - 1);
        }
        assert(len(body) % 3 == 0, line);
    }
}

fn sample_head() -> Head {
    let none_: [Address] = [];
    let extra: [Header] = [Header { name: "List-Unsubscribe", value: "<https://x.com/u>" }];
    return Head {
        from: Address { name: "Shop", addr: "shop@x.com" },
        to: [Address { name: "", addr: "ada@y.com" }],
        cc: none_,
        reply_to: none_,
        subject: "Your order",
        date: "Tue, 13 Oct 2026 09:30:15 +0000",
        message_id: "<abc@x.com>",
        extra: extra
    };
}

fn test_build_text_only() {
    let atts: [Attachment] = [];
    let m = to_str(build(sample_head(), "Hi Ada.\n.\nBye", "", atts, "=_b1"));
    let want = "Date: Tue, 13 Oct 2026 09:30:15 +0000\r\nFrom: Shop <shop@x.com>\r\nTo: ada@y.com\r\n" +
        "Message-ID: <abc@x.com>\r\nSubject: Your order\r\nList-Unsubscribe: <https://x.com/u>\r\n" +
        "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n" +
        "Content-Transfer-Encoding: quoted-printable\r\n\r\nHi Ada.\r\n.\r\nBye\r\n";
    assert(m == want, m);
    assert(!strings.contains(m, "Bcc"));
}

fn test_build_alternative_with_attachment() {
    let atts = [Attachment { filename: "r.pdf", content_type: "Application/PDF", data: b"%PDF-1.7" },
                Attachment { filename: "résumé.txt", content_type: "text/plain", data: b"x" }];
    let m = to_str(build(sample_head(), "text", "<b>html</b>", atts, "=_b1"));
    assert(strings.contains(m, "Content-Type: multipart/mixed;\r\n boundary=\"=_b1m\"\r\n\r\n--=_b1m\r\n" +
        "Content-Type: multipart/alternative;\r\n boundary=\"=_b1a\"\r\n\r\n--=_b1a\r\n" +
        "Content-Type: text/plain; charset=utf-8\r\n"), m);
    assert(strings.contains(m, "\r\n--=_b1a\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n<b>html</b>\r\n--=_b1a--\r\n--=_b1m\r\n"), m);
    assert(strings.contains(m, "Content-Type: application/pdf; name=\"r.pdf\"\r\nContent-Disposition: attachment; filename=\"r.pdf\"\r\n" +
        "Content-Transfer-Encoding: base64\r\n\r\n" + encoding.base64_encode(b"%PDF-1.7") + "\r\n--=_b1m"), m);
    assert(strings.contains(m, "filename*=UTF-8''r%C3%A9sum%C3%A9.txt"), m);
    assert(strings.has_suffix(m, "--=_b1m--\r\n"));
    // No line passes the 998-character limit.
    for line in strings.split(m, "\r\n") {
        assert(len(line) <= 998);
    }
}

fn test_base64_lines_wrap_at_76() {
    let s = base64_lines(strings.bytes_zero(300));
    for line in strings.split(s, "\r\n") {
        assert(len(line) <= 76);
    }
    assert((encoding.base64_decode(strings.replace(s, "\r\n", "")) ?? b"") == strings.bytes_zero(300));
}
