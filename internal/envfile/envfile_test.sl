fn test_basic() {
    let m = parse("PORT=8080\nNAME=zokor\n");
    assert(len(m) == 2);
    assert(m["PORT"] == "8080");
    assert(m["NAME"] == "zokor");
}

fn test_comments_and_blanks() {
    let m = parse("# a comment\n\n  \nPORT=1\n#PORT=2\n");
    assert(len(m) == 1);
    assert(m["PORT"] == "1");
}

fn test_quotes_and_spaces() {
    let m = parse("A=\"with spaces\"\nB='single'\nC= trimmed \nD=\n");
    assert(m["A"] == "with spaces");
    assert(m["B"] == "single");
    assert(m["C"] == "trimmed");
    assert(m["D"] == "");
}

fn test_export_and_trailing_comment() {
    let m = parse("export DATABASE_URL=postgres://host/db\nPORT=8080 # the port\nURL=http://a#b\n");
    assert(m["DATABASE_URL"] == "postgres://host/db");
    assert(m["PORT"] == "8080");
    assert(m["URL"] == "http://a#b");
}

fn test_malformed_lines_are_skipped() {
    let m = parse("NOEQUALS\n=novalue\nGOOD=1\n");
    assert(len(m) == 1);
    assert(m["GOOD"] == "1");
}

fn test_crlf() {
    let m = parse("A=1\r\nB=2\r\n");
    assert(m["A"] == "1");
    assert(m["B"] == "2");
}
