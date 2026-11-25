# CLAUDE.md

`split-route/macos`: the macOS app for Split Route, a VPN app with routing lists. A Swift menu bar app
(`app/`) owns every setting and talks over a unix socket to a small Go service (`daemon/`) that runs as root,
because the tunnel device needs it. The service is the network layer and nothing else: it keeps no database,
settings, tunnels or lists on disk. It hosts the cross-platform engine from
[`split-route/core`](https://github.com/split-route/core) (sing-box in-process). The app sends the whole desired
state as a snapshot; the service runs it. This is the shape a Network Extension needs: when the project has an
Apple developer account the service becomes an extension and the app stays as it is. It runs as root, so
correctness and safety beat features.

## Layout

| Path | Role |
|------|------|
| `daemon/` | Go module `github.com/split-route/macos/daemon`. `main.go` (flags, lock, socket), `app.go` (boot ID, status, loop), `apply.go` (a snapshot becomes what the host runs), `host.go` (runs the core engine for the tunnels the app wants), `parse.go` (stateless parsers the app asks for, and the one-shot legacy export), `legacy.go` (one-time cleanup of what 0.x left), `killswitch.go` (the pf anchor) |
| `daemon/internal/api/` | Control socket: one JSON request and response per connection; wire types and the snapshot's validation |
| `app/Sources/Splitroute/` | Swift app (SwiftPM, macOS 14+): AppKit status item with a SwiftUI popover (`MenuPopover.swift`), the window (`SettingsView.swift`: Home, Servers, Routing, Settings). `AppModel*.swift` is the model, `ServiceLink.swift` builds and sends the snapshot, `Daemon.swift` is the socket client and wire types, `Fetch.swift` downloads, `LegacyMigration.swift` moves 0.2 data over |
| `app/Sources/Splitroute/Store/` | The settings database (SQLite via GRDB): `Schema.swift` (migrations), `Store*.swift` (queries, edits), `ConfigRules.swift` (validation, pure list edits, presets, catalog), `Secrets.swift` (0600 files) |
| `app/Sources/Design/` | The look: tokens (`Tokens.swift`), Inter, controls and rows. The app uses it; `Screens.swift` holds `Destination` and `Sidebar` (used) plus old fake-data screens (unused) |
| `build-app.sh` | Builds `Splitroute.app` and the DMG; the service binary embeds the engine, nothing else is bundled |

The binary and the launchd label keep their old names (`splitroute`, `io.github.aliraghebi.splitroute`) so an
updated app finds its service. The `watch` argument starts the service.

## Rules

- The service never starts a program for tunnels: the engine is a library. It runs commands in two places:
  `legacy.go` (cleanup of routes and DNS an older version left; only `/sbin/route`, `/sbin/ifconfig`,
  `/usr/sbin/scutil`, only commands recorded as safe to fail, and only prefixes that parse) and `killswitch.go`
  (only `/sbin/pfctl`, on the anchor `com.apple/250.splitroute`, with a fixed ruleset: the only input is the LAN flag).
- The service keeps nothing: no database, no profiles, no credentials on disk (one exception: the kill switch's marker file, below). A restarted service knows nothing
  until the app sends the snapshot, so the app sends it whenever `status.boot_id` changes and after every change.
  Until then, and whenever the app isn't running after a reboot, traffic goes direct. `apply` is idempotent.
- `apply` takes the whole state (`Snapshot`: VPN switch, lists on/off, selected tunnel, tunnels, lists with their
  entries, `retry`). The service validates it (`Snapshot.Validate`: IDs become tags and file names, so they are
  checked; list IDs are derived by the service from the name, never taken from the socket). An OpenVPN tunnel
  carries its profile and the service builds the options from it again; a proxy tunnel carries engine options,
  which the core refuses if they name a file (`*_path`) or steer the engine's own traffic (`deniedKeys`), at any depth.
  Never accept raw options for OpenVPN or skip the core's check.
- The host (`host.go`) keeps these, each with a test: credentials stay in memory while a tunnel is wanted; a
  failed tunnel is dropped with its credentials at once and **stays failed until a snapshot names it in `retry`**
  (retrying bad credentials locks accounts; the app re-sends the same snapshot on every change, so this is the
  guard); one bad tunnel fails alone; changes are applied after a settle time so a burst is one restart; the API
  answers from the engine's `Status`, events only prompt a re-read; a list naming a tunnel that isn't connected is
  blocked, never sent elsewhere. `apply.go` adds: a tunnel whose source is unchanged is left alone, a rename is
  done in place, tunnels the app dropped are forgotten.
- Settings live only in the app's database (`~/Library/Application Support/Splitroute/splitroute.db`, 0600). Every
  write goes through `Store.update`, which validates (`Config.validate`) in the same transaction. Socket: root:admin
  0660 (any admin-group process can drive the service and read what `legacy_export` returns once).
- Schema changes: a new entry at the end of `Schema.migrations`, never edit an applied one. A migration that
  rebuilds a table starts with the `foreign_keys=off` marker (the runner copies the database to `<db>.v<N>` first).
  A newer schema or a failed `quick_check` is refused, never reset. The schema is the one the service used to
  own (0001-0006; the app's start at 0007: the kill switch, bootstrap, and the `none` list action), so a 0.2 database is copied whole (`LegacyMigration.copyDatabase`, SQLite's backup) and the
  root-only files come from the service once through `legacy_export`; the old files are never deleted.
- A tunnel's profile or options (they hold keys and passwords) are 0600 files under `Application Support/Splitroute/tunnels/<id>/`,
  never in the database; the hash stored at import is checked before every send. A subscription's address carries
  the user's token: `subscriptions/<id>/url` (0600). Errors from fetching one name the host only, never the path or
  query (`testErrorsDoNotLeakTheSubscriptionAddress`); https only; 8 MB body limit. The app does all downloads
  (release lists with SHA256SUMS, imports, subscriptions); the service never fetches.
- `test` measures the loaded tunnels, OpenVPN included but never started just for it (one request to a fixed URL through each, 8 at a time, 5 s each) via the core's
  `Engine.Test`; the URL is the daemon's, never the socket's. The app turns the VPN on first if it is off; it asks for one tunnel per call, 8 calls at a time, and shows the time or "Timeout" on
  each row as its result arrives.
- The parsers stay in the core, so the app asks the service (`check_profile`, `parse_links`, `parse_entries`,
  `canon_entries`). The app never parses entry syntax itself: it canonicalizes through the service, then edits
  canonical lines (`ConfigRules.swift`).
- Credentials live in the app (`TunnelSecrets.swift`: 0600 files under Application Support for now) and in the
  service's memory while a tunnel is wanted; never in the service's disk, in logs or in status.

- Wire types in `Daemon.swift` mirror the Go JSON (`daemon/internal/api/types.go`); change both together. The
  snapshot's shape is pinned by one golden JSON in `ServiceLinkTests` and `TestSnapshotFromTheApp`.
- Kill switch (`kill_switch`, `kill_switch_lan` in `settings`; `Snapshot.KillSwitch`, `KillSwitchLAN`; `killswitch.go`). While
  the VPN is on and the setting is on, a pf anchor blocks every outbound packet except loopback, the engine's tun (matched by its source subnet `ksTunNet`, because Apple's pf doesn't match `on utun` against `utunN`),
  root's TCP/UDP (the engine: tunnel servers and direct lists), IPv6 neighbor discovery and, if asked, the LAN. The
  rules live in the kernel, so a dropped tunnel, a stopped engine, a dead service or a quit app **block** instead of
  leaking: this overrides "traffic goes direct" below. `Apply` is the only owner, it arms *before* the engine starts (an
  arm failure fails the apply, the VPN doesn't start), re-loads the rules on every apply (undoes an outside flush), and
  removes them only when the VPN switch or the setting goes off (a failed tunnel, an engine error or a failed apply never
  do). A restarted service doesn't know what the last run left, so its first "off" flushes once. The `pfctl -E` token is
  kept to release only our own enable reference (never `pfctl -d`). Way out: turn it off in the app, or `sudo splitroute
  killswitch off` (the app re-arms on its next change unless its setting is off). It survives a reboot: while the rules
  should be in force the service keeps one marker file (`<state>/killswitch`, `lan` or `nolan`, 0600, written before the rules are
  loaded: no marker, no arm), loads the rules again first thing at start (`restore`, before any snapshot; an unreadable marker
  arms without the LAN) and removes the marker only after the flush succeeds. So after a reboot the network is blocked until
  the app connects the VPN. The app turns the setting off before it uninstalls the service. Root-owned sockets bypass it (pf matches users, not programs). A Network Extension
  (`includeAllNetworks`) replaces `killswitch.go`.
- `bootstrap` (`settings.bootstrap`, `Snapshot.Bootstrap`, API rev 5; automatic since rev 10) is how proxy tunnels' server names are found: empty is automatic (`bootstrap.go`: as the connection comes up the service sends one DoH query to each of 1.1.1.1, 8.8.8.8 and 9.9.9.9 and takes the first that answers, in that order, else the system resolver; kept until the connection goes down; never probed while the engine runs, because the tun would make every resolver look reachable), a DoH server's IP, or `system`. It is a setting because a network can reset DoH to one provider
  (every tunnel then fails with "connection reset by peer" from the engine's own lookup). The service validates it; a change
  restarts the engine, and the app adds `retry` so tunnels that failed on the lookup are tried again.
- One switch and one selected tunnel (`vpn_on`, `selected_tunnel_id` in `settings`; `desiredTunnels` in `apply.go`). The engine runs once
  while the VPN is on; the selected tunnel is its default and carries all traffic no list names. Choosing another is
  `Engine.Select` on the core's `selected` selector, never a restart. `reconcile` (in `apply.go`) decides what the engine loads:
  every non-OpenVPN tunnel, the selected one, and each OpenVPN tunnel a list names (a loaded OpenVPN tunnel is a real
  session). If the selected tunnel can't be loaded (waits for credentials, failed) the engine stops and traffic goes
  direct (blocked, with the kill switch on): never through another tunnel; the UI says so. A tunnel that failed is not reloaded until the user switches
  the VPN or selects it (the app adds `retry`). The selected tunnel can't be removed while the VPN is on. A restart (a list or tunnel
  change) takes well under a second for proxy tunnels, so the host's settle time is 250 ms.
- Tunnels other than OpenVPN come from `core/importers/links` (share links, base64 lists, sing-box JSON), through
  `parse_links`. A subscription is a group of tunnels
  (`subscription_id`); removing it removes its tunnels, refused while a list uses one. Tunnels with no session
  of their own report `ready`, never `connected`.
- The core is a Go workspace sibling during development (`../go.work`); once released, `daemon/go.mod` requires a
  tagged version. Build the service with the core's tags (`core.RequiredTags`).
- Theme (Settings > General: System, Light, Dark; `Theme.swift`, defaults key `theme`) is `NSApp.appearance`; nothing else forces an appearance, and `Backdrop` and `Glass` adapt (light: frosted white over the blur, dark rules). The window is liquid glass: non-opaque. In dark: the content and the sidebar are two `Backdrop` layers (the
  desktop behind, blurred by an `NSVisualEffectView`, darkened: the content darker and blurrier, the sidebar lighter),
  so the wallpaper tints them faintly and nothing behind is readable. `Accent` is the one color (switches, ticks,
  primary buttons, the shield). Lit things use `AccentSurface` (gradient, gloss, rim, glow); the selected sidebar item
  is `LiquidSelection` (translucent blue with an inner glow and a glowing icon). Cards are `Glass` fills. Pages are
  transparent over the backdrop. Destination titles and icons live on `Destination`; its raw values are stored in the
  user's defaults, so they stay when a title changes ("Tunnels" is titled "VPN", "Lists" "Routing").
- UI uses `Design` tokens and components, never raw colors; custom controls need an accessibility label and visible
  keyboard focus. Tunnels have no colors in the app (the selected one has a tick); `Design` still has the line
  colors for its older unused screens. The font is registered from
  `Contents/Resources/Fonts` (`build-app.sh` copies it); never touch `Bundle.module` inside the app.
- A list's action can be `none` ("No Action"): kept with its entries, never put in the snapshot; a ready-made list with it isn't downloaded. Compare it as `Action.none`: a bare `.none` on an optional reads as `Optional.none`.
- Lists page downloads: `AppModel.downloads` holds a list's progress or failure; the row shows a ring with a percentage, or a red icon that retries.
- The final route (`settings.final_action`, `final_tunnel_id`; `Snapshot.Final`, API rev 6; the "Default Route" bar on the Routing page) is where traffic no list matches goes: direct, block, or a tunnel (none named: the selected one, the default and what older versions did). The app sends nothing for the default. The service gives it to the core (`Config.Final`; a change restarts the engine) and blocks it if it names a tunnel that isn't connected (like a list). It applies whether or not routing is on. The engine still needs the selected tunnel loaded, so "connected" with a direct final route means lists can use tunnels. A tunnel it names can't be removed.
- In the UI a tunnel is a **server** ("Servers", "Active Server"): VLESS, VMess and Trojan aren't tunnels to the people who use them. Code, the database, the API and the core keep "tunnel"; only user-facing strings changed. The one switch is called Connection (not VPN) in the UI: with a direct final route the tunnel can be up while most traffic is not in it. The tunnels page is "Tunnels".
- Home (`HomePage.swift`, the first page) shows the engine state, server, kill switch, default route and a one-minute speed chart. Speed is the byte counters of the engine's tun, found by its address (`TrafficMonitor.tunAddress`, same coupling as `ksTunNet`), read once a second while the window is open (the model owns the monitor, so the chart survives a visit to another page): no service call. It counts everything through the tun, direct traffic included, not only what a server carries.
- An OpenVPN profile's encrypted client key (PKCS#8 or OpenSSL's older PEM form) is opened by the core (`openvpn.DecryptKey`) with the password the app sends as `TunnelSpec.KeyPassword` (API rev 7); sing-box has no password option, so the engine gets the plain key, in memory only. A profile that needs the password and has none waits like one that needs a sign-in. The password sheet is the existing Credentials sheet.
- Lists can be a sing-box rule-set (`.srs`, binary) from a URL or a file: the app sends the bytes as `data` (base64) to `parse_entries` (API rev 8, up to 5 MB) and the core reads them (`core.RuleSetText`, sing-box's own reader) into the same entries a text list gives. What an entry can't say (keywords, regular expressions, inverted or logical rules, rules that also test ports or processes) is skipped and counted. The source JSON form of a rule-set is not read.
- Block QUIC (`settings.block_quic`, default on; `Snapshot.BlockQUIC`, API rev 9; a switch in Settings): the engine refuses QUIC (UDP 443) that no list matched, after every list, so a browser that hid a site's name inside HTTP/3 falls back to TCP, where the name is in the TLS handshake and a Block list matches. QUIC a list matched is untouched. The service ignores it while routing is off (no lists, no names to match). Changing it restarts the engine.
- Settings are grouped: General, Connection (server lookup, Block QUIC), Kill switch, System service, About, plus Warnings when the service has some. The Routing switch (Home, the menu bar panel, the top of the Routing page; `settings.disabled`, `Snapshot.ListsOn`) turns every list off at once and leaves only the default route, which applies either way; the Routing page dims and disables its lists while it is off. There are no presets, no release-URL field (`baseURL` stays in the config for `config import`) and no files section.
- The menu bar icon opens `MenuBarPanel` (`MenuPanel.swift`), not an NSPopover: a borderless non-activating panel that joins every Space and sits above full-screen windows (an NSPopover would not appear over a full-screen app, and its corners are the system's). Its content (`MenuPopover.swift`): Connection, Routing, Kill Switch and Default Route (the last three faded and inert while disconnected, like Home), then Open Splitroute and Quit. It closes on a click elsewhere, Esc or a Space change.
- Nothing slow runs on the main actor: the snapshot is built in a detached task (`ServiceLink.build`: database, saved files, list texts) and the socket call encodes and decodes off it (`Daemon.send`); `Store.read` reads entries only of custom lists (an import can hold hundreds of thousands of rows), import entry counts are cached by download hash, and `launchAtLogin` is a cached value (asking SMAppService on every redraw of Settings was an IPC each time). Keep it that way: a toggle must not wait for a file or a socket before it moves.
- Motion: the sidebar highlight slides between items (`matchedGeometryEffect`), pages cross-fade (0.18 s), dimmed cards, rows and the chart fade (0.25 s). Reduce Motion turns the slide off.
- Adding and editing a list are pages of the Routing section, not dialogs (`ListsPage.Route`: add, with tabs for ready-made, URL, file and custom; edit a custom list; edit an import), each with a "‹ Routing" link back; the views close themselves through `EnvironmentValues.closePage`.
- A custom list is a rule built from fields (`RuleSpec.swift`, the core's `RuleSpec`): the fields keep sing-box's own names and meaning (`domain`, `domain_suffix`, `domain_keyword`, `domain_regex`, `ip_cidr`, `port`, `port_range`, `process_name`, `process_path`, `process_path_regex`, `network`), plus the applications picked from Finder (matched as the bundle). `mode` is `or` (any field) or `and` (every field) and `invert` negates; the core compiles it to sing-box's binary rule-set (`core.CompileRules`), and the editor asks the service to check every value (`check_rules`) before saving. Not offered, because they don't mean anything here: the source address and port (the tun is the only source), Wi-Fi name and network type (macOS gives them only to apps with location permission), package names (Android). The rule is JSON in `lists.builder`; migration 16 turned the old entries into fields.
- A rule-set (a sing-box `.srs` or its JSON source) imported from a URL or a file is kept exactly as it is (`lists.ruleset`, the binary the service checked with `check_ruleset`; a binary one comes back unchanged) and handed to the engine as a binary rule-set, so everything sing-box can run in one works: invert, logical rules, AdGuard rules, process rules. It is not edited as fields. Plain text lists (hosts files, domain lists) are still entries (`entries` rows, text imports) or, from a file, the fields of a rule. API rev 12.
- An OpenVPN server can be overridden (`tunnels.server_override`, migration 17; "Edit…" in the server's menu, the same dialog that asks for credentials): "host", "host:port" or "[v6]:port" replaces every `remote` line of the profile when the snapshot is built (`OvpnProfile.overridingServer`; the first remote's port and protocol are kept when none is given), so the service sees a different profile and reconnects. The profile file and its stored hash are never changed.
- Every bug fix gets a table test; parsers get a fixture copied from real output.
- English only in code, comments, commits and logs.

## Verify

```sh
cd daemon && gofmt -l . && go vet ./... && go test -race ./...
cd daemon && go test -race -tags with_gvisor,with_quic,with_utls,with_wireguard,with_openvpn ./...   # plus the live host test with SPLITROUTE_TEST_PROFILE
cd app && swift build && swift test
./build-app.sh
```

## Release

There is no release workflow yet: build with `VERSION=X.Y.Z GOWORK=off ./build-app.sh`, tag `vX.Y.Z`, and attach
`build/Splitroute.dmg` (named `Splitroute_<version>_macos.dmg`) to a GitHub release. The app is ad-hoc signed,
not notarized (no Apple Developer account).

## Planned (needs an Apple developer account)

One step, taken together: sign the app with a developer ID, then
- turn the service into a Network Extension (`NEPacketTunnelProvider`, App Group container; the snapshot becomes
  `providerConfiguration` plus `sendProviderMessage`, `apply.go` and `host.go` move in as they are);
- turn `TunnelKeychain.useKeychain` on and move the saved credentials (and ideally profile and options files, and
  subscription addresses) into the Keychain: the stable signature stops the per-build prompts that make it unusable
  now. Until then these are user-readable 0600 files.
