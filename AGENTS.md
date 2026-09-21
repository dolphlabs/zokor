# AGENTS.md — zokor

Read this before touching code. These are the rules the framework exists
to enforce, so the framework follows them first.

## Stack

- slang (`slangc`), compiled to C. No runtime dependencies.
- `make test` runs every package's suite. A new package without its own
  line in the Makefile fails review.
- `make example` must print the same output it prints today.

## Layout

- The repository root **is** the package a service imports; a slang `pkg`
  pin resolves to it. Public types and their methods live here, because
  a type cannot be re-exported from a sub-package.
- `internal/*` holds pure logic: no sockets, no clock, no environment.
  Everything there is directly testable and is where the hot paths live.
- `examples/*` are programs, not part of the package.

## Rules

- **One error envelope.** Nothing writes JSON for a failure by hand;
  every failure goes through `respond*` with a registered code. A new
  failure means a new code, not a new shape.
- **Configuration is read once.** Nothing under `internal/` or in a
  handler reads the environment. `Config` is built at startup and passed.
- **Every problem at once.** Validation collects; it does not stop at the
  first failure.
- **No regular expressions in a request path.** Routing is segment
  comparison against patterns split at registration.
- **No per-request allocation that can be avoided.** A literal segment
  costs a comparison; a near-miss route costs no map; a path with no
  query costs no copy.
- **Secrets are masked** wherever a value can reach a log.

## Style

- `guard let` for the happy path, early return for failures. `??` for
  defaults.
- `i32` for HTTP statuses, `int` for counts, ids and nanoseconds.
- Comments say why, not what.
- Every package has `*_test.sl` with `fn test_*`. A test that passes when
  the behaviour is removed is not a test: check it fails first.
