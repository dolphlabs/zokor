# AGENTS.md -- __service__

A zokor service, in slang. Read this before changing anything.

## Commands

- `make test`: every package's tests. `make check`: tests and a build.
- `make run`: build and serve (configuration from `.env`, see `.env.example`).
- `zokor add feature <name>`: a new feature slice, wired in. Use it rather
  than writing the files by hand.
- `zokor add route <feature> <METHOD> <path> <handler>`: a route under the
  feature's prefix, a handler answering 501 until written, and its test.
- `slangc doc zokor <name>`: zokor's API, one item at a time.

## Layout

```
src/main.sl            startup only: config, state, mount, serve
src/platform/config/   every setting, read once (settings.sl)
src/platform/app/      App: the state handlers get as c.state
src/platform/auth/     who the caller is (require_tenant)
src/<feature>/
  domain/    types and rules; pure: no I/O, no zokor
  service/   use cases, and ports.sl: what it needs from storage
  store/     adapters implementing those ports
  server/    routes, DTOs, error codes: HTTP in and out
migrations/  NNN_description.sql, applied in order by `zokor migrate`
```

## Rules

- Imports go one way: `server -> service -> domain`; `store` implements
  `service`'s ports; `platform/app` wires stores to services. A feature
  reaches another only through that feature's `service`.
- The tenant is an explicit argument to every use case and store call.
- Configuration is read once, in `platform/config`; nothing else reads the
  environment.
- Every failure goes through a registered error code (`server/errors.sl`);
  a store's own error is logged, never sent to a client.
- Every package has a `*_test.sl` beside it. Fakes live in `*_test.sl`
  files, so they never ship.
- Comments say why, not what.
