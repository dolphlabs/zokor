# Start here

> Create a Slang backend service with Zokor. Follow the setup guide for installation, project structure, requirements, and your first routes.

## Starting a service

`zokor new` writes a service that compiles and passes its tests as it
stands, laid out so a person or an agent changing one feature reads one
directory:

```
make cli                      # builds bin/zokor
bin/zokor new billing         # or: --db pg for Postgres
cd billing && slangc get && make test && make run
bin/zokor add feature orders  # a new slice, wired in (--entity to name its type)
bin/zokor add route orders POST /:id/cancel cancel_order
```

`add route` registers the route under the feature's prefix (here
`POST /orders/:id/cancel`), behind the feature's authentication, with a
handler that answers 501 until it is written and a test that the route is
mounted and authenticated.

`zokor check` (run by the project's `make check`) holds a service to that
layout: imports go `server -> service -> domain`, only `store/` and
`platform/db` import `pg`, `domain` and `service` do no I/O, SQL is never
built by concatenating a value, configuration is read only in
`platform/config`, every public use case takes a `tenant_id`, every
`server.sl` is behind `require_tenant` (or says `// zokor:public`), and every
package has tests. It prints `file:line: rule: message`, or one JSON
object per line with `--json`, and exits 1 on any problem.

```
src/main.sl            startup only: config, state, mount, serve
src/platform/config/   every setting, read once
src/platform/app/      App: the state handlers get as c.state
src/platform/auth/     who the caller is (API keys -> tenant)
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
service's ports and `platform/app` wiring them together. The example
feature is a tenant-scoped notes API (create, get, list) behind
`X-Api-Key`, with fakes in `*_test.sl` so they never ship. `add feature`
writes the same slice under a new name and inserts it at the `// zokor:`
markers in `src/platform/app/app.sl` and `src/main.sl`; it refuses a name
that exists or that the generated code uses, and writes nothing then. The
project's own `AGENTS.md` gives an agent these rules in a few lines.

A new project pins `zokor` at `v0.2.0`, which is not tagged yet: until it
is, pass `--zokor-git` and `--zokor-tag` for the commit you build against.
The templates are real files under `cmd/zokor/templates/`, embedded by
`make templates`; `tests/scaffold.sh` (part of `make check`) generates
both kinds of project against this checkout and runs their tests.

## Install

In a new project (`slangc new app` writes the `name` and `version`
lines), add the pin to `slang.project`. The whole file:

```
name app
version 0.1.0

pkg zokor git https://github.com/dolphlabs/zokor tag v0.2.0 dir zokor
```

`v0.2.0` is the next release and is not tagged yet. Until it is, pin
`tag v0.1.0 dir src`: the package lived in `src/` before the rename.

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
