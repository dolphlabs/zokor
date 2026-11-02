// Background jobs: work on a schedule, and work queued to run later.
//
// Scheduled jobs take a cron schedule read on the clocks of a time zone,
// so "every weekday at 09:00 in Berlin" stays at 09:00 across daylight-
// saving changes (slang's timez does the arithmetic):
//
//     let jobs = zokor.new_jobs(state);
//     jobs.logger = sc.logger;
//     jobs.zone = timez.load_zone("Europe/Berlin") ?? timez.utc_zone();
//     jobs.every("digest", "0 9 * * MON-FRI", send_digest, 60 * timez.SECOND);
//     jobs.start();                         // then listen_and_serve as usual
//
//     fn send_digest(j: zokor.JobCtx[App]) -> result[int, str] {
//         ... use j.state, and j.deadline for every call that can block ...
//         return ok(0);
//     }
//
// Queued jobs run once, at or after a time, with retries:
//
//     jobs.handle("welcome_email", send_welcome, 5);     // up to 5 attempts
//     jobs.enqueue("welcome_email", user_id, timez.now());
//
// What it promises:
//   - a run is its own task: a panic fails that run, logged with the
//     job's name, and nothing else;
//   - a scheduled job never overlaps itself: due while its last run is
//     still going, that turn is skipped and logged;
//   - missed turns are not replayed (a server down at 09:00 does not run
//     the 09:00 job at 09:20), as in cron;
//   - a failed queued job is retried with exponential backoff (1 s, 2 s,
//     4 s ... capped at an hour) until its attempts run out, then logged
//     and dropped;
//   - on SIGTERM the scheduler stops starting runs within a quarter
//     second; runs in progress get the server's shutdown drain to finish.
//
// The queue is in memory: what is queued is lost when the process
// stops. Work that must survive a restart belongs in a table or a Redis
// list that a scheduled job drains.
//
// Tests drive the scheduler with `tick(now)` on fixed instants and
// `wait_runs()`, and never sleep.

import "proc";
import "time";
import "timez";

// What a run gets: the service's state, which run this is, and the
// deadline to pass to everything that can block.
pub gc struct JobCtx[S] {
    state: S,
    name: str,
    // A queued job's payload; "" for a scheduled one.
    payload: str,
    // 1 on the first try of a queued job; always 1 for a scheduled one.
    attempt: int,
    // When this run was due.
    due: timez.Time,
    deadline: until,
}

gc struct ScheduledJob[S] {
    name: str,
    cron: timez.Cron,
    run: fn(JobCtx[S]) -> result[int, str],
    timeout: int,
    next: opt[timez.Time],
    running: bool,
}

gc struct JobKind[S] {
    kind: str,
    run: fn(JobCtx[S]) -> result[int, str],
    attempts: int,
    timeout: int,
}

gc struct QueuedJob {
    kind: str,
    payload: str,
    at: timez.Time,
    attempt: int,
}

pub gc struct Jobs[S] {
    state: S,
    // The clocks cron schedules are read on. UTC unless set.
    zone: timez.Zone,
    // Where now comes from: a fixed clock in tests.
    clock: timez.Clock,
    logger: Logger,
    // How long a queued job's run may take, when its kind does not say.
    default_timeout: int,
    scheduled: [ScheduledJob[S]],
    kinds: [JobKind[S]],
    queue: [QueuedJob],
    lock: mutex,
    in_flight: int,
    stopping: bool,
    // Runs that ended in err or a panic, and queued jobs given up on.
    failures: int,
}

pub fn new_jobs[S](state: S) -> Jobs[S] {
    let no_scheduled: [ScheduledJob[S]] = [];
    let no_kinds: [JobKind[S]] = [];
    let no_queue: [QueuedJob] = [];
    return Jobs[S] {
        state: state,
        zone: timez.utc_zone(),
        clock: timez.system_clock(),
        logger: no_logger(),
        default_timeout: 60 * timez.SECOND,
        scheduled: no_scheduled,
        kinds: no_kinds,
        queue: no_queue,
        lock: make_mutex(),
        in_flight: 0,
        stopping: false,
        failures: 0
    };
}

// Longest a queued job waits between tries.
fn max_backoff() -> int {
    return timez.HOUR;
}

// The wait before try `attempt + 1`: 1 s, 2 s, 4 s ... capped.
pub fn job_backoff(attempt: int) -> int {
    let d = timez.SECOND;
    let i = 1;
    while i < attempt && d < max_backoff() {
        d = d * 2;
        i = i + 1;
    }
    if d > max_backoff() {
        return max_backoff();
    }
    return d;
}

impl Jobs[S] {
    // Runs `run` on the cron schedule `spec` (see timez.parse_cron), each
    // run given `timeout` nanoseconds as its deadline. err for a bad
    // schedule, an empty or repeated name, or a timeout below 1 ms.
    pub fn every(self: Jobs[S], name: str, spec: str,
                 run: fn(JobCtx[S]) -> result[int, str], timeout: int) -> result[int, str] {
        if len(name) == 0 {
            return err("a scheduled job needs a name");
        }
        if timeout < timez.MILLISECOND {
            return err("job " + name + ": timeout must be at least 1ms");
        }
        let cr = timez.parse_cron(spec);
        guard let cron = cr else let e = err_of(cr) {
            return err("job " + name + ": " + e);
        }
        mutex_lock(self.lock);
        for j in self.scheduled {
            if j.name == name {
                mutex_unlock(self.lock);
                return err("job " + name + " is already scheduled");
            }
        }
        push(self.scheduled, ScheduledJob[S] {
            name: name,
            cron: cron,
            run: run,
            timeout: timeout,
            next: none,
            running: false
        });
        let n = len(self.scheduled);
        mutex_unlock(self.lock);
        return ok(n);
    }

    // Registers what runs a queued job of `kind`, and how many tries it
    // gets (at least 1). err for an empty or repeated kind.
    pub fn handle(self: Jobs[S], kind: str, run: fn(JobCtx[S]) -> result[int, str],
                  attempts: int) -> result[int, str] {
        if len(kind) == 0 {
            return err("a job kind needs a name");
        }
        if attempts < 1 {
            return err("job kind " + kind + ": attempts must be at least 1");
        }
        mutex_lock(self.lock);
        for k in self.kinds {
            if k.kind == kind {
                mutex_unlock(self.lock);
                return err("job kind " + kind + " is already handled");
            }
        }
        push(self.kinds, JobKind[S] {
            kind: kind,
            run: run,
            attempts: attempts,
            timeout: self.default_timeout
        });
        let n = len(self.kinds);
        mutex_unlock(self.lock);
        return ok(n);
    }

    // Queues one run of `kind` with `payload`, due at `at` (now or in
    // the past runs at the next tick). err when nothing handles `kind`.
    pub fn enqueue(self: Jobs[S], kind: str, payload: str, at: timez.Time) -> result[int, str] {
        mutex_lock(self.lock);
        let known = false;
        for k in self.kinds {
            if k.kind == kind {
                known = true;
            }
        }
        if !known {
            mutex_unlock(self.lock);
            return err("no handler for job kind " + kind + "; register it with handle()");
        }
        push(self.queue, QueuedJob { kind: kind, payload: payload, at: at, attempt: 1 });
        let n = len(self.queue);
        mutex_unlock(self.lock);
        return ok(n);
    }

    // Queued runs not yet started.
    pub fn queued(self: Jobs[S]) -> int {
        mutex_lock(self.lock);
        let n = len(self.queue);
        mutex_unlock(self.lock);
        return n;
    }

    // Runs started and not yet finished.
    pub fn running(self: Jobs[S]) -> int {
        mutex_lock(self.lock);
        let n = self.in_flight;
        mutex_unlock(self.lock);
        return n;
    }

    // Starts every run due at `now` -- scheduled turns and queued jobs --
    // each in its own task, and returns how many it started. The
    // scheduler loop calls this; a test calls it with fixed instants.
    pub fn tick(self: Jobs[S], now: timez.Time) -> int {
        let started = 0;
        mutex_lock(self.lock);
        if self.stopping {
            mutex_unlock(self.lock);
            return 0;
        }
        let i = 0;
        while i < len(self.scheduled) {
            let j = self.scheduled[i];
            guard let next = j.next else {
                // first sight: the next turn after now, never one already past
                j.next = j.cron.next_after(now, self.zone);
                i = i + 1;
                continue;
            }
            if next.after(now) {
                i = i + 1;
                continue;
            }
            j.next = j.cron.next_after(now, self.zone);
            if j.running {
                self.logger.warn("Jobs", j.name + ": still running at its next turn (" +
                                 next.rfc3339() + "); skipped");
                i = i + 1;
                continue;
            }
            j.running = true;
            self.in_flight = self.in_flight + 1;
            let c = JobCtx[S] {
                state: self.state,
                name: j.name,
                payload: "",
                attempt: 1,
                due: next,
                deadline: until_of(time.mono() + j.timeout)
            };
            spawn run_scheduled(self, j, c);
            started = started + 1;
            i = i + 1;
        }
        let waiting: [QueuedJob] = [];
        for q in self.queue {
            if q.at.after(now) {
                push(waiting, q);
                continue;
            }
            let found = false;
            for k in self.kinds {
                if k.kind == q.kind && !found {
                    found = true;
                    self.in_flight = self.in_flight + 1;
                    let c = JobCtx[S] {
                        state: self.state,
                        name: q.kind,
                        payload: q.payload,
                        attempt: q.attempt,
                        due: q.at,
                        deadline: until_of(time.mono() + k.timeout)
                    };
                    spawn run_queued(self, k, q, c);
                    started = started + 1;
                }
            }
        }
        self.queue = waiting;
        mutex_unlock(self.lock);
        return started;
    }

    // How long until the earliest known due time after `now`, at most
    // `cap` and at least 1 ms.
    fn wait_from(self: Jobs[S], now: timez.Time, cap: int) -> int {
        let best = cap;
        mutex_lock(self.lock);
        for j in self.scheduled {
            if let next = j.next {
                let d = next.sub(now);
                if d < best {
                    best = d;
                }
            }
        }
        for q in self.queue {
            let d = q.at.sub(now);
            if d < best {
                best = d;
            }
        }
        mutex_unlock(self.lock);
        if best < timez.MILLISECOND {
            return timez.MILLISECOND;
        }
        return best;
    }

    // Starts the scheduler: a task that ticks at each due time, and at
    // least every quarter second so a stop or SIGTERM is seen quickly.
    pub fn start(self: Jobs[S]) -> int {
        spawn jobs_loop(self);
        return 0;
    }

    // Stops starting runs. Runs in progress finish on their own.
    pub fn stop(self: Jobs[S]) -> int {
        mutex_lock(self.lock);
        self.stopping = true;
        mutex_unlock(self.lock);
        return 0;
    }

    fn stop_requested(self: Jobs[S]) -> bool {
        mutex_lock(self.lock);
        let s = self.stopping;
        mutex_unlock(self.lock);
        return s;
    }

    // Waits until no run is in progress, or `timeout` nanoseconds pass;
    // true when none is. For tests, and for a shutdown that wants its
    // jobs finished before the process exits.
    pub fn wait_runs(self: Jobs[S], timeout: int) -> bool {
        let end = time.mono() + timeout;
        while self.running() > 0 {
            if time.mono() >= end {
                return false;
            }
            time.sleep(1000000);
        }
        return true;
    }

    fn finished(self: Jobs[S], failed: bool) {
        mutex_lock(self.lock);
        self.in_flight = self.in_flight - 1;
        if failed {
            self.failures = self.failures + 1;
        }
        mutex_unlock(self.lock);
    }

    fn requeue(self: Jobs[S], q: QueuedJob) {
        mutex_lock(self.lock);
        push(self.queue, q);
        mutex_unlock(self.lock);
    }
}

fn jobs_loop[S](j: Jobs[S]) {
    while !j.stop_requested() && !proc.shutdown_requested() {
        let now = j.clock.now();
        j.tick(now);
        time.sleep(j.wait_from(j.clock.now(), 250 * timez.MILLISECOND));
    }
}

// The user's function in a task of its own, so its panic is this run's
// failure and not the scheduler's.
fn call_job[S](run: fn(JobCtx[S]) -> result[int, str], c: JobCtx[S]) -> result[int, str] {
    return run(c);
}

// "" when the run succeeded, else why it failed.
fn job_outcome[S](run: fn(JobCtx[S]) -> result[int, str], c: JobCtx[S]) -> str {
    let h = spawn call_job(run, c);
    let jr = join_wait(h);
    guard let r = jr else let pe = err_of(jr) {
        return "panicked: " + pe;
    }
    guard let _v = r else let e = err_of(r) {
        return e;
    }
    return "";
}

fn run_scheduled[S](js: Jobs[S], j: ScheduledJob[S], c: JobCtx[S]) {
    let why = job_outcome(j.run, c);
    if len(why) > 0 {
        js.logger.error("Jobs", j.name + " failed: " + why);
    }
    mutex_lock(js.lock);
    j.running = false;
    mutex_unlock(js.lock);
    js.finished(len(why) > 0);
}

fn run_queued[S](js: Jobs[S], k: JobKind[S], q: QueuedJob, c: JobCtx[S]) {
    let why = job_outcome(k.run, c);
    if len(why) == 0 {
        js.finished(false);
        return;
    }
    if q.attempt >= k.attempts {
        js.logger.error("Jobs", k.kind + " failed on its last attempt (" + to_str(q.attempt) +
                        " of " + to_str(k.attempts) + "), dropped: " + why);
        js.finished(true);
        return;
    }
    let wait = job_backoff(q.attempt);
    js.logger.warn("Jobs", k.kind + " failed (attempt " + to_str(q.attempt) + " of " +
                   to_str(k.attempts) + "), retrying in " + timez.format_duration(wait) +
                   ": " + why);
    js.requeue(QueuedJob {
        kind: q.kind,
        payload: q.payload,
        at: js.clock.now().add(wait),
        attempt: q.attempt + 1
    });
    js.finished(true);
}
