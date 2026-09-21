# zokor

A backend framework for [slang](https://github.com/dolphlabs/slang).

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

let r = zokor.Router[App] {
    routes: [], befores: [], afters: [], state: app,
    errors: reg, auto_options: true, auto_head: true
};
r.get("/orgs/:id", show_org);
```

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
| `load_config`, `require_*` | `.env` then the environment, per-variable validation, **every** problem reported at once |
| `ok_json`, `created`, … | success responses with the headers they should carry |

## Configuration

Read once, at startup, into a value you hold. Nothing reads the
environment while serving: a handler that calls `getenv` changes
behaviour without a deploy and cannot be tested without setting process
state.

```slang
let cfg = zokor.load_config();                 // ".env", then the environment
// or: zokor.load_config_from(".env.test")

let port = zokor.require_port(cfg, "PORT");
let dsn  = zokor.require_dsn(cfg, "DATABASE_URL");
let from = zokor.require_email(cfg, "ALERT_FROM");
let mode = zokor.require_one_of(cfg, "MODE", ["dev", "prod"]);

let ready = zokor.check(cfg);
guard let _ok = ready else let e = err_of(ready) {
    println(e);
    exit(1);
}
```

Every problem comes back together, because a service with six unset
variables should say so once instead of failing six times:

```
configuration is not usable (read from .env and the environment):
  SERVICE_NAME is required but not set
  PORT must be a TCP port (1-65535), got '0'
  DATABASE_URL is required but not set
  ALERT_FROM must be an email address, got 'ops@'
  MODE must be one of: dev, prod, got 'staging'
```

Values under a name that looks like a secret (`*_TOKEN`, `*_PASSWORD`,
`*_URL`, `*_KEY`, …) are reported as `(24 characters, hidden)`, because
this text gets logged.

Validators: `require`, `require_int`, `require_range`, `require_port`,
`require_bool`, `require_float`, `require_email`, `require_url`,
`require_dsn`, `require_host`, `require_ipv4`, `require_uuid`,
`require_one_of`, `require_duration`, `require_min_len`,
`require_max_len`, and `optional_url` / `optional_one_of` for values that
must be valid *when set*.

## Errors

Every failure names a code; every code is registered once with its status
and its wording; every response is rendered by the same function. A
client sees one shape:

```json
{"error":{"code":"org.not_found","message":"no such organisation",
          "status":404,"request_id":"req-9"}}
```

```json
{"error":{"code":"validation_failed","message":"some fields are not valid",
          "status":422,
          "fields":[{"field":"email","reason":"must be an email address"}]}}
```

All HTTP failure statuses ship registered (`bad_request` … `network_auth_required`).
Add your own, or reword a built-in:

```slang
zokor.register(reg, "org.not_found", 404, "no such organisation");
zokor.register(reg, "rate_limited", 429, "slow down");
```

A code nobody registered answers **500 and names itself** — the mistake
belongs in your logs, not hidden behind a generic message.

## Layout

```
zokor/            the package your service imports
  router.sl       Router[S], Route[S], Ctx[S]
  errors.sl       Registry, Code, the envelope
  config.sl       Config, load_config, require_*
  respond.sl      success responses
  internal/
    path/         split, query parsing, percent-decoding
    envfile/      .env parsing
    validate/     the value rules
  examples/hello/ a service you can run
```

The public API is the repository root because that is what a slang `pkg`
pin resolves to. `internal/` holds the pure parts, which is where the
tests are cheapest and the hot paths are easiest to keep honest.

## Install

```
pkg zokor git https://github.com/dolphlabs/zokor tag v0.1.0
```

```
slangc get
```

## Tests

```
make test
```

## Not yet

- **The serve loop.** `listen_and_serve` has to spawn a task carrying
  `Router[S]`, which needs generic **functions**; slang has generic
  structs and methods today. It is the next thing to land.
- **WebSocket**, rewritten from RFC 6455 (needs `crypto.sha1` in slang).
- **`zokor check`**, the layout checker.
- **Postgres helpers and the testing kit.**
