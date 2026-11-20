import "pg";
import "proc";
import "strings";
import "time";
import "timez";

fn jd_dl() -> until {
    return until_of(time.mono() + 5000000000);
}

// The live database with an empty queue table, or none when there is no
// database: these tests then say so and pass, like postgres_test.
fn jd_live(test: str) -> opt[pg.Pool] {
    let url = proc.getenv("ZOKOR_TEST_DATABASE_URL") ?? "";
    if len(url) == 0 {
        println("skip " + test + " (ZOKOR_TEST_DATABASE_URL is not set)");
        return none;
    }
    let pr = pg_from_config(cfg_of("DATABASE_URL=" + url + "\nDB_POOL_SIZE=8\n"));
    guard let p = pr else let e = err_of(pr) {
        println("skip " + test + " (" + e + ")");
        return none;
    }
    let dropped = pg.pool_exec(p, "drop table if exists zokor_jobs; drop table if exists zokor_job_turns", jd_dl());
    guard let _d = dropped else let e = err_of(dropped) {
        println("skip " + test + " (" + e + ")");
        return none;
    }
    assert((pg.pool_exec(p, jobs_schema(), jd_dl()) ?? -1) >= 0);
    return some(p);
}

fn jd_jobs(p: pg.Pool, s: JState) -> Jobs[JState] {
    let j = new_jobs(s);
    assert((j.durable(p) ?? -1) == 0);
    return j;
}

struct JdRow {
    attempt: int,
    dead: bool,
    last_error: opt[str],
}

fn jd_row(p: pg.Pool, id: int) -> opt[JdRow] {
    let r: result[opt[JdRow], str] = query_one(p,
        "select attempt, dead_at is not null as dead, last_error from zokor_jobs where id = $1",
        [pg.arg_int(id)], jd_dl());
    guard let row = r else let e = err_of(r) {
        println("jd_row: " + e);
        assert(false);
        return none;
    }
    return row;
}

// As if the backoff, or a crashed worker's lease, had run out.
fn jd_make_due(p: pg.Pool) {
    assert((pg.pool_exec(p, "update zokor_jobs set run_at = now() - interval '1 second'," +
                            " locked_until = case when locked_until is null then null" +
                            " else now() - interval '1 second' end", jd_dl()) ?? -1) >= 0);
}

fn jd_note_id(c: JobCtx[JState]) -> result[int, str] {
    js_note(c.state, c.payload + " #" + to_str(c.job_id) + " try " + to_str(c.attempt));
    return ok(0);
}

struct JdNew {
    payload: str,
    fail: bool,
}

fn jd_tx_body(c: pg.Conn, n: JdNew) -> result[int, str] {
    let r = enqueue_tx(c, "mail", n.payload, timez.now(), jd_dl());
    guard let _id = r else let e = err_of(r) {
        return err(e);
    }
    if n.fail {
        return err("the write it belongs to failed");
    }
    return ok(1);
}

fn test_durable_refuses_a_missing_table_and_names_the_fix() {
    guard let p = jd_live("test_durable_refuses_a_missing_table_and_names_the_fix") else { return; }
    assert((pg.pool_exec(p, "drop table zokor_jobs; drop table zokor_job_turns", jd_dl()) ?? -1) >= 0);
    let j = new_jobs(js_state());
    let r = j.durable(p);
    guard let _x = r else let e = err_of(r) {
        assert(contains(e, "zokor.jobs_schema()"));
        pg_close(p);
        return;
    }
    assert(false);
}

fn test_jobs_schema_applies_as_a_migration() {
    guard let p = jd_live("test_jobs_schema_applies_as_a_migration") else { return; }
    assert((pg.pool_exec(p, "drop table zokor_jobs; drop table zokor_job_turns; drop table if exists zokor_schema_migrations",
                         jd_dl()) ?? -1) >= 0);
    let r = migrate(p, [new_migration(1, "1_zokor_jobs.sql", jobs_schema())], jd_dl());
    guard let n = r else let e = err_of(r) {
        println(e);
        assert(false);
        return;
    }
    assert(n == 1);
    assert((pg.pool_exec(p, "drop table zokor_schema_migrations", jd_dl()) ?? -1) >= 0);
    pg_close(p);
}

// The whole point: a new process with nothing in memory finds the job.
fn test_durable_job_survives_a_restart() {
    guard let p = jd_live("test_durable_job_survives_a_restart") else { return; }
    let s1 = js_state();
    let first = jd_jobs(p, s1);
    assert((first.handle("mail", jd_note_id, 3) ?? 0) == 1);
    let id = first.enqueue("mail", "ada", timez.now()) ?? 0;
    assert(id > 0);
    assert(first.queued() == 0);

    let s2 = js_state();
    let second = jd_jobs(p, s2);
    assert((second.handle("mail", jd_note_id, 3) ?? 0) == 1);
    assert((second.poll() ?? -1) == 1);
    assert(second.wait_runs(5000000000));
    assert(js_seen(s2)[0] == "ada #" + to_str(id) + " try 1");
    assert((second.pending(jd_dl()) ?? -1) == 0);
    assert(len(js_seen(s1)) == 0);
    pg_close(p);
}

fn test_enqueue_tx_commits_and_rolls_back_with_the_transaction() {
    guard let p = jd_live("test_enqueue_tx_commits_and_rolls_back_with_the_transaction") else { return; }
    let j = jd_jobs(p, js_state());
    let kept = transaction(p, JdNew { payload: "kept", fail: false }, jd_tx_body, jd_dl());
    assert((kept ?? 0) == 1);
    let lost = transaction(p, JdNew { payload: "lost", fail: true }, jd_tx_body, jd_dl());
    guard let _l = lost else {
        let no_args: [pg.Arg] = [];
        let rows: result[[JdPayload], str] = query_all(p, "select payload from zokor_jobs", no_args, jd_dl());
        guard let list = rows else { assert(false); return; }
        assert(len(list) == 1 && list[0].payload == "kept");
        assert((j.pending(jd_dl()) ?? -1) == 1);
        pg_close(p);
        return;
    }
    assert(false);
}

struct JdPayload {
    payload: str,
}

fn test_durable_job_not_yet_due_is_left_alone() {
    guard let p = jd_live("test_durable_job_not_yet_due_is_left_alone") else { return; }
    let s = js_state();
    let j = jd_jobs(p, s);
    assert((j.handle("mail", jd_note_id, 3) ?? 0) == 1);
    assert((j.enqueue("mail", "later", timez.now().add(timez.HOUR)) ?? 0) > 0);
    assert((j.poll() ?? -1) == 0);
    assert((j.pending(jd_dl()) ?? -1) == 1);
    pg_close(p);
}

// Two workers, many jobs: each row goes to exactly one of them.
fn test_durable_workers_never_share_a_job() {
    guard let p = jd_live("test_durable_workers_never_share_a_job") else { return; }
    let s = js_state();
    let a = jd_jobs(p, s);
    let b = jd_jobs(p, s);
    a.max_running = 64;
    b.max_running = 64;
    assert((a.handle("mail", jd_note_id, 3) ?? 0) == 1);
    assert((b.handle("mail", jd_note_id, 3) ?? 0) == 1);
    let i = 0;
    while i < 40 {
        assert((a.enqueue("mail", "j" + to_str(i), timez.now()) ?? 0) > 0);
        i = i + 1;
    }
    let done: chan[int] = make_chan(2);
    spawn jd_poller(a, done);
    spawn jd_poller(b, done);
    let _x = chan_recv(done);
    let _y = chan_recv(done);
    assert(a.wait_runs(5000000000) && b.wait_runs(5000000000));
    let seen = js_seen(s);
    assert(len(seen) == 40);
    let once: map[str]bool = {};
    for w in seen {
        assert(!has(once, w));
        once[w] = true;
    }
    assert((a.pending(jd_dl()) ?? -1) == 0);
    pg_close(p);
}

// A row another worker has locked is skipped, not waited for: a queue
// where one slow claim stalls every worker is not a queue. Deterministic
// where racing two pollers is not.
fn test_durable_claim_skips_a_locked_row_without_waiting() {
    guard let p = jd_live("test_durable_claim_skips_a_locked_row_without_waiting") else { return; }
    let s = js_state();
    let j = jd_jobs(p, s);
    j.store_timeout = 1000 * timez.MILLISECOND;
    assert((j.handle("mail", jd_note_id, 3) ?? 0) == 1);
    let locked = j.enqueue("mail", "locked", timez.now().add(-timez.HOUR)) ?? 0;
    let free = j.enqueue("mail", "free", timez.now()) ?? 0;
    let cr = pg.acquire(p, jd_dl());
    guard let holder = cr else { assert(false); return; }
    assert((pg.exec(holder, "BEGIN", jd_dl()) ?? -1) >= 0);
    let held = pg.query(holder, "select id from zokor_jobs where id = $1 for update",
                        [pg.arg_int(locked)], jd_dl());
    guard let _h = held else { assert(false); return; }

    let r = j.poll();
    guard let n = r else let e = err_of(r) {
        println("poll blocked on the locked row: " + e);
        assert(false);
        return;
    }
    assert(n == 1);
    assert(j.wait_runs(5000000000));
    assert(js_seen(s)[0] == "free #" + to_str(free) + " try 1");
    assert((pg.exec(holder, "ROLLBACK", jd_dl()) ?? -1) >= 0);
    pg.release(p, holder);
    pg_close(p);
}

fn jd_poller(j: Jobs[JState], done: chan[int]) {
    let empty = 0;
    while empty < 5 {
        let n = j.poll() ?? 0;
        if n == 0 {
            empty = empty + 1;
            time.sleep(2000000);
        } else {
            empty = 0;
        }
    }
    chan_send(done, 1);
}

// A worker that claimed a job and died: the lease ends, another takes it.
fn test_durable_job_of_a_dead_worker_runs_again_after_its_lease() {
    guard let p = jd_live("test_durable_job_of_a_dead_worker_runs_again_after_its_lease") else { return; }
    let s = js_state();
    let dead = jd_jobs(p, s);
    assert((dead.handle("mail", js_slow, 3) ?? 0) == 1);
    let id = dead.enqueue("mail", "x", timez.now()) ?? 0;
    assert((dead.poll() ?? -1) == 1);

    let live_state = js_state();
    let live = jd_jobs(p, live_state);
    assert((live.handle("mail", jd_note_id, 3) ?? 0) == 1);
    assert((live.poll() ?? -1) == 0);          // leased: not yet
    jd_make_due(p);
    assert((live.poll() ?? -1) == 1);
    assert(live.wait_runs(5000000000));
    assert(js_seen(live_state)[0] == "x #" + to_str(id) + " try 2");

    // The first worker wakes up late: its success must not be believed
    // for a row that is someone else's. Here the row is already gone.
    chan_send(s.gate, 1);
    assert(dead.wait_runs(5000000000));
    pg_close(p);
}

// A late worker's outcome must not disturb the row's new holder.
fn test_durable_lost_lease_cannot_delete_the_new_holders_row() {
    guard let p = jd_live("test_durable_lost_lease_cannot_delete_the_new_holders_row") else { return; }
    let s = js_state();
    let late = jd_jobs(p, s);
    assert((late.handle("mail", js_slow, 3) ?? 0) == 1);
    let id = late.enqueue("mail", "x", timez.now()) ?? 0;
    assert((late.poll() ?? -1) == 1);

    let s2 = js_state();
    let holder = jd_jobs(p, s2);
    assert((holder.handle("mail", js_slow, 3) ?? 0) == 1);
    jd_make_due(p);
    assert((holder.poll() ?? -1) == 1);

    chan_send(s.gate, 1);
    assert(late.wait_runs(5000000000));
    guard let row = jd_row(p, id) else { assert(false); return; }
    assert(row.attempt == 2);

    chan_send(s2.gate, 1);
    assert(holder.wait_runs(5000000000));
    assert((holder.pending(jd_dl()) ?? -1) == 0);
    pg_close(p);
}

fn test_durable_failure_retries_with_backoff_then_goes_dead() {
    guard let p = jd_live("test_durable_failure_retries_with_backoff_then_goes_dead") else { return; }
    let s = js_state();
    s.fail_until = 99;
    let j = jd_jobs(p, s);
    assert((j.handle("mail", js_flaky, 2) ?? 0) == 1);
    let id = j.enqueue("mail", "x", timez.now()) ?? 0;

    assert((j.poll() ?? -1) == 1);
    assert(j.wait_runs(5000000000));
    guard let first = jd_row(p, id) else { assert(false); return; }
    assert(first.attempt == 1 && !first.dead);
    assert((first.last_error ?? "") == "smtp 451 try later");
    assert((j.poll() ?? -1) == 0);             // backing off

    jd_make_due(p);
    assert((j.poll() ?? -1) == 1);
    assert(j.wait_runs(5000000000));
    guard let last = jd_row(p, id) else { assert(false); return; }
    assert(last.attempt == 2 && last.dead);
    assert((j.dead(jd_dl()) ?? -1) == 1);
    assert((j.pending(jd_dl()) ?? -1) == 0);
    jd_make_due(p);
    assert((j.poll() ?? -1) == 0);             // dead stays dead
    assert(j.failures == 2);
    pg_close(p);
}

// A job that kills its process never reports, so the attempt must have
// been counted at the claim or it would crash the service forever.
fn test_durable_crash_loop_ends_in_dead_without_another_run() {
    guard let p = jd_live("test_durable_crash_loop_ends_in_dead_without_another_run") else { return; }
    let s = js_state();
    let j = jd_jobs(p, s);
    assert((j.handle("mail", jd_note_id, 2) ?? 0) == 1);
    let id = j.enqueue("mail", "x", timez.now()) ?? 0;
    assert((pg.pool_exec(p, "update zokor_jobs set attempt = 2, locked_by = 'gone'," +
                            " locked_until = now() - interval '1 second'", jd_dl()) ?? -1) >= 0);
    assert((j.poll() ?? -1) == 0);
    assert(len(js_seen(s)) == 0);
    guard let row = jd_row(p, id) else { assert(false); return; }
    assert(row.dead);
    assert(contains(row.last_error ?? "", "without finishing"));
    pg_close(p);
}

fn test_durable_leaves_a_kind_it_does_not_handle() {
    guard let p = jd_live("test_durable_leaves_a_kind_it_does_not_handle") else { return; }
    let s = js_state();
    let j = jd_jobs(p, s);
    assert((j.handle("mail", jd_note_id, 2) ?? 0) == 1);
    let tx = transaction(p, JdNew { payload: "x", fail: false }, jd_other_kind, jd_dl());
    assert((tx ?? 0) == 1);
    assert((j.poll() ?? -1) == 0);
    assert((j.pending(jd_dl()) ?? -1) == 1);
    pg_close(p);
}

fn jd_other_kind(c: pg.Conn, n: JdNew) -> result[int, str] {
    let r = enqueue_tx(c, "from_the_next_deploy", n.payload, timez.now(), jd_dl());
    guard let _id = r else let e = err_of(r) {
        return err(e);
    }
    return ok(1);
}

fn test_durable_holds_no_more_than_max_running() {
    guard let p = jd_live("test_durable_holds_no_more_than_max_running") else { return; }
    let s = js_state();
    let j = jd_jobs(p, s);
    j.max_running = 2;
    assert((j.handle("mail", js_slow, 3) ?? 0) == 1);
    let i = 0;
    while i < 5 {
        assert((j.enqueue("mail", "x", timez.now()) ?? 0) > 0);
        i = i + 1;
    }
    assert((j.poll() ?? -1) == 2);
    assert((j.poll() ?? -1) == 0);
    chan_send(s.gate, 1);
    chan_send(s.gate, 1);
    assert(j.wait_runs(5000000000));
    assert((j.poll() ?? -1) == 2);
    chan_send(s.gate, 1);
    chan_send(s.gate, 1);
    assert(j.wait_runs(5000000000));
    pg_close(p);
}

fn test_durable_stopped_scheduler_claims_nothing() {
    guard let p = jd_live("test_durable_stopped_scheduler_claims_nothing") else { return; }
    let s = js_state();
    let j = jd_jobs(p, s);
    assert((j.handle("mail", jd_note_id, 3) ?? 0) == 1);
    assert((j.enqueue("mail", "x", timez.now()) ?? 0) > 0);
    j.stop();
    assert((j.poll() ?? -1) == 0);
    assert((j.pending(jd_dl()) ?? -1) == 1);
    pg_close(p);
}

fn test_durable_scheduler_runs_jobs_on_its_own() {
    guard let p = jd_live("test_durable_scheduler_runs_jobs_on_its_own") else { return; }
    let s = js_state();
    let j = jd_jobs(p, s);
    j.poll_every = 5 * timez.MILLISECOND;
    assert((j.handle("mail", jd_note_id, 3) ?? 0) == 1);
    j.start();
    assert((j.enqueue("mail", "x", timez.now()) ?? 0) > 0);
    let tries = 0;
    while len(js_seen(s)) == 0 && tries < 2000 {
        time.sleep(1000000);
        tries = tries + 1;
    }
    assert(len(js_seen(s)) == 1);
    j.stop();
    assert(j.wait_runs(5000000000));
    pg_close(p);
}

// The reason this table exists: a schedule on two replicas, one run.
fn test_durable_schedule_runs_each_turn_once_across_instances() {
    guard let p = jd_live("test_durable_schedule_runs_each_turn_once_across_instances") else { return; }
    assert((pg.pool_exec(p, "truncate zokor_job_turns", jd_dl()) ?? -1) >= 0);
    let s = js_state();
    let a = jd_jobs(p, s);
    let b = jd_jobs(p, s);
    assert((a.every("digest", "* * * * *", js_record, timez.SECOND) ?? 0) == 1);
    assert((b.every("digest", "* * * * *", js_record, timez.SECOND) ?? 0) == 1);
    let t0 = timez.unix(1700000000);
    a.tick(t0);
    b.tick(t0);
    let turn = t0.add(2 * timez.MINUTE);
    a.tick(turn);
    b.tick(turn);
    assert(a.wait_runs(5000000000) && b.wait_runs(5000000000));
    assert(len(js_seen(s)) == 1);
    let later = turn.add(2 * timez.MINUTE);
    a.tick(later);
    b.tick(later);
    assert(a.wait_runs(5000000000) && b.wait_runs(5000000000));
    assert(len(js_seen(s)) == 2);
    pg_close(p);
}

// Different jobs at the same instant are different turns.
fn test_durable_schedule_turns_are_kept_apart_by_name() {
    guard let p = jd_live("test_durable_schedule_turns_are_kept_apart_by_name") else { return; }
    assert((pg.pool_exec(p, "truncate zokor_job_turns", jd_dl()) ?? -1) >= 0);
    let s = js_state();
    let j = jd_jobs(p, s);
    assert((j.every("one", "* * * * *", js_record, timez.SECOND) ?? 0) == 1);
    assert((j.every("two", "* * * * *", js_record, timez.SECOND) ?? 0) == 2);
    let t0 = timez.unix(1700000000);
    j.tick(t0);
    j.tick(t0.add(2 * timez.MINUTE));
    assert(j.wait_runs(5000000000));
    assert(len(js_seen(s)) == 2);
    pg_close(p);
}

fn test_durable_schedule_skips_a_turn_it_cannot_claim() {
    guard let p = jd_live("test_durable_schedule_skips_a_turn_it_cannot_claim") else { return; }
    let s = js_state();
    let j = jd_jobs(p, s);
    assert((j.every("digest", "* * * * *", js_record, timez.SECOND) ?? 0) == 1);
    assert((pg.pool_exec(p, "drop table zokor_job_turns", jd_dl()) ?? -1) >= 0);
    let t0 = timez.unix(1700000000);
    j.tick(t0);
    j.tick(t0.add(2 * timez.MINUTE));
    assert(j.wait_runs(5000000000));
    assert(len(js_seen(s)) == 0);
    assert(j.running() == 0);
    pg_close(p);
}

fn test_durable_schedule_old_turns_are_pruned() {
    guard let p = jd_live("test_durable_schedule_old_turns_are_pruned") else { return; }
    assert((pg.pool_exec(p, "truncate zokor_job_turns;" +
        " insert into zokor_job_turns (name, due) values ('digest', now() - interval '8 days')",
        jd_dl()) ?? -1) >= 0);
    let won = claim_turn(p, "digest", timez.now(), jd_dl());
    assert(won ?? false);
    let r: result[opt[JobCount], str] = query_one(p,
        "select count(*) as n from zokor_job_turns", jd_no_args(), jd_dl());
    guard let row = r else { assert(false); return; }
    guard let c = row else { assert(false); return; }
    assert(c.n == 1);
    pg_close(p);
}

fn jd_no_args() -> [pg.Arg] {
    let none_here: [pg.Arg] = [];
    return none_here;
}

fn test_durable_error_text_is_capped_without_splitting_a_character() {
    guard let p = jd_live("test_durable_error_text_is_capped_without_splitting_a_character") else { return; }
    let s = js_state();
    let j = jd_jobs(p, s);
    assert((j.handle("mail", jd_huge_error, 1) ?? 0) == 1);
    let id = j.enqueue("mail", "x", timez.now()) ?? 0;
    assert((j.poll() ?? -1) == 1);
    assert(j.wait_runs(5000000000));
    guard let row = jd_row(p, id) else { assert(false); return; }
    assert(row.dead);
    assert(len(row.last_error ?? "") == 2 * max_job_error_chars());
    pg_close(p);
}

fn jd_huge_error(c: JobCtx[JState]) -> result[int, str] {
    let e = "é";
    let i = 0;
    while i < 13 {
        e = e + e;
        i = i + 1;
    }
    return err(e);
}

fn test_in_memory_queue_has_no_durable_counts() {
    let j = new_jobs(js_state());
    let r = j.pending(jd_dl());
    guard let _n = r else let e = err_of(r) {
        assert(contains(e, "durable()"));
        assert((j.poll() ?? -1) == 0);
        return;
    }
    assert(false);
}
