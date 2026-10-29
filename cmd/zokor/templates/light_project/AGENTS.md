# AGENTS.md -- __service__

A small zokor service in slang. Read this before changing anything.

## Commands

- `make test`: run every package's tests; `make check`: check, test and build.
- `make run`: build and serve using configuration from `.env`.
- `zokor check [--json]`: check the service layout and configuration rules.
- `zokor newcomp <name>`: generate the component-based service with an example
  feature; use `zokor add feature <name>` there to add another feature.
- `slangc doc zokor <name>`: read one item of zokor's API documentation.

## Layout

```
src/main.sl                    startup: configuration, router and server
src/platform/config/settings.sl settings read once at startup
```

## Rules

- Configuration is read once in `platform/config`; pass settings to the router.
- Keep startup wiring in `src/main.sl` and reusable setup in `src/platform/`.
- Keep request handling in a package, with tests beside each package's code.
- Comments say why, not what.
