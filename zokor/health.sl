// Health and readiness.
//
// Two questions an orchestrator asks, with different answers:
//
//   GET /healthz  -- is this process alive? It says the accept loop
//                    and the workers are serving and nothing else. It
//                    never touches a dependency: a database outage must
//                    not make Kubernetes restart every replica.
//   GET /readyz   -- should this replica get traffic? Runs every check
//                    registered with `r.ready_check`, each bounded by the
//                    readiness timeout, and answers 503 while the process
//                    is shutting down so a load balancer drains it first.
//
//     r.health();
//     r.ready_check("db", db_ready);
//
//     fn db_ready(s: App) -> result[int, str] {
//         let q = s.db.query("select 1");
//         guard let _rows = q else let e = err_of(q) {
//             return err(to_str(e));
//         }
//         return ok(0);
//     }
//
// The router answers both paths itself, and only when no route claims
// them (see serve_id): a handler is a non-generic `fn`, so zokor cannot
// register its own generic one, and answering on the miss costs a
// matched request nothing.
//
// The response names each check and whether it passed, never why it
// failed: /readyz is reachable by anyone who can reach the API, and a
// driver's error text carries hosts and user names. The reason goes to
// the server's log instead (stderr when it has none), once per change of
// state rather than once per probe.
//
// A check runs in its own task, so a panic inside it fails the check
// instead of the probe. A check that outlives the timeout keeps running;
// probes that arrive meanwhile wait on that run instead of starting
// another, so a hung dependency costs one task, not one per probe.

import "http";
import "io";
import "proc";
import "time";

pub gc struct ReadyCheck[S] {
    name: str,
    check: fn(S) -> result[int, str],
    lock: mutex,
    // Runs started and finished. A probe starts a run only when they
    // are equal (none in flight), and is answered once `finished`
    // reaches the run it started or joined.
    started: int,
    finished: int,
    passed: bool,
    // The failure last written to stderr; "" when passing. Compared so
    // a check failing the same way every probe is reported once.
    reported: str,
}

pub gc struct Readiness[S] {
    // "" until `r.health()` mounts them.
    live_path: str,
    ready_path: str,
    checks: [ReadyCheck[S]],
    // Nanoseconds a probe waits for its checks before answering 503.
    timeout: int,
    // Where a check's failures and recoveries are reported: the server's
    // logger, set by listen_and_serve_with. With none (a router served
    // some other way), stderr.
    logger: Logger,
}

// 0.9s: inside Kubernetes' default 1s probe timeout, so a slow
// dependency is answered as a 503 naming it rather than as a probe that
// timed out and says nothing.
pub fn default_ready_timeout() -> int {
    return 900000000;
}

fn live_response() -> http.Response {
    return json_response(200, "{\"status\":\"ok\"}");
}

// The /readyz answer: every check run (or joined) at once, then waited
// for together, so the probe takes as long as the slowest check, not
// the sum of them.
fn ready_response[S](rd: Readiness[S], state: S) -> http.Response {
    if proc.shutdown_requested() {
        return json_response(503, "{\"status\":\"shutting_down\",\"checks\":{}}");
    }
    let n = len(rd.checks);
    let targets: [int] = [];
    let i = 0;
    while i < n {
        push(targets, begin_run(rd.checks[i], state, rd.logger));
        i = i + 1;
    }
    let deadline = time.mono() + rd.timeout;
    let results = wait_runs(rd.checks, targets, deadline);
    return ready_body(rd.checks, results);
}

// Starts a run of `ch` unless one is already in flight, and returns the
// run number the caller should wait for.
fn begin_run[S](ch: ReadyCheck[S], state: S, lg: Logger) -> int {
    mutex_lock(ch.lock);
    let start = ch.started == ch.finished;
    if start {
        ch.started = ch.started + 1;
    }
    let target = ch.started;
    mutex_unlock(ch.lock);
    if start {
        spawn run_check(ch, state, lg);
    }
    return target;
}

// Runs the check in a task of its own so a panic is a failed check,
// then records the outcome.
fn run_check[S](ch: ReadyCheck[S], state: S, lg: Logger) {
    let h = spawn call_check(ch.check, state);
    let jr = join_wait(h);
    guard let r = jr else let pe = err_of(jr) {
        record_run(ch, false, "panicked: " + pe, lg);
        return;
    }
    guard let _v = r else let e = err_of(r) {
        let why = e;
        if len(why) == 0 {
            why = "failed";
        }
        record_run(ch, false, why, lg);
        return;
    }
    record_run(ch, true, "", lg);
}

fn call_check[S](f: fn(S) -> result[int, str], state: S) -> result[int, str] {
    return f(state);
}

fn record_run[S](ch: ReadyCheck[S], passed: bool, why: str, lg: Logger) {
    mutex_lock(ch.lock);
    ch.finished = ch.finished + 1;
    ch.passed = passed;
    let was = ch.reported;
    ch.reported = why;
    mutex_unlock(ch.lock);
    if why == was {
        return;
    }
    if lg.enabled(LogLevel.WARN) {
        if len(why) > 0 {
            lg.warn("Health", "readiness check " + ch.name + " failing: " + why);
        } else {
            lg.log("Health", "readiness check " + ch.name + " recovered");
        }
        return;
    }
    if len(why) > 0 {
        io.eprintln("zokor: readiness check " + ch.name + " failing: " + why);
    } else {
        io.eprintln("zokor: readiness check " + ch.name + " recovered");
    }
}

// 0 = still running at the deadline, 1 = passed, 2 = failed.
fn wait_runs[S](checks: [ReadyCheck[S]], targets: [int], deadline: duration) -> [int] {
    let out: [int] = [];
    let i = 0;
    while i < len(checks) {
        push(out, 0);
        i = i + 1;
    }
    let pending = len(checks);
    while true {
        let k = 0;
        while k < len(checks) {
            if out[k] == 0 {
                let ch = checks[k];
                mutex_lock(ch.lock);
                if ch.finished >= targets[k] {
                    out[k] = 2;
                    if ch.passed {
                        out[k] = 1;
                    }
                    pending = pending - 1;
                }
                mutex_unlock(ch.lock);
            }
            k = k + 1;
        }
        if pending == 0 || time.mono() >= deadline {
            return out;
        }
        // There is no timed channel receive to park on, and a probe
        // arrives every few seconds, so a short poll costs nothing.
        time.sleep(2000000);
    }
    return out;
}

// A check name is 1-64 of [A-Za-z0-9_.-]: it is written into the JSON
// body and to stderr as is.
pub fn check_name_ok(name: str) -> bool {
    let b = to_bytes(name);
    if len(b) == 0 || len(b) > 64 {
        return false;
    }
    for c in b {
        let ok_byte = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) ||
                      (c >= 48 && c <= 57) || c == 95 || c == 46 || c == 45;
        if !ok_byte {
            return false;
        }
    }
    return true;
}

fn ready_body[S](checks: [ReadyCheck[S]], results: [int]) -> http.Response {
    let all = true;
    let body = "";
    let i = 0;
    while i < len(checks) {
        if i > 0 {
            body = body + ",";
        }
        let word = "ok";
        if results[i] == 0 {
            word = "timeout";
            all = false;
        } else if results[i] == 2 {
            word = "failing";
            all = false;
        }
        // Names are restricted at registration (check_name_ok), so
        // they need no escaping here.
        body = body + "\"" + checks[i].name + "\":\"" + word + "\"";
        i = i + 1;
    }
    if all {
        return json_response(200, "{\"status\":\"ok\",\"checks\":{" + body + "}}");
    }
    return json_response(503, "{\"status\":\"unavailable\",\"checks\":{" + body + "}}");
}
