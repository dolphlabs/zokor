import "internal/envfile";

fn cfg_of(text: str) -> Config {
    let cfg = config_from_values(envfile.parse(text));
    cfg.source = ".env";
    return cfg;
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

fn config_test_restore_env(key: str, prior: opt[str]) {
    if let value = prior { os.setenv(key, value); } else { os.unsetenv(key); }
}

fn test_config_environment_is_a_startup_snapshot() {
    let key = "ZOKOR_TEST_CONFIG_SNAPSHOT";
    let prior = proc.getenv(key);
    os.setenv(key, "before");
    let cfg = load_config_from("");
    os.setenv(key, "after");
    let value = str_or(cfg, key, "missing");
    config_test_restore_env(key, prior);
    assert(value == "before", "loaded configuration changed after the environment changed: " + value);
}

fn config_test_options(profile: str) -> ConfigLoad {
    let options = config_load();
    options.directory = "testdata/config-profiles";
    options.profile = profile;
    return options;
}

fn test_config_profile_files_overlay_base_for_each_profile() {
    let key = "ZOKOR_TEST_PROFILE_VALUE";
    let prior = proc.getenv(key);
    os.unsetenv(key);
    for profile in ["dev", "test", "prod"] {
        let cfg = load_config_with(config_test_options(profile));
        let checked_ = check(cfg);
        guard let _valid = checked_ else let e = err_of(checked_) { panic(e); }
        assert(cfg.profile == profile && str_or(cfg, key, "missing") == profile);
        assert(str_or(cfg, "ZOKOR_TEST_PROFILE_BASE", "missing") == "present");
        assert(len(cfg.sources) == 2 && cfg.source == "testdata/config-profiles/.env." + profile);
        assert(cfg.sources[0] == "testdata/config-profiles/.env");
    }
    config_test_restore_env(key, prior);
}

fn test_config_environment_wins_including_empty_values_and_explicit_profile_wins() {
    let selector = proc.getenv("ZOKOR_PROFILE");
    let override = proc.getenv("ZOKOR_TEST_PROFILE_OVERRIDE");
    os.setenv("ZOKOR_PROFILE", "prod");
    os.setenv("ZOKOR_TEST_PROFILE_OVERRIDE", "environment");
    let cfg = load_config_with(config_test_options("test"));
    let chosen = cfg.profile;
    let before = str_or(cfg, "ZOKOR_TEST_PROFILE_OVERRIDE", "missing");
    os.setenv("ZOKOR_TEST_PROFILE_OVERRIDE", "");
    let empty = load_config_with(config_test_options("test"));
    let empty_value = str_or(empty, "ZOKOR_TEST_PROFILE_OVERRIDE", "missing");
    let held = str_or(cfg, "ZOKOR_TEST_PROFILE_OVERRIDE", "missing");
    config_test_restore_env("ZOKOR_PROFILE", selector);
    config_test_restore_env("ZOKOR_TEST_PROFILE_OVERRIDE", override);
    assert(chosen == "test" && before == "environment" && held == before);
    assert(has_key(empty, "ZOKOR_TEST_PROFILE_OVERRIDE") && empty_value == "");
}

fn test_config_automatic_profile_uses_startup_selector() {
    let selector = proc.getenv("ZOKOR_PROFILE");
    let value = proc.getenv("ZOKOR_TEST_PROFILE_VALUE");
    os.unsetenv("ZOKOR_TEST_PROFILE_VALUE");
    os.setenv("ZOKOR_PROFILE", "test");
    let options = config_test_options("");
    let cfg = load_config_with(options);
    os.setenv("ZOKOR_PROFILE", "prod");
    let held = cfg.profile;
    let held_value = str_or(cfg, "ZOKOR_TEST_PROFILE_VALUE", "missing");
    config_test_restore_env("ZOKOR_PROFILE", selector);
    config_test_restore_env("ZOKOR_TEST_PROFILE_VALUE", value);
    assert(held == "test" && held_value == "test");
}

fn test_config_profile_defaults_to_dev_without_selector() {
    let selector = proc.getenv("ZOKOR_PROFILE");
    let value = proc.getenv("ZOKOR_TEST_PROFILE_VALUE");
    os.unsetenv("ZOKOR_PROFILE"); os.unsetenv("ZOKOR_TEST_PROFILE_VALUE");
    let cfg = load_config_with(config_test_options(""));
    config_test_restore_env("ZOKOR_PROFILE", selector);
    config_test_restore_env("ZOKOR_TEST_PROFILE_VALUE", value);
    assert(cfg.profile == "dev" && str_or(cfg, "ZOKOR_TEST_PROFILE_VALUE", "missing") == "dev");
}

fn test_config_profile_rejects_traversal_and_collects_all_load_options() {
    let options = config_test_options("../prod");
    options.directory = "";
    options.max_file_bytes = 0;
    let cfg = load_config_with(options);
    let checked_ = check(cfg);
    guard let _ok = checked_ else let e = err_of(checked_) {
        assert(len(cfg.problems) == 3 && says(e, "ZOKOR_PROFILE") && says(e, "directory") && says(e, "max_file_bytes"));
        assert(cfg.profile == "" && len(cfg.sources) == 0);
        return;
    }
    panic("invalid options accepted");
}

fn test_config_load_errors_collect_each_file_and_required_fields() {
    let options = config_test_options("test");
    options.max_file_bytes = 1;
    let cfg = load_config_with(options);
    require(cfg, "ZOKOR_TEST_CONFIG_MISSING_REQUIRED");
    let checked_ = check(cfg);
    guard let _ok = checked_ else let e = err_of(checked_) {
        assert(len(cfg.problems) == 3 && says(e, "testdata/config-profiles/.env exceeds max_file_bytes") && says(e, "testdata/config-profiles/.env.test exceeds max_file_bytes"));
        assert(says(e, "ZOKOR_TEST_CONFIG_MISSING_REQUIRED is required"));
        return;
    }
    panic("loading failures were discarded");
}

fn test_config_single_file_and_pure_values_do_not_select_profiles() {
    let selector = proc.getenv("ZOKOR_PROFILE");
    let value = proc.getenv("ZOKOR_TEST_PROFILE_VALUE");
    os.setenv("ZOKOR_PROFILE", "prod"); os.unsetenv("ZOKOR_TEST_PROFILE_VALUE");
    let cfg = load_config_from("testdata/config-profiles/.env.test");
    let pure_values: map[str]str = { "NAME": "owned" };
    let pure = config_from_values(pure_values);
    pure_values["NAME"] = "changed";
    config_test_restore_env("ZOKOR_PROFILE", selector);
    config_test_restore_env("ZOKOR_TEST_PROFILE_VALUE", value);
    assert(cfg.profile == "" && len(cfg.sources) == 1 && str_or(cfg, "ZOKOR_TEST_PROFILE_VALUE", "missing") == "test");
    assert(str_or(pure, "NAME", "missing") == "owned" && len(pure.values) == 1 && pure.profile == "");
}

fn test_config_file_refuses_non_regular_and_nul_inputs() {
    let dir = load_config_file("testdata/config-profiles", 1024);
    let nul = load_config_file("testdata/migrations-nul/1_nul.sql", 1024);
    assert(len(dir.problems) == 1 && says(dir.problems[0].reason, "regular file"));
    assert(len(nul.problems) == 1 && says(nul.problems[0].reason, "NUL"));
    assert(dir.problems[0].shown == "" && nul.problems[0].shown == "");
}

fn test_config_base_file_can_select_profile_but_environment_wins() {
    let selector = proc.getenv("ZOKOR_PROFILE");
    let value = proc.getenv("ZOKOR_TEST_PROFILE_VALUE");
    os.unsetenv("ZOKOR_PROFILE"); os.unsetenv("ZOKOR_TEST_PROFILE_VALUE");
    let options = config_load();
    options.directory = "testdata/config-selected";
    let selected = load_config_with(options);
    os.setenv("ZOKOR_PROFILE", "prod");
    let overridden = load_config_with(options);
    config_test_restore_env("ZOKOR_PROFILE", selector);
    config_test_restore_env("ZOKOR_TEST_PROFILE_VALUE", value);
    assert(selected.profile == "test" && str_or(selected, "ZOKOR_TEST_PROFILE_VALUE", "missing") == "selected");
    assert(overridden.profile == "prod" && str_or(overridden, "ZOKOR_TEST_PROFILE_VALUE", "missing") == "base");
    assert(len(overridden.sources) == 1, "missing profile files are optional");
}
