fn okv(r: result[bool, str]) -> bool {
    guard let v = r else {
        return false;
    }
    return v;
}

fn why(r: result[bool, str]) -> str {
    guard let _v = r else let e = err_of(r) {
        return e;
    }
    return "";
}

fn test_is_string() {
    assert(okv(is_string("x")));
    assert(!okv(is_string("")));
    assert(!okv(is_string("   ")));
    assert(why(is_string("")) == "must not be empty");
}

fn test_lengths() {
    assert(okv(min_len("abcd", 4)));
    assert(!okv(min_len("abc", 4)));
    assert(okv(max_len("abc", 4)));
    assert(!okv(max_len("abcde", 4)));
}

fn test_ints_and_ranges() {
    assert(okv(is_int("42")));
    assert(okv(is_int("-42")));
    assert(!okv(is_int("")));
    assert(!okv(is_int("-")));
    assert(!okv(is_int("4x")));
    assert(okv(in_range("5", 1, 10)));
    assert(!okv(in_range("0", 1, 10)));
    assert(okv(is_port("8080")));
    assert(!okv(is_port("0")));
    assert(!okv(is_port("65536")));
    assert(okv(is_float("1.5")));
    assert(!okv(is_float("abc")));
}

fn test_bool_and_duration() {
    assert(okv(is_bool("TRUE")));
    assert(okv(is_bool("off")));
    assert(!okv(is_bool("maybe")));
    assert(okv(is_duration("30s")));
    assert(okv(is_duration("1500ms")));
    assert(okv(is_duration("90")));
    assert(!okv(is_duration("5x")));
    assert(duration_ns("2s", 0) == 2000000000);
    assert(duration_ns("1500ms", 0) == 1500000000);
    assert(duration_ns("2m", 0) == 120000000000);
    assert(duration_ns("bad", 7) == 7);
}

fn test_email() {
    assert(okv(is_email("ada@example.com")));
    assert(okv(is_email("a.b+c@sub.example.co.uk")));
    assert(!okv(is_email("ada@")));
    assert(!okv(is_email("@example.com")));
    assert(!okv(is_email("ada@@example.com")));
    assert(!okv(is_email("ada@example")));
    assert(!okv(is_email("ada example@x.com")));
}

fn test_url_and_dsn() {
    assert(okv(is_url("https://example.com")));
    assert(okv(is_url("http://a")));
    assert(!okv(is_url("ftp://example.com")));
    assert(okv(is_dsn("postgres://user:pw@host:5432/db")));
    assert(okv(is_dsn("redis://localhost")));
    assert(!okv(is_dsn("localhost:5432")));
    assert(!okv(is_dsn("://host")));
}

fn test_uuid_host_ip() {
    assert(okv(is_uuid("123e4567-e89b-12d3-a456-426614174000")));
    assert(!okv(is_uuid("123e4567e89b12d3a456426614174000")));
    assert(!okv(is_uuid("123e4567-e89b-12d3-a456-42661417400g")));
    assert(okv(is_host("api.example.com")));
    assert(okv(is_host("localhost")));
    assert(!okv(is_host("api..example.com")));
    assert(!okv(is_host("")));
    assert(okv(is_ipv4("127.0.0.1")));
    assert(!okv(is_ipv4("127.0.0")));
    assert(!okv(is_ipv4("256.0.0.1")));
}

fn test_one_of_and_printable() {
    let levels = ["debug", "info", "warn", "error"];
    assert(okv(is_one_of("INFO", levels)));
    assert(!okv(is_one_of("trace", levels)));
    assert(why(is_one_of("trace", levels)) ==
           "must be one of: debug, info, warn, error");
    assert(okv(is_printable("hello")));
    assert(!okv(is_printable("a\nb")));
}
