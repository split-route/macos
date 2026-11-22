# CLAUDE.md

`split-route/macos`: the macOS app for Split Route, a VPN app with routing lists. A Swift menu bar app
(`app/`) talks over a unix socket to a small Go service (`daemon/`) that runs as root, because the tunnel
device needs it and tunnels connect at boot. The service hosts the cross-platform engine from
[`split-route/core`](https://github.com/split-route/core) (sing-box in-process). Storage of tunnels, lists and
settings is this app's job, not the core's. It runs as root, so correctness and safety beat features.

## Layout

| Path | Role |
|------|------|
| `daemon/` | Go module `github.com/split-route/macos/daemon`. `main.go` (flags, lock, socket), `app.go` (settings database, list refresh, loop, `api.Backend`), `host.go` (runs the core engine for the tunnels the user connects), `tunnels.go` (stored profiles and the tunnel operations), `lists.go`, `imports.go`, `legacy.go` (one-time cleanup of what 0.x left) |
| `daemon/internal/api/` | Control socket: one JSON request and response per connection; wire types |
| `daemon/internal/config/` | `Config`, `Validate`, presets, pure list edits |
| `daemon/internal/store/` | Settings database (SQLite): schema in `migrations/*.sql`, imports, tunnels |
| `daemon/internal/catalog/` | Titles and descriptions of the release lists (content, not engine) |
| `app/` | Swift app (SwiftPM, macOS 13+): AppKit status item, SwiftUI settings; socket client in `Daemon.swift` |
| `build-app.sh` | Builds `Splitroute.app` and the DMG; the service binary embeds the engine, nothing else is bundled |

The binary and the launchd label keep their old names (`splitroute`, `io.github.aliraghebi.splitroute`) so an
updated app finds its service. The `watch` argument starts the service.

## Rules

- The service never starts a program for tunnels: the engine is a library. The one place it runs commands is
  `legacy.go` (cleanup of routes and DNS an older version left; only `/sbin/route`, `/sbin/ifconfig`,
  `/usr/sbin/scutil`, only commands recorded as safe to fail, and only prefixes that parse).
- The host (`host.go`) keeps these, each with a test: credentials stay in memory while a tunnel is wanted; a
  failed tunnel is dropped with its credentials at once (retrying bad credentials locks accounts); one bad tunnel
  fails alone; changes are applied after a settle time so a burst is one restart; the API answers from the
  engine's `Status`, events only prompt a re-read; a list naming a tunnel that isn't connected is blocked,
  never sent elsewhere.
- Settings live only in the database (`/var/db/splitroute/splitroute.db`, 0644, rollback journal). Every write
  goes through `store.Update`/`Init`, which run `Config.Validate` in the same transaction. Socket: root:admin
  0660.
- Schema changes: a new numbered file in `daemon/internal/store/migrations/`, never edit an applied one. A
  migration that rebuilds a table starts with the `foreign_keys=off` marker (the runner checks
  `foreign_key_check` and copies the database to `<db>.v<N>` first). A newer schema or a failed `quick_check` is
  refused, never reset.
- Profiles are 0600 files under `<state dir>/tunnels/<id>/`, never in the database (world-readable); the hash
  stored at import is checked before every start; the daemon never opens a path from a profile or the socket.
  Profiles that run scripts, or that the core can't translate, are refused at import, naming the directive.
- Credentials live in the macOS Keychain (the app) and in the service's memory while a tunnel is wanted; never on
  disk, in logs or in status.
- Wire types in `Daemon.swift` mirror the Go JSON (`daemon/internal/api`); change both together. The app edits
  lists with the per-list commands, never `set_config` from a stale copy.
- The core is a Go workspace sibling during development (`../go.work`); once released, `daemon/go.mod` requires a
  tagged version. Build the service with the core's tags (`core.RequiredTags`).
- Every bug fix gets a table test; parsers get a fixture copied from real output.
- English only in code, comments, commits and logs.

## Verify

```sh
cd daemon && gofmt -l . && go vet ./... && go test -race ./...
cd daemon && go test -race -tags with_gvisor,with_quic,with_utls,with_wireguard,with_openvpn ./...   # plus the live host test with SPLITROUTE_TEST_PROFILE
cd app && swift build
./build-app.sh
```

## Release

Push a `vX.Y.Z` tag; the release workflow builds `Splitroute_<version>_macos.dmg` and updates the cask. The app
is ad-hoc signed, not notarized (no Apple Developer account).
