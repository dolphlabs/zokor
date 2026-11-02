// Redis, wired to zokor's config system.
//
// slang's own "redis" package is the driver -- connection pooling,
// every command, transactions, pub/sub, streams, cluster routing. What
// is missing is the ten lines every service repeats to turn REDIS_URL
// into a pool at startup, decide whether Redis is even configured, and
// close it down cleanly. This is that, nothing more: a command like
// `redis.get(conn, key, deadline)` is already the right shape, and
// wrapping all ~150 of them here would only be a second place for that
// API to drift from the one slang ships.
//
// Optional by design, same as any other dependency a service may or
// may not need: a config with no REDIS_URL set builds no pool and
// opens no connection, and `redis_from_config` says so with a plain
// `err`, not a panic -- the caller decides whether that is fatal.

import "redis";

// REDIS_URL, read the same way every other optional dependency in this
// package is: config.optional_dsn, so a malformed value (a scheme with
// no host, or nothing that looks like a connection string at all)
// still surfaces through Config's own problem report -- with a clear
// field name and reason -- rather than as a raw parse error handed
// back from here. "" (unset) is not a problem; it is "this service
// does not use Redis," and this function reports that as err, not a
// panic, so the caller decides whether that is fatal.
//
// REDIS_POOL_SIZE, if set, overrides the default of 8 connections
// (redis.Pool's own default_config uses the same number). Parses
// REDIS_URL and builds the Pool struct; connects nothing until the
// first acquire (redis.new_pool's own behavior) -- a service that
// never actually reaches a Redis-backed code path on a given run pays
// nothing at startup for having Redis configured.
pub fn redis_from_config(cfg: Config) -> result[redis.Pool, str] {
    let url = optional_dsn(cfg, "REDIS_URL", "");
    if len(url) == 0 {
        return err("REDIS_URL is not set");
    }
    let size = int_or(cfg, "REDIS_POOL_SIZE", 8);
    if size < 1 {
        return err("REDIS_POOL_SIZE must be at least 1");
    }
    return redis.new_pool(url, size);
}

// true iff REDIS_URL is set -- for a service that wants to know
// whether to wire Redis-backed features in at all before trying to
// build a pool (a health check registering a Redis probe only when
// there is a pool to probe, say), without the DSN validation
// redis_from_config also does surfacing as a Config problem for a
// service that does not use Redis in the first place.
pub fn has_redis(cfg: Config) -> bool {
    return len(optional_dsn(cfg, "REDIS_URL", "")) > 0;
}

// Closes every idle connection and marks the pool closed; an in-flight
// acquire finishes normally, and the next one fails with "pool is
// closed" (redis.acquire's own behavior). Named for symmetry with
// redis_from_config rather than making every caller reach past this
// package into slang's redis one for the one call it still needs.
pub fn redis_close(p: redis.Pool) {
    redis.pool_close(p);
}
