import "strings";
import "timez";

gc struct JState {
    seen: [str],
    lock: mutex,
    gate: chan[int],
    fail_until: int,
}

fn js_state() -> JState {
    let seen: [str] = [];
    let g: chan[int] = make_chan(16);
    return JState { seen: seen, lock: make_mutex(), gate: g, fail_until: 0 };
}

fn js_note(s: JState, what: str) {
    mutex_lock(s.lock);
    push(s.seen, what);
    mutex_unlock(s.lock);
}

fn js_seen(s: JState) -> [str] {
    mutex_lock(s.lock);
    let out: [str] = [];
    for x in s.seen {
        push(out, x);
    }
    mutex_unlock(s.lock);
    return out;
}

fn js_record(c: JobCtx[JState]) -> result[int, str] {
    js_note(c.state, c.name + "@" + c.due.rfc3339());
    return ok(0);
}

// Blocks until the test sends on the gate: a run that is still going.
fn js_slow(c: JobCtx[JState]) -> result[int, str] {
    js_note(c.state, "slow start");
    let _g = chan_recv(c.state.gate);
    js_note(c.state, "slow end");
    return ok(0);
}

fn js_panics(c: JobCtx[JState]) -> result[int, str] {
    js_note(c.state, "panicking");
    let empty: [int] = [];
    return ok(empty[3]);
}

// Fails until attempt `fail_until`, then succeeds.
fn js_flaky(c: JobCtx[JState]) -> result[int, str] {
    js_note(c.state, c.payload + " try " + to_str(c.attempt));
    if c.attempt < c.state.fail_until {
        return err("smtp 451 try later");
    }
    return ok(0);
}

fn js_at(s: str) -> timez.Time {
    let r = timez.parse_rfc3339(s);
    guard let t = r else let e = err_of(r) {
        panic(e);
    }
    return t;
}

fn js_jobs(s: JState, start: str) -> Jobs[JState] {
    let j = new_jobs(s);
    j.clock = timez.fixed_clock(js_at(start));
    return j;
}

fn test_a_scheduled_job_runs_at_its_turns_only() {
    let s = js_state();
    let j = js_jobs(s, "2026-10-13T09:58:00Z");
    assert(is_ok_int(j.every("report", "*/5 * * * *", js_record, timez.SECOND)));
    // the first tick only learns the next turn: nothing already past runs
    assert(j.tick(js_at("2026-10-13T09:58:00Z")) == 0);
    assert(j.tick(js_at("2026-10-13T09:59:59Z")) == 0);
    assert(j.tick(js_at("2026-10-13T10:00:00Z")) == 1);
    assert(j.wait_runs(timez.SECOND));
    assert(j.tick(js_at("2026-10-13T10:00:30Z")) == 0);
    // a server that was down for two turns runs once, not three times
    assert(j.tick(js_at("2026-10-13T10:12:00Z")) == 1);
    assert(j.wait_runs(timez.SECOND));
    let seen = js_seen(s);
    assert(len(seen) == 2, strings.join(seen, ", "));
    assert(seen[0] == "report@2026-10-13T10:00:00Z");
    assert(seen[1] == "report@2026-10-13T10:05:00Z");
}

fn test_turns_are_read_on_the_zone_clocks() {
    let s = js_state();
    let j = js_jobs(s, "2026-07-01T00:00:00Z");
    let zr = timez.load_zone("Europe/Berlin");
    guard let berlin = zr else {
        return;   // no tz database on this machine: covered by timez's own tests
    }
    j.zone = berlin;
    assert(is_ok_int(j.every("morning", "0 9 * * *", js_record, timez.SECOND)));
    j.tick(js_at("2026-07-01T00:00:00Z"));
    // 09:00 in Berlin in July is 07:00 UTC
    assert(j.tick(js_at("2026-07-01T06:59:59Z")) == 0);
    assert(j.tick(js_at("2026-07-01T07:00:00Z")) == 1);
    assert(j.wait_runs(timez.SECOND));
    assert(js_seen(s)[0] == "morning@2026-07-01T07:00:00Z");
}

fn test_a_job_still_running_skips_its_next_turn() {
    let s = js_state();
    let j = js_jobs(s, "2026-10-13T10:00:00Z");
    assert(is_ok_int(j.every("slow", "* * * * *", js_slow, timez.MINUTE)));
    j.tick(js_at("2026-10-13T10:00:00Z"));
    assert(j.tick(js_at("2026-10-13T10:01:00Z")) == 1);
    assert(j.tick(js_at("2026-10-13T10:02:00Z")) == 0);   // still running: skipped
    assert(j.running() == 1);
    chan_send(s.gate, 1);
    assert(j.wait_runs(timez.SECOND));
    assert(j.tick(js_at("2026-10-13T10:03:00Z")) == 1);
    chan_send(s.gate, 1);
    assert(j.wait_runs(timez.SECOND));
}

fn test_a_panicking_run_is_only_that_run() {
    let s = js_state();
    let j = js_jobs(s, "2026-10-13T10:00:00Z");
    assert(is_ok_int(j.every("bad", "* * * * *", js_panics, timez.SECOND)));
    assert(is_ok_int(j.every("good", "* * * * *", js_record, timez.SECOND)));
    j.tick(js_at("2026-10-13T10:00:00Z"));
    assert(j.tick(js_at("2026-10-13T10:01:00Z")) == 2);
    assert(j.wait_runs(timez.SECOND));
    assert(j.failures == 1);
    // the panicking job is scheduled again, and the scheduler still works
    assert(j.tick(js_at("2026-10-13T10:02:00Z")) == 2);
    assert(j.wait_runs(timez.SECOND));
    assert(j.failures == 2);
}

fn test_a_queued_job_retries_with_backoff_then_succeeds() {
    let s = js_state();
    s.fail_until = 3;
    let j = js_jobs(s, "2026-10-13T10:00:00Z");
    assert(is_ok_int(j.handle("email", js_flaky, 5)));
    assert(is_ok_int(j.enqueue("email", "user-7", js_at("2026-10-13T10:00:00Z"))));
    assert(j.tick(js_at("2026-10-13T10:00:00Z")) == 1);
    assert(j.wait_runs(timez.SECOND));
    // try 1 failed: back in the queue 1 s after the clock's now
    assert(j.queued() == 1);
    assert(j.tick(js_at("2026-10-13T10:00:00.5Z")) == 0);
    assert(j.tick(js_at("2026-10-13T10:00:01Z")) == 1);
    assert(j.wait_runs(timez.SECOND));
    assert(j.tick(js_at("2026-10-13T10:00:02Z")) == 1);
    assert(j.wait_runs(timez.SECOND));
    assert(j.queued() == 0);
    let seen = js_seen(s);
    assert(strings.join(seen, ",") == "user-7 try 1,user-7 try 2,user-7 try 3",
           strings.join(seen, ","));
}

fn test_a_queued_job_out_of_attempts_is_dropped() {
    let s = js_state();
    s.fail_until = 99;
    let j = js_jobs(s, "2026-10-13T10:00:00Z");
    assert(is_ok_int(j.handle("email", js_flaky, 2)));
    assert(is_ok_int(j.enqueue("email", "user-9", js_at("2026-10-13T09:00:00Z"))));
    assert(j.tick(js_at("2026-10-13T10:00:00Z")) == 1);
    assert(j.wait_runs(timez.SECOND));
    assert(j.tick(js_at("2026-10-13T10:00:01Z")) == 1);
    assert(j.wait_runs(timez.SECOND));
    assert(j.queued() == 0);
    assert(j.failures == 2);
}

fn test_backoff_doubles_to_an_hour() {
    assert(job_backoff(1) == timez.SECOND);
    assert(job_backoff(2) == 2 * timez.SECOND);
    assert(job_backoff(5) == 16 * timez.SECOND);
    assert(job_backoff(40) == timez.HOUR);
}

fn test_mistakes_are_refused_with_the_fix() {
    let j = js_jobs(js_state(), "2026-10-13T10:00:00Z");
    let r1 = j.every("x", "61 * * * *", js_record, timez.SECOND);
    assert(strings.contains(err_or_empty(r1), "job x: cron"), err_or_empty(r1));
    assert(is_ok_int(j.every("x", "* * * * *", js_record, timez.SECOND)));
    assert(strings.contains(err_or_empty(j.every("x", "* * * * *", js_record, timez.SECOND)),
                            "already scheduled"));
    assert(strings.contains(err_or_empty(j.every("", "* * * * *", js_record, timez.SECOND)),
                            "needs a name"));
    assert(strings.contains(err_or_empty(j.every("y", "* * * * *", js_record, 10)),
                            "at least 1ms"));
    assert(strings.contains(err_or_empty(j.enqueue("nope", "", timez.now())),
                            "register it with handle()"));
    assert(strings.contains(err_or_empty(j.handle("k", js_flaky, 0)), "at least 1"));
}

fn test_a_stopped_scheduler_starts_nothing() {
    let s = js_state();
    let j = js_jobs(s, "2026-10-13T10:00:00Z");
    assert(is_ok_int(j.every("r", "* * * * *", js_record, timez.SECOND)));
    j.tick(js_at("2026-10-13T10:00:00Z"));
    j.stop();
    assert(j.tick(js_at("2026-10-13T10:05:00Z")) == 0);
}

fn test_the_scheduler_loop_runs_queued_work() {
    let s = js_state();
    let j = new_jobs(s);
    assert(is_ok_int(j.handle("email", js_flaky, 1)));
    assert(is_ok_int(j.enqueue("email", "live", timez.now())));
    j.start();
    let i = 0;
    while j.queued() > 0 && i < 200 {
        time_sleep_ms(5);
        i = i + 1;
    }
    assert(j.wait_runs(timez.SECOND));
    j.stop();
    assert(js_seen(s)[0] == "live try 1");
}

fn is_ok_int(r: result[int, str]) -> bool {
    if let _v = r {
        return true;
    }
    return false;
}

fn err_or_empty(r: result[int, str]) -> str {
    guard let _v = r else let e = err_of(r) {
        return e;
    }
    return "";
}

fn time_sleep_ms(ms: int) {
    time.sleep(ms * 1000000);
}
