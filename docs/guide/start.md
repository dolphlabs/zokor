# Start here

> Create a Slang backend service with Zokor. Follow the setup guide for installation, project structure, requirements, and your first routes.

## Starting a service

The `zokor` command lives in its own repository,
[zokor_cli](https://github.com/dolphlabs/zokor_cli). Install it once,
with slang installed:

```
curl -fsSL https://raw.githubusercontent.com/dolphlabs/zokor_cli/main/install.sh | sh
```

`zokor new` writes a small service (startup, config, a health check) that
compiles and passes its tests as it stands. `zokor newcomp` writes the
full layout, so a person or an agent changing one feature reads one
directory:

```
zokor new billing             # small: startup, config, /healthz
cd billing && slangc get && make test && make run
zokor newcomp ledger          # full layout; --db pg for Postgres
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

A new project pins the zokor release the CLI was built against (`zokor
version` prints it). `--zokor-git` and `--zokor-tag` pin another. The
templates, and the tests that build and run every kind of project,
are in zokor_cli.

## Install

In a new project (`slangc new app` writes the `name` and `version`
lines), add the pin to `slang.project`. The whole file:

```
name app
version 0.1.0

pkg zokor git https://github.com/dolphlabs/zokor tag v0.2.0 dir zokor
```

Then fetch it, and import it as `import "zokor";`:

```
slangc get
```

`dir zokor` points the pin at the package inside the repository, so the
repository can hold its examples, docs and tests without shipping them
into your build.

## Requirements

slang 0.2.3 or later
([releases](https://github.com/dolphlabs/slang/releases)). It has what
zokor needs: generic structs and methods, the `dir` sub-directory pin,
`exclude`, the compiler-backed `pg.rows_as`, `link.tls_accept` for HTTPS
and `link.split` for WebSocket and Socket.IO routes.
