// A queue of background jobs that survives restarts, in Postgres.
//
// The table is yours: apply jobs_schema() in a migration, then
//
//     let jobs = zokor.new_jobs(state);
//     jobs.handle("welcome_email", send_welcome, 5);
//     jobs.durable(db)?;     // err when the table is missing
//     jobs.start();
//
// `enqueue` now writes a row, and enqueue_tx writes one inside your own
// transaction, so the job exists exactly if the change that caused it
// committed:
//
//     fn create_user(c: pg.Conn, u: NewUser) -> result[int, str] {
//         ... insert the user ...
//         return zokor.enqueue_tx(c, "welcome_email", u.email, timez.now(), u.deadline);
//     }
//     let r = zokor.transaction(c.state.db, user, create_user, deadline);
//
// What it promises:
//   - at least once, not exactly once. A worker that dies mid-run, or a
//     run that outlives its lease, runs again, so a job must be safe to
//     repeat; JobCtx.job_id is stable across tries to key that on;
//   - any number of instances share the table: FOR UPDATE SKIP LOCKED
//     hands each row to one of them;
//   - a claim is a lease of the longest timeout of the kinds handled
//     here plus lease_margin. A worker that dies gives its jobs back when
//     the lease ends, so a crash costs that long and one attempt: an
//     attempt is counted at the claim, so a job that kills its process
//     cannot do so forever;
//   - a job out of attempts stays in the table with dead_at and
//     last_error set, for you to read and to re-queue:
//         update zokor_jobs set dead_at = null, attempt = 0, run_at = now()
//         where id = $1;
//   - a row whose kind this process does not handle is left alone: during
//     a rolling deploy, the instance that knows it takes it.
//
// Every clock here is the database's, so instances need not agree on the
// time. Cron schedules are not covered: `every` still runs on each
// instance that registers it.

import "builder";
import "pg";
import "proc";
import "time";
import "timez";

struct ClaimedJob {
    id: int,
    kind: str,
    payload: str,
    run_at: timez.Time,
    attempt: int,
}

struct JobId {
    id: int,
}

struct JobCount {
    n: int,
}

// A run that overruns its timeout by less than this keeps its lease.
fn lease_margin() -> int {
    return 30 * timez.SECOND;
}

// last_error is for a person reading a row, not an archive.
fn max_job_error_chars() -> int {
    return 4096;
}

// The SQL of the table a durable queue needs, for a file of its own in
// your migrations directory, such as migrations/007_zokor_jobs.sql.
pub fn jobs_schema() -> str {
    return "create table zokor_jobs (\n" +
           "    id bigint generated always as identity primary key,\n" +
           "    kind text not null,\n" +
           "    payload text not null,\n" +
           "    run_at timestamptz not null,\n" +
           "    attempt int not null default 0,\n" +
           "    locked_by text,\n" +
           "    locked_until timestamptz,\n" +
           "    dead_at timestamptz,\n" +
           "    last_error text,\n" +
           "    created_at timestamptz not null default now()\n" +
           ");\n" +
           "create index zokor_jobs_ready on zokor_jobs (run_at, id) where dead_at is null;\n";
}

fn insert_sql() -> str {
    return "insert into zokor_jobs (kind, payload, run_at) values ($1, $2, $3) returning id";
}

fn insert_args(kind: str, payload: str, at: timez.Time) -> [pg.Arg] {
    return [pg.arg_text(kind), pg.arg_text(payload), pg.arg_time(at)];
}

fn insert_job(db: pg.Pool, kind: str, payload: str, at: timez.Time,
              deadline: until) -> result[int, str] {
    let r: result[opt[JobId], str] = query_one(db, insert_sql(), insert_args(kind, payload, at),
                                               deadline);
    return inserted_id(kind, r);
}

fn inserted_id(kind: str, r: result[opt[JobId], str]) -> result[int, str] {
    guard let row = r else let e = err_of(r) {
        return err(job_store_problem(e));
    }
    guard let j = row else {
        return err("job " + kind + ": the insert returned no row");
    }
    return ok(j.id);
}

// The likely first failure of a new service, named with its fix.
fn job_store_problem(e: str) -> str {
    if contains(e, "zokor_jobs") && contains(e, "does not exist") {
        return "the zokor_jobs table does not exist; apply zokor.jobs_schema() in a migration";
    }
    return e;
}

// Queues one run of `kind` in the transaction `c` is in: it exists if that
// transaction commits, and never otherwise. For use in a transaction()
// body. Unlike enqueue it cannot check that anything handles `kind`.
pub fn enqueue_tx(c: pg.Conn, kind: str, payload: str, at: timez.Time,
                  deadline: until) -> result[int, str] {
    if len(kind) == 0 {
        return err("a job kind needs a name");
    }
    let r: result[[JobId], str] = conn_query_all(c, insert_sql(), insert_args(kind, payload, at),
                                                 deadline);
    guard let rows = r else let e = err_of(r) {
        return err(job_store_problem(e));
    }
    if len(rows) == 0 {
        return err("job " + kind + ": the insert returned no row");
    }
    return ok(rows[0].id);
}

fn interval_ms(ns: int) -> pg.Arg {
    return pg.arg_text(to_str(ns / timez.MILLISECOND) + " milliseconds");
}

struct ClaimTerms {
    kinds: str,
    lease: int,
}

fn jobs_poll_loop[S](j: Jobs[S]) {
    while !j.stop_requested() && !proc.shutdown_requested() {
        let r = j.poll();
        guard let _n = r else let e = err_of(r) {
            j.logger.error("Jobs", "could not check the queue: " + e);
            j.poll_pause();
            continue;
        }
        j.poll_pause();
    }
}

fn run_claimed[S](js: Jobs[S], db: pg.Pool, k: JobKind[S], q: ClaimedJob, c: JobCtx[S]) {
    let why = job_outcome(k.run, c);
    if len(why) == 0 {
        let no_extra: [pg.Arg] = [];
        js.settle(db, q, "delete from zokor_jobs", no_extra);
        js.release_claim(false);
        return;
    }
    if q.attempt >= k.attempts {
        js.logger.error("Jobs", k.kind + " #" + to_str(q.id) + " failed on its last attempt (" +
                        to_str(q.attempt) + " of " + to_str(k.attempts) + "), marked dead: " + why);
        js.bury(db, q, why);
        js.release_claim(true);
        return;
    }
    let wait = job_backoff(q.attempt);
    js.logger.warn("Jobs", k.kind + " #" + to_str(q.id) + " failed (attempt " + to_str(q.attempt) +
                   " of " + to_str(k.attempts) + "), retrying in " +
                   timez.format_duration(wait) + ": " + why);
    js.retry_later(db, q, why, wait);
    js.release_claim(true);
}
