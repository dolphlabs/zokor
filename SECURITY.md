# Security policy

## Supported versions

zokor is pre-1.0. Only the latest release and `main` get security fixes.
Fixes land on `dev` first and reach a release from `main`.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.** Report it
privately through GitHub:

<https://github.com/dolphlabs/zokor/security/advisories/new>

(or the repository's **Security** tab → **Report a vulnerability**). Only the
maintainers can see it.

If that form is not available, open a public issue titled
`security contact request` with **no details** in it, and a maintainer will
arrange a private way to talk.

A useful report has:

- the zokor commit or version, the slang version (`slangc --version`), and
  the OS and architecture;
- the smallest service, or the exact request bytes, that shows it;
- what you expected, what happened, and what you think an attacker gains.

We will acknowledge the report, keep you informed while we work on it, and
credit you in the fix unless you would rather we did not. Please give us a
reasonable chance to fix a problem before you publish it.

## What counts as a vulnerability

In scope, in zokor's own code (`zokor/`):

- **Anything a client can send** that gets past a check zokor claims to make:
  routing and path handling (traversal in static files), body and upload
  limits, multipart parsing, JSON decoding, the WebSocket and Socket.IO
  protocols, rate limits, idempotency keys, conditional requests.
- **Authentication and secrets**: bearer tokens, API keys, Basic, JWT
  verification, signed cookies, CORS, trusted-proxy handling of
  `X-Forwarded-For` and `Forwarded`, and secrets reaching a log or a client.
- **TLS termination** configuration (`TLS_*`), and mutual TLS.
- **A small request that costs disproportionate CPU or memory**, or holds a
  connection, a session or a queue past the limit that should bound it.
- **Injection** through the Postgres helpers, migrations, or the Mongo
  sanitiser.

Not in scope:

- Bugs in a service's own logic, or a service that turns off a protection
  zokor turns on by default (security headers, sanitising, limits).
- Problems in slang itself (the compiler, the runtime, `http`, `net`, TLS
  verification): report those to slang, through
  <https://github.com/dolphlabs/slang/security/advisories/new>.
- Problems in OpenSSL, Postgres or Redis themselves; report those upstream.
