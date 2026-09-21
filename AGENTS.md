# AGENTS.md — zokor

Read this before touching code. These are the rules the framework exists
to enforce, so the framework follows them first.

## Stack

- slang (`slangc`), compiled to C. No runtime dependencies.
- `make test` runs every package's suite. A new package without its own
  line in the Makefile fails review.
- `make example` must print the same output it prints today.

## Layout

- `src/` **is** the package a service imports (`pkg zokor git ... dir src`).
  Public types and their methods live directly in `src/`, because a type
  cannot be re-exported from a sub-package.
- `src/internal/*` holds pure logic: no sockets, no clock, no
  environment. Everything there is directly testable and is where the
  hot paths live.
- `examples/*` and `docs/` are not part of the package.

## Rules

- **One error envelope.** Nothing writes JSON for a failure by hand;
  every failure goes through `respond*` with a registered code. A new
  failure means a new code, not a new shape. The shape itself is a
  default: services replace it with `set_renderer`, one per registry.
- **Configuration is read once.** Nothing under `internal/` or in a
  handler reads the environment. `Config` is built at startup and passed.
- **Every problem at once.** Validation collects; it does not stop at the
  first failure. That holds for configuration, for uploads and for
  request bodies.
- **A failure names its field.** A client should never have to guess
  which part of its body was wrong.
- **No regular expressions in a request path.** Routing is segment
  comparison against patterns split at registration.
- **Protocol code is sans-io.** A parser takes bytes and returns
  values; it never reads a socket. That is why every rule in RFC 6455
  has a test and none of them needs a network.
- **Nothing from a client is trusted as a name.** A filename is one
  path segment, sanitised, with the original kept only for reporting.
- **Every limit is the caller's.** A framework constant that a service
  cannot change is a service that will be taken down by a body size
  somebody else chose.
- **No per-request allocation that can be avoided.** A literal segment
  costs a comparison; a near-miss route costs no map; a path with no
  query costs no copy.
- **Secrets are masked** wherever a value can reach a log.

## Naming

- Files in a package share ONE namespace, so an import alias and a
  parameter cannot use the same name, and two files cannot define the
  same helper. Aliases here are `valid`, `path`, `envfile`, `multipart`;
  a collision resolves to the package and the error names a member you
  never wrote.

## Style

- `guard let` for the happy path, early return for failures. `??` for
  defaults.
- `i32` for HTTP statuses, `int` for counts, ids and nanoseconds.
- Comments say why, not what.
- Every package has `*_test.sl` with `fn test_*`. A test that passes when
  the behaviour is removed is not a test: check it fails first.
