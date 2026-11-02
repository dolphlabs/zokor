# The zokor command

> Install and use the zokor command: scaffold services and features, check the layout, rebuild on save, and apply migrations.

## The zokor command

`zokor` is a separate tool,
[zokor_cli](https://github.com/dolphlabs/zokor_cli). It needs slang 0.2.4
or later, git and make; with slang 0.2.5 or later, watch mode uses slang's
development builds, which rebuild several times faster.

```
curl -fsSL https://raw.githubusercontent.com/dolphlabs/zokor_cli/main/install.sh | sh
```

This builds the latest release with your `slangc` and installs it as
`~/.local/bin/zokor`. `PREFIX` puts it somewhere else, and
`ZOKOR_CLI_VERSION=v0.2.2` picks a release. From a checkout of zokor_cli,
`make install PREFIX=~/.local` does the same. `zokor version` prints the
CLI's version and the zokor release new projects pin.

```
zokor version               this CLI, and the zokor release new projects pin
zokor new <name>            a small service: startup, config, a health check
zokor newcomp <name>        the full layout, with a sample feature
                            [--db memory|pg]
zokor add feature <name>    a new slice, wired in [--entity <singular>]
zokor add route <feature> <METHOD> <path> <handler>
zokor check [--json]        the layout rules, run from the service's root
zokor start                 build into bin/app and run it in the foreground
zokor watch [--release]     rebuild and restart on every save
zokor migrate [directory]   apply migrations (default: migrations)
```

`new` and `newcomp` also take `--zokor-git URL` and `--zokor-tag TAG` to
pin a zokor other than the release the CLI was built against. A generated
project's `Makefile` wraps the common ones: `make dev` is `zokor watch`,
`make check` is `zokor check` plus the tests and a build, and `make run`
builds and runs without the CLI.

`add feature` and `add route` need a project made by `newcomp`: they
insert the new code at its `// zokor:` markers, and a `new` project has
none. Both run from the service's root, and `add feature` refuses a name
that already exists.

### Checking a service

`zokor check` always enforces the layout, imports, pure `domain` and
`service`, `pg` only in `store/` and `platform/db`, literal SQL,
configuration read once, and tests beside every package. Two rules are
opt-in, one per line of a `zokor.rules` file at the service's root:

```
tenant                  # every public use case in service/ takes tenant_id
auth require_session    # every server.sl calls this guard (default
                        # require_tenant) or says // zokor:public
```

### Running and watching

`zokor start` finds `src/main.sl` (or `main.sl`), builds it into
`bin/app` and runs it in the foreground. `zokor watch`, the same as
`zokor start --watch`, keeps it running while you edit:

- It compiles beside the running server, into `.zokor/watch/app.next`,
  and swaps only when the build succeeds. A compile error is printed and
  the previous server keeps serving.
- A restart sends `SIGTERM` to the server's process group and kills it
  if it has not exited after two seconds, then starts the new build.
- A save during a build cancels that build and starts another, so the
  server never runs code older than your last save.
- If the server crashes, the watcher waits for the next save instead of
  restarting it in a loop.
- Builds are unoptimized and compile about ten times faster;
  `--release` builds optimized.

Both take `--entry <path>`, `--bin <path>`, `--verbose`, and arguments
for the service after `--`, as in `zokor watch -- --port 9000`.
`--debounce <ms>` (default 50) sets how long `watch` waits for a burst of
saves to settle.

### Migrations from the command line

`zokor migrate [directory]` applies a service's migrations with
`DATABASE_URL` from the environment; see [Migrations](#migrations) for
the file rules and limits.
