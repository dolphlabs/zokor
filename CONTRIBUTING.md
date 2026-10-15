# Contributing to zokor

Thank you for wanting to help. This file is what you need to build zokor,
run its tests, and get a change merged. Read [AGENTS.md](AGENTS.md) too: it
holds the rules the framework exists to enforce, and they apply to changes to
the framework first.

By contributing you agree that your contribution is licensed under the
[MIT licence](LICENSE), like the rest of the project. Please sign your commits
off (`git commit -s`), which adds a `Signed-off-by:` line certifying the
[Developer Certificate of Origin](https://developercertificate.org/). Nothing
checks this automatically yet; we ask that you do it anyway.

Everyone taking part is expected to follow the [Code of
Conduct](CODE_OF_CONDUCT.md). To report a security problem, read
[SECURITY.md](SECURITY.md) and do not open a public issue.

## Build and test

zokor is a slang package, so you need `slangc`. zokor tracks slang's `dev`
branch (see *Requirements* in the README for what a release must contain):

```sh
git clone https://github.com/dolphlabs/slang && cd slang
git switch dev
sudo make install        # or PREFIX=~/.local
```

Building slang needs a C compiler and OpenSSL (macOS: `brew install openssl`;
Debian/Ubuntu: `apt install build-essential libssl-dev libsqlite3-dev
zlib1g-dev`). Then, in zokor:

```sh
slangc get               # fetch the pinned packages (jwt)
make test                # every package's suite
make check               # what CI runs: tests, examples, the guide's
                         # snippets, api.txt freshness, the CLI
```

The Postgres and Redis tests run against a live server when they can reach
one and say `skip` when they cannot. For Postgres, set
`ZOKOR_TEST_DATABASE_URL` (for example
`postgres://postgres:zokor@127.0.0.1:5432/zokor_test`); Redis is looked for on
`127.0.0.1:6379`.

Run one test, or the tests whose names contain a word:

```sh
slangc test zokor --run test_ws_ -v
```

**Run one `make test` at a time.** Runs share build directories, and two at
once produce failures that are not real.

## What a change needs

- **A test beside the code**, in the package's `*_test.sl`, as `fn test_*`.
  A new package gets its own line in the Makefile's `test` target: a package
  without one is a package with no tests, and that fails review.
- **For a bug fix, a test that fails without the fix.** Show it: run the test
  against the code before your change and say what it printed. A test that
  passes on the broken code proves nothing.
- **Measurements for performance claims**, taken before and after in ABBA
  order (old, new, new, old), with the spread. Allocations per request are
  the number that moves throughput here; `bench/allocs` counts them.
- **A changed public symbol regenerates `docs/api.txt`** (`make api`, then
  commit it on its own: `docs: regenerate api.txt for ...`). CI fails when it
  is stale.
- **The agent guide stays true.** `docs/llms-small.txt` is what an agent
  copies verbatim; every ```slang block in it must compile and run
  (`make snippets`).
- **Behaviour changes update the README** section they belong to, and
  `todo.md`: tick what landed, with a line on what is not done.

Changes that touch the serve loop, TLS, WebSockets or anything with tasks
and channels should be run on Linux and macOS: continuous integration runs
both on every pull request (Linux x86_64 and arm64, macOS arm64), or
dispatch it on a branch with `gh workflow run ci.yml --ref <branch>`.

## Workflow

- `main` is the release branch. Work is integrated on `dev`.
- **Branch each change from the current `dev`, one branch per task, and open
  the pull request against `dev`.** Do not build a branch on top of another
  unmerged one: if the first changes, the second is stranded.
- Commits are conventional (`feat(ws): ...`, `fix(serve): ...`), with a body
  saying what and why.
- Write the pull request description for someone who has not seen the
  conversation: what changed and why, the evidence (what failed before, what
  passes now), where you ran the suite, and anything you did not do.
- A change that needs something new in slang is made and merged in slang
  first (`[slang]` in `todo.md`); zokor's CI builds slang from `dev`.
