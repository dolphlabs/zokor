# Start here

> Create a Slang backend service with Zokor. Follow the setup guide for installation, project structure, requirements, and your first routes.

## Starting a service

Install the `zokor` command (see [The zokor command](#the-zokor-command)),
then:

```
zokor new billing             # a small service: startup, config, a health check
cd billing && slangc get && make test
make dev                      # rebuilds and restarts on every save
```

For the full layout, with a sample feature split into layers, start with
`zokor newcomp` instead, and grow it a slice at a time:

```
zokor newcomp billing --db pg # --db memory (the default) or pg for Postgres
cd billing && slangc get && make test
zokor add feature orders      # a new slice, wired in (--entity to name its type)
zokor add route orders POST /:id/cancel cancel_order
```

`add route` registers the route under the feature's prefix (here
`POST /orders/:id/cancel`), behind the feature's authentication, with a
handler that answers 501 until it is written and a test that the route is
mounted and authenticated.

`zokor check` (run by the project's `make check`) holds a service to that
layout: imports go `server -> service -> domain`, only `store/` and
`platform/db` import `pg`, `domain` and `service` do no I/O, SQL is never
built by concatenating a value, configuration is read only in
`platform/config`, and every package has tests. It prints
`file:line: rule: message`, or one JSON object per line with `--json`, and
exits 1 on any problem.

```
src/main.sl            startup only: config, state, mount, serve
src/platform/config/   every setting, read once
src/platform/app/      App: the state handlers get as c.state
src/platform/auth/     who the caller is
src/platform/db/       the Postgres pool (--db pg)
src/<feature>/
  domain/    types and rules; pure: no I/O, no zokor
  service/   use cases, and ports.sl: what they need from storage
  store/     adapters for those ports; store.sl picks one at startup
  server/    routes, DTOs, error codes
migrations/  NNN_<feature>.sql (--db pg), applied by `zokor migrate`
```

Each folder is a package with its tests beside it, and imports run one
way: `server -> service -> domain`, with `store` implementing the
service's ports and `platform/app` wiring them together. The sample
feature is a notes API (create, get, list), with fakes in `*_test.sl` so
they never ship. `add feature` writes the same slice under a new name and
inserts it at the `// zokor:` markers in `src/platform/app/app.sl` and
`src/main.sl`; it refuses a name that exists or that the generated code
uses, and writes nothing then. The project's own `AGENTS.md` gives an
agent these rules in a few lines.

## Install

In a new project (`slangc new app` writes the `name` and `version`
lines), add the pin to `slang.project`. The whole file:

```
name app
version 0.1.0

pkg zokor git https://github.com/dolphlabs/zokor tag v0.2.0 dir zokor
```

`v0.1.0` and older lived in `src/`: pin those with `dir src`.

Then fetch it, and import it as `import "zokor";`:

```
slangc get
```

`dir zokor` points the pin at the package inside the repository, so the
repository can hold its examples, docs and tests without shipping them
into your build.

## Requirements

slang's `dev` branch until its next release: typed Postgres mapping needs
the compiler-backed `pg.rows_as`. zokor also needs generic structs and methods
and the `dir` sub-directory pin. HTTPS (`TLS_CERT_FILE`) needs `link.tls_accept`
and served WebSocket and Socket.IO routes need `link.split`, both on
slang's `dev` branch until its next release.
