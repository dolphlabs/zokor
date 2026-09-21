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
r.post("/orgs", create_org);
```

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
| `load_config`, `require_*` | `.env` then the environment, per-variable validation, **every** problem reported at once |
| `parse_form`, `c.upload` | multipart/form-data: limits, type and extension allowlists, filenames made safe |
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

### The shape is a default

That envelope is what you get until you say otherwise. A service with an
existing contract — a different key, `application/problem+json`, whatever
its clients already parse — installs its own renderer and keeps the
registry, the codes and the statuses:

```slang
fn problem_json(v: zokor.ErrorView) -> http.Response {
    let body = "{\"type\":\"about:blank\",\"title\":" + zokor.quote(v.code) +
               ",\"detail\":" + zokor.quote(v.message) +
               ",\"status\":" + to_str(v.status) + "}";
    return zokor.bytes_of(v.status, "application/problem+json", to_bytes(body));
}

zokor.set_renderer(reg, problem_json);
```

`ErrorView` carries the code, the message, the status, the request id and
the field errors — a struct, not a parameter list, so a later addition
does not break renderers people have already written. One renderer per
registry: every failure in a service still comes out the same way, which
is the point of having a registry at all.

## Uploads

`multipart/form-data` is a format where being lax is a vulnerability:
the client picks the delimiter, names the parts and supplies the
filenames. A handler says what it accepts; anything else comes back as
a registered failure and never reaches it.

```slang
fn upload_avatar(c: zokor.Ctx[App]) -> http.Response {
    let rules = zokor.with_max_file_bytes(
        zokor.uploads_allowing(["image/png", "image/jpeg"]), 1048576);

    let r = c.upload(rules);          // POST/PUT/PATCH only
    guard let form = r else let e = err_of(r) {
        return zokor.respond_with(c.state.errors, e.code, e.detail, c.request_id);
    }
    guard let avatar = zokor.file(form, "avatar") else {
        return zokor.respond(c.state.errors, "validation_failed", c.request_id);
    }

    zokor.value(form, "title");        // the non-file fields
    zokor.files_for(form, "docs");     // <input multiple>
    avatar.filename;                   // safe to use as one path segment
    avatar.raw_filename;               // what the client actually sent
    return zokor.ok_json("{\"bytes\":" + to_str(len(avatar.data)) + "}");
}
```

**Filenames are made safe**: everything before the last `/` or `\` is
dropped, control characters go, a leading dot goes, and a name that is
empty after that becomes `upload`. `../../etc/passwd` arrives as
`passwd`. The name the client sent is kept as `raw_filename` for logs.

**Limits are the caller's**, checked while the body is walked: parts,
files, bytes per file, bytes per field, total bytes, header size,
filename length. Over a size limit is a `413`; a body that is not
well-formed multipart is a `400`; a type or extension that is not
allowed is a `415`.

**Refused rather than guessed at**: a Content-Type that is not
multipart or has no boundary, a boundary that is empty or over 70
characters, a body that stops before its closing delimiter, a part with
no `Content-Disposition` or no name, unterminated or oversized part
headers, and a `Content-Transfer-Encoding` the web does not use. A file
sent with no `Content-Type` is refused unless you turn
`require_content_type` off.

A body arrives whole, so this does not stream: set `max_total_bytes`
for what a service can afford to hold.

## Layout

```
src/              the package your service imports
  router.sl       Router[S], Route[S], Ctx[S]
  errors.sl       Registry, Code, ErrorView, the envelope
  config.sl       Config, load_config, require_*
  respond.sl      success responses
  upload.sl       uploads: rules, Form, Upload, safe filenames
  internal/
    path/         split, query parsing, percent-decoding
    envfile/      .env parsing
    validate/     the value rules
    multipart/    the multipart/form-data parser
examples/hello/   a service you can run
docs/
```

`internal/` holds the pure parts: no sockets, no clock, no environment.
That is where the tests are cheapest and the hot paths easiest to keep
honest.

## Requirements

slang with **generic structs and methods** — on `dev`, not yet in a
release. `pkg ... dir src` needs the sub-directory pin, also on `dev`.

## Install

```
pkg zokor git https://github.com/dolphlabs/zokor tag v0.1.0 dir src
```

```
slangc get
```

`dir src` points the pin at the package inside the repository, so the
repository can hold its examples, docs and tests without shipping them
into your build.

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
