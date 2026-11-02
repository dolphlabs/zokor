# zokor

> A backend framework for slang.

zokor exists for one reason: a service should spend its code on what it
does, not on the plumbing every service rewrites — routing, configuration,
error shapes, limits. It is opinionated about the things that go wrong
when each service invents its own: **one error envelope**, **one place
configuration is read**, **one router**.

```slang
import "http";
import "zokor";

gc struct App {
    db: pg.Pool,
    errors: zokor.Registry,
}

fn show_org(c: zokor.Ctx[App]) -> http.Response {
    guard let org = find_org(c.state.db, c.param("id")) else {
        return zokor.respond(c.state.errors, "org.not_found", c.request_id);
    }
    return zokor.ok_json(encode(org));
}

let r = zokor.new_router(app);
r.errors = reg;
r.get("/orgs/:id", show_org);
r.post("/orgs", create_org);
```

Middleware attaches to a **group**, not to every handler:

```slang
r.get("/health", health);            // public

let api = r.group("/api/v1");
api.before(require_token);           // everything below is guarded
api.get("/orgs/:id", show_org);
api.post("/orgs", create_org);

let admin = api.group("/admin");     // nests: /api/v1/admin
admin.before(require_admin);         // and keeps the parent's hooks
admin.delete("/orgs/:id", drop_org);
```

Middleware applies to routes registered **after** it, on that group, and
each route keeps a copy — so adding a hook later cannot silently change
a route that already exists. One route on its own:
`r.guarded(Method.DELETE, "/orgs/:id", drop, [require_admin])`.

A `before` can also **resolve** something for the handler, which is the
point of doing authentication once at the edge:

```slang
fn require_token(c: zokor.Ctx[App]) -> opt[http.Response] {
    guard let user = lookup(c.state.db, c.bearer()) else {
        return some(zokor.respond(c.state.errors, "unauthorized", c.request_id));
    }
    c.set_local("user_id", user.id);     // the handler reads c.local("user_id")
    return none;
}
```

`after` hooks run innermost first (the route's, then the router's), and
they run even when a `before` stopped the request — so a logging hook
cannot be skipped by a short circuit.

Methods are a closed set: `r.get`, `r.post`, `r.put`, `r.patch`,
`r.delete`, `r.head`, `r.options`, `r.trace`, `r.connect`, and
`r.any([zokor.Method.GET, zokor.Method.POST], "/p", h)` for several at
once. A verb the set does not contain answers `501`, not `404`: the
path may well exist.

`Router[S]` is generic over **your** state. A framework cannot know what
your handlers need — a database pool, a config, your services — and
before slang had generics the only way to reach them was to pass each as
its own parameter. A real control plane ended up with a twelve-parameter
`dispatch` that grew with every new service. Here it is one value you
declare, and every handler receives it.

## What is in it

| | |
|---|---|
| `Router[S]`, `Ctx[S]` | every HTTP method, `:params`, `*wildcards`, before/after middleware, automatic `HEAD` and `OPTIONS`, `Allow` on a 405 |
| `Registry`, `respond*` | every HTTP failure code, one JSON envelope, field-level validation errors |
| `load_config`, `require_*` | `.env` plus profiles, startup environment snapshot, per-variable validation, **every** problem reported at once |
| `parse_form`, `c.upload` | multipart/form-data: limits, type and extension allowlists, filenames made safe |
| `snake_keys`, `decode_failed`, `checker` | DTOs: wire names, decode errors as field errors, validation |
| `Json`, `parse`, `jobj` | JSON you did not declare: walk it, build it, render it |
| `upgrade`, `receive`, `sio_*` | WebSocket (RFC 6455) and Socket.IO, as a state machine you feed bytes |
| `ok_json`, `created`, … | success responses with the headers they should carry |
| `files_at`, `r.files(mount)` | static files: traversal-safe, ranges, validators, cache headers |
| `r.compress(compression())` | gzip for clients that accept it, on bodies worth it |
| `r.idempotency(store)` | idempotency keys: a retried POST gets the first answer, in memory or Redis |
| `page_of`, `offset_page`, `cursor_page` | pagination: offset or keyset pages, one envelope, `Link` headers |
| `new_jobs`, `every`, `handle`, `enqueue` | background jobs: cron schedules in a time zone, a retrying in-memory queue |
| `preconditions`, `etag_of`, `r.etags()` | conditional requests: `304 Not Modified`, `412` on a lost update, ETag and Last-Modified |
| `redis_from_config` | a Redis pool from `REDIS_URL`, optional by default |
| `ServerConfig`, `listen_and_serve_with` | idle/header/body/write timeouts, safe defaults, all overridable |
| `RateLimiter`, `rate_limit` | per-client sliding-window limits: `429`, `Retry-After`, the registered envelope |
| `TokenStore`, `bearer_subject` | opaque bearer tokens: crypto-random, issue/lookup/revoke, optional TTL, safe across tasks |

Every public symbol, one line each: [docs/api.txt](docs/api.txt).
