import "http";
import "strings";
import "time";

fn lt_req(route: str, raw_path: str, status: int) -> LogEvent {
    let ev = request_event("GET", route, raw_path, status, 412000, 28,
                           "req_854dcb44626ad7d4b3184491243e922d", "10.0.0.4");
    ev.time = 1760293621123000000;
    return ev;
}

fn test_parse_level_accepts_the_documented_names() {
    assert(level_name(parse_level("debug") ?? LogLevel.OFF) == "debug");
    assert(level_name(parse_level("LOG") ?? LogLevel.OFF) == "log");
    assert(level_name(parse_level("info") ?? LogLevel.OFF) == "log");
    assert(level_name(parse_level(" warn ") ?? LogLevel.OFF) == "warn");
    assert(level_name(parse_level("error") ?? LogLevel.OFF) == "error");
    assert(level_name(parse_level("off") ?? LogLevel.DEBUG) == "off");
    guard let _l = parse_level("verbose") else {
        return;
    }
    assert(false, "verbose is not a level");
}

fn test_utc_stamps_match_the_calendar() {
    let f = new_log_format(1);
    assert(f.stamp(0, true) == "1970-01-01T00:00:00.000Z", f.stamp(0, true));
    assert(f.stamp(1760293621123000000, true) == "2025-10-12T18:27:01.123Z");
    assert(f.stamp(1760293621123000000, false) == "2025-10-12 18:27:01.123Z");
    // a leap day, and nanoseconds below a millisecond dropped
    assert(f.stamp(1709208000123456789, true) == "2024-02-29T12:00:00.123Z");
    // before the epoch rounds down, not toward zero
    let p = utc_parts(-1000000);
    assert(p[0] == 1969 && p[1] == 12 && p[2] == 31 && p[3] == 23 &&
           p[4] == 59 && p[5] == 59 && p[6] == 999);
}

fn test_a_cached_second_does_not_leak_into_the_next() {
    let f = new_log_format(1);
    assert(f.stamp(1760293621999000000, true) == "2025-10-12T18:27:01.999Z");
    assert(f.stamp(1760293622000000000, true) == "2025-10-12T18:27:02.000Z");
    assert(f.stamp(1760293621500000000, true) == "2025-10-12T18:27:01.500Z");
}

fn test_safe_path_drops_the_query_and_escapes_what_could_forge_a_line() {
    assert(safe_path("/users/42") == "/users/42");
    assert(safe_path("/search?token=secret") == "/search");
    assert(safe_path("/a\nb") == "/a%0ab", safe_path("/a\nb"));
    assert(safe_path("/q\"x\\y") == "/q%22x%5cy", safe_path("/q\"x\\y"));
    let esc = to_str(b"/\x1b[31mred");
    assert(safe_path(esc) == "/%1b[31mred", safe_path(esc));
    let long = "/" + strings.repeat("a", 100);
    let s = safe_path(long);
    assert(len(s) == 67 && strings.has_suffix(s, "..."), s);
}

fn test_request_level_follows_the_status() {
    assert(level_name(lt_req("/x", "/x", 200).level) == "log");
    assert(level_name(lt_req("/x", "/x", 404).level) == "warn");
    assert(level_name(lt_req("/x", "/x", 503).level) == "error");
}

fn test_json_request_line() {
    let f = new_log_format(4242);
    let got = f.json(lt_req("/users/:id", "/users/42?token=secret", 200));
    let want = "{\"time\":\"2025-10-12T18:27:01.123Z\",\"level\":\"log\",\"pid\":4242," +
               "\"context\":\"HTTP\",\"msg\":\"GET /users/:id 200 28B 10.0.0.4 " +
               "req_854dcb44626ad7d4b3184491243e922d\",\"method\":\"GET\"," +
               "\"route\":\"/users/:id\",\"status\":200,\"duration_ms\":0.412," +
               "\"bytes\":28,\"request_id\":\"req_854dcb44626ad7d4b3184491243e922d\"," +
               "\"client_ip\":\"10.0.0.4\"}";
    assert(got == want, got);
    assert(!strings.contains(got, "token"), "a query string reached the log");
    assert(!strings.contains(got, "/users/42"), "a matched request logs its pattern, not its path");
}

fn test_json_unmatched_request_logs_the_safe_path() {
    let f = new_log_format(1);
    let got = f.json(lt_req("", "/nope\r\nFAKE: line?x=1", 404));
    assert(strings.contains(got, "\"route\":\"\",\"path\":\"/nope%0d%0aFAKE: line\""), got);
    assert(strings.contains(got, "\"msg\":\"GET /nope%0d%0aFAKE: line 404 "), got);
    assert(!strings.contains(got, "\n"), "one record, one line");
}

fn test_json_quotes_a_route_that_needs_it() {
    let f = new_log_format(1);
    let got = f.json(lt_req("/odd\"route", "/odd", 200));
    assert(strings.contains(got, "\"route\":\"/odd\\\"route\""), got);
    assert(strings.contains(got, "\"msg\":\"GET (route) 200"), got);
}

fn test_json_message_line_escapes_the_message() {
    let f = new_log_format(1);
    let ev = request_event("GET", "", "", 0, 0, 0, "", "");
    ev.request = false;
    ev.context = "Server";
    ev.message = "said \"hi\"\nthen left";
    ev.time = 0;
    ev.level = LogLevel.WARN;
    assert(f.json(ev) == "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"warn\",\"pid\":1," +
           "\"context\":\"Server\",\"msg\":\"said \\\"hi\\\"\\nthen left\"}", f.json(ev));
}

fn test_pretty_request_line_without_colour() {
    let f = new_log_format(4242);
    let got = f.pretty(lt_req("/users/:id", "/users/42", 200), false, 0);
    assert(got == "[zokor] 4242  - 2025-10-12 18:27:01.123Z     LOG [HTTP] GET /users/:id 200 28B " +
                  "10.0.0.4 req_854dcb44626ad7d4b3184491243e922d +0.41ms", got);
}

fn test_pretty_colours_only_when_asked() {
    let f = new_log_format(1);
    let esc = to_str(b"\x1b[");
    assert(!strings.contains(f.pretty(lt_req("/x", "/x", 500), false, 0), esc));
    let c = f.pretty(lt_req("/x", "/x", 500), true, 0);
    assert(strings.contains(c, to_str(b"\x1b[31m")), "an error is red");
    assert(strings.contains(c, "  ERROR"));
}

fn test_pretty_slow_requests_read_in_seconds() {
    let f = new_log_format(1);
    let ev = lt_req("/x", "/x", 200);
    ev.duration_ns = 1250000000;
    assert(strings.has_suffix(f.pretty(ev, false, 0), " +1.25s"), f.pretty(ev, false, 0));
}

fn test_no_logger_logs_nothing() {
    let lg = no_logger();
    assert(!lg.enabled(LogLevel.ERROR));
    lg.error("Server", "nobody hears this");
    lg.record_request("GET", "/x", "/x", 500, 1, 1, "", "");
    assert(lg.take_dropped() == 0);
    assert(lg.own_tasks() == 0);
}

fn lt_recv(ch: chan[LogEvent]) -> LogEvent {
    let r = chan_recv(ch);
    guard let ev = r else {
        panic("channel closed");
    }
    return ev;
}

fn test_channel_logger_hands_records_to_its_owner() {
    let ch: chan[LogEvent] = make_chan(8);
    let lg = channel_logger(ch, LogLevel.LOG, true);
    lg.record_request("POST", "/orgs", "/orgs", 201, 5000, 12, "req_1", "10.0.0.4");
    let ev = lt_recv(ch);
    assert(ev.request && ev.method == "POST" && ev.route == "/orgs" && ev.status == 201);
    assert(ev.size == 12 && ev.request_id == "req_1" && ev.client_ip == "10.0.0.4");
    lg.warn("Billing", "card declined");
    let w = lt_recv(ch);
    assert(!w.request && w.context == "Billing" && w.message == "card declined");
    assert(level_name(w.level) == "warn");
    assert(lg.own_tasks() == 0, "the owner drains a channel_logger, not zokor");
}

fn test_level_and_request_switches_filter_before_sending() {
    let ch: chan[LogEvent] = make_chan(8);
    let lg = channel_logger(ch, LogLevel.WARN, true);
    lg.record_request("GET", "/ok", "/ok", 200, 1, 1, "", "");
    lg.log("Server", "chatter");
    lg.record_request("GET", "", "/gone", 404, 1, 1, "", "");
    let ev = lt_recv(ch);
    assert(ev.status == 404, "only the 404 passes LOG_LEVEL=warn");

    let quiet = channel_logger(ch, LogLevel.LOG, false);
    quiet.record_request("GET", "", "/gone", 500, 1, 1, "", "");
    quiet.log("Server", "still here");
    let s = lt_recv(ch);
    assert(!s.request && s.message == "still here", "LOG_REQUESTS=false keeps the server's lines");
}

fn test_a_full_queue_drops_and_counts_instead_of_waiting() {
    let ch: chan[LogEvent] = make_chan(1);
    let lg = channel_logger(ch, LogLevel.LOG, true);
    let t0 = time.mono();
    let i = 0;
    while i < 5 {
        lg.record_request("GET", "/x", "/x", 200, 1, 1, "", "");
        i = i + 1;
    }
    assert(((time.mono() - t0) as int) < 100000000, "emit must never block");
    assert(lg.take_dropped() == 4);
    assert(lg.take_dropped() == 0, "taking the count resets it");
}

fn test_logger_from_reads_the_settings() {
    let c = cfg_of("LOG_FORMAT=json\nLOG_LEVEL=warn\nLOG_REQUESTS=false\n");
    let lg = logger_from(c);
    assert(lg.json && !lg.color);
    assert(level_name(lg.level) == "warn");
    assert(!lg.requests);
    assert(lg.console);
    guard let _ok = check(c) else {
        panic("valid settings reported as a problem");
    }
}

fn test_logger_from_reports_every_bad_setting() {
    let c = cfg_of("LOG_FORMAT=xml\nLOG_LEVEL=loud\nLOG_REQUESTS=maybe\n");
    let _lg = logger_from(c);
    let r = check(c);
    guard let _ok = r else let e = err_of(r) {
        assert(strings.contains(e, "LOG_FORMAT"), e);
        assert(strings.contains(e, "LOG_LEVEL"), e);
        assert(strings.contains(e, "LOG_REQUESTS"), e);
        return;
    }
    panic("bad log settings were not reported");
}

fn test_server_config_from_carries_the_logger() {
    let sc = server_config_from(cfg_of("LOG_LEVEL=off\n"));
    assert(level_name(sc.logger.level) == "off");
    sc.logger.start();
    assert(sc.logger.own_tasks() == 0, "LOG_LEVEL=off starts no writer");
}

fn test_console_logger_starts_once_and_flushes() {
    let lg = console_logger(true, false, LogLevel.ERROR, true);
    assert(lg.own_tasks() == 0, "not started until listen");
    lg.start();
    lg.start();
    assert(lg.own_tasks() == 1);
    let t0 = time.mono();
    lg.flush(2000000000);
    assert(((time.mono() - t0) as int) < 1000000000, "flush waited for its own timeout");
}
