import "internal/envfile";

fn cfg_of(text: str) -> Config {
    let probs: [Problem] = [];
    return Config { values: envfile.parse(text), problems: probs, source: ".env" };
}

fn test_reads_values() {
    let c = cfg_of("PORT=8080\nNAME=zokor\n");
    assert(str_or(c, "NAME", "x") == "zokor");
    assert(int_or(c, "PORT", 0) == 8080);
    assert(str_or(c, "MISSING", "fallback") == "fallback");
    assert(has_key(c, "PORT"));
    assert(!has_key(c, "MISSING"));
}

fn test_bool_and_duration() {
    let c = cfg_of("DEBUG=yes\nOFF=false\nTIMEOUT=30s\n");
    assert(bool_or(c, "DEBUG", false));
    assert(!bool_or(c, "OFF", true));
    assert(bool_or(c, "MISSING", true));
    assert(duration_or(c, "TIMEOUT", 0) == 30000000000);
    assert(duration_or(c, "MISSING", 5) == 5);
}

fn test_every_problem_is_reported_at_once() {
    let c = cfg_of("PORT=0\nMODE=staging\n");
    require(c, "SERVICE_NAME");
    require_port(c, "PORT");
    require_dsn(c, "DATABASE_URL");
    require_email(c, "ALERT_FROM");
    require_one_of(c, "MODE", ["dev", "prod"]);
    assert(len(problems(c)) == 5);
    assert(!is_valid(c));
    let r = check(c);
    guard let _ok = r else let e = err_of(r) {
        assert(says(e, "SERVICE_NAME is required but not set"));
        assert(says(e, "PORT must be a TCP port (1-65535)"));
        assert(says(e, "DATABASE_URL is required but not set"));
        assert(says(e, "ALERT_FROM is required but not set"));
        assert(says(e, "MODE must be one of: dev, prod"));
        return;
    }
    panic("expected the configuration to be rejected");
}

fn test_valid_config_passes() {
    let c = cfg_of("SERVICE_NAME=api\nPORT=8080\nDATABASE_URL=postgres://h/db\nALERT_FROM=ops@example.com\nMODE=prod\n");
    assert(require(c, "SERVICE_NAME") == "api");
    assert(require_port(c, "PORT") == 8080);
    assert(require_dsn(c, "DATABASE_URL") == "postgres://h/db");
    assert(require_email(c, "ALERT_FROM") == "ops@example.com");
    assert(require_one_of(c, "MODE", ["dev", "prod"]) == "prod");
    assert(is_valid(c));
    guard let _ok = check(c) else {
        panic("expected the configuration to be accepted");
    }
}

fn test_secrets_are_masked_in_the_report() {
    let c = cfg_of("DATABASE_URL=not-a-dsn\nSERVICE_NAME=\n");
    require_dsn(c, "DATABASE_URL");
    require(c, "SERVICE_NAME");
    let r = check(c);
    guard let _ok = r else let e = err_of(r) {
        assert(!says(e, "not-a-dsn"));
        assert(says(e, "characters, hidden"));
        return;
    }
    panic("expected problems");
}

fn test_optional_values_still_have_to_be_valid() {
    let c = cfg_of("WEBHOOK_URL=ftp://x\n");
    assert(optional_url(c, "WEBHOOK_URL", "") == "ftp://x");
    assert(len(problems(c)) == 1);
    let c2 = cfg_of("");
    assert(optional_url(c2, "WEBHOOK_URL", "none") == "none");
    assert(is_valid(c2));
}

fn test_missing_file_is_not_an_error() {
    let c = load_config_from("/nonexistent/path/.env");
    assert(is_valid(c));
    assert(c.source == "");
    assert(str_or(c, "ANYTHING", "d") == "d");
}

fn says(hay: str, needle: str) -> bool {
    let a = to_bytes(hay);
    let b = to_bytes(needle);
    let n = len(a);
    let m = len(b);
    if m == 0 || m > n {
        return false;
    }
    let i = 0;
    while i + m <= n {
        let j = 0;
        while j < m && a[i + j] == b[j] {
            j = j + 1;
        }
        if j == m {
            return true;
        }
        i = i + 1;
    }
    return false;
}
