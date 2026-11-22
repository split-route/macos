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
| `app/Sources/Splitroute/` | Swift app (SwiftPM, macOS 14+): AppKit status item with a SwiftUI popover (`MenuPopover.swift`), the window (`SettingsView.swift`: Tunnels, Lists, Status, Settings); socket client in `Daemon.swift` |
| `app/Sources/Design/` | The look: tokens (`Tokens.swift`), Instrument Sans, controls and rows. The app and `DesignPreview` both use it; `Screens.swift` is the preview's fake-data pages only |
| `app/Sources/DesignPreview/` | `swift run DesignPreview [--snapshot <dir>]`: every screen and state on fake data, light and dark |
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
- One switch and one selected tunnel (`vpn_on`, `selected_tunnel_id` in `settings`; `vpn.go`). The engine runs once
  while the VPN is on; the selected tunnel is its default and carries all traffic no list names. Choosing another is
  `Engine.Select` on the core's `selected` selector, never a restart. `reconcile` decides what the engine loads:
  every non-OpenVPN tunnel, the selected one, and each OpenVPN tunnel a list names (a loaded OpenVPN tunnel is a real
  session). If the selected tunnel can't be loaded (waits for credentials, failed) the engine stops and traffic goes
  direct: never through another tunnel; the UI says so. A tunnel that failed is not reloaded until the user switches
  the VPN or selects it. The selected tunnel can't be removed while the VPN is on. A restart (a list or tunnel
  change) takes well under a second for proxy tunnels, so the host's settle time is 250 ms.
- Tunnels other than OpenVPN come from `core/importers/links` (share links, base64 lists, sing-box JSON). A
  tunnel's options hold its password or key: they are `tunnels/<id>/options.json` (0600), hash-checked before every
  start, never in the database or an API answer. A subscription's URL carries the user's token: it is
  `subscriptions/<id>/url` (0600). Errors from fetching one name the host only, never the path or query
  (`TestSubscriptionErrorsDoNotLeakTheAddress`); https only; 8 MB body limit. A subscription is a group of tunnels
  (`subscription_id`); removing it removes its tunnels, refused while a list uses one. Tunnels with no session
  of their own report `ready`, never `connected`.
- The core is a Go workspace sibling during development (`../go.work`); once released, `daemon/go.mod` requires a
  tagged version. Build the service with the core's tags (`core.RequiredTags`).
- UI uses `Design` tokens and components, never raw colors; custom controls need an accessibility label and visible
  keyboard focus. Tunnels have no colors in the app (the selected one has a tick); `Design` still has the line
  colors for the preview's older screens. The font is registered from
  `Contents/Resources/Fonts` (`build-app.sh` copies it); never touch `Bundle.module` inside the app.
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

There is no release workflow yet: build with `VERSION=X.Y.Z GOWORK=off ./build-app.sh`, tag `vX.Y.Z`, and attach
`build/Splitroute.dmg` (named `Splitroute_<version>_macos.dmg`) to a GitHub release. The app is ad-hoc signed,
not notarized (no Apple Developer account).
