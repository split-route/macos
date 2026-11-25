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
| `app/Sources/Splitroute/` | Swift app (SwiftPM, macOS 14+): AppKit status item with a SwiftUI popover (`MenuPopover.swift`), the window (`SettingsView.swift`: Home, Servers, Routing, and the Settings group: General, Connection, Updates). `AppModel*.swift` is the model, `ServiceLink.swift` builds and sends the snapshot, `Daemon.swift` is the socket client and wire types, `Fetch.swift` downloads, `LegacyMigration.swift` moves 0.2 data over |
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
  (release lists with SHA256SUMS, imports, subscriptions); the service fetches only the two fixed address-lookup URLs below, through the selected server, and nothing else.
- `test` (API rev 13) takes a method, an address and a timeout from the app, and the service validates all three (`api.TestOptions`): the address is https only
  (no other scheme, no credentials in it, 2048 bytes) and the timeout is clamped to 1-30 s. A free-text address is allowed on purpose (Settings > Connection has presets and
  a field): the socket is root:admin 0660, so any admin-group process can make root request an https address through a tunnel; that is the accepted cost. `connect`
  (default) is one request through each loaded tunnel via the core's `Engine.Test` (OpenVPN included but never started just for it; with no address given the service uses its own, an IP address for OpenVPN, whose name would be looked up through the selected tunnel; the app sends none for OpenVPN when the user's address is a preset). The app turns the VPN on first if it is off. `tcp` and `icmp` time the tunnel's own server, outside the tunnel
  (`probe.go`): they need no engine and the app doesn't turn anything on. The server's address comes from the last snapshot (`core.TunnelEndpoint`; OpenVPN's from its profile again), so a tunnel
  that isn't loaded can be tested. While the engine runs, its tun takes the Mac's traffic, so the sockets are bound to the physical interface (`IP_BOUND_IF`, the interface of the original
  default route, `probe_darwin.go`) and a server name is asked of the bootstrap resolver over DoH from that interface, never the system resolver. TCP is "UDP only" for WireGuard, Hysteria, TUIC and OpenVPN over UDP.
  ICMP is "Blocked by the kill switch" while it is armed (the pf rules pass root's TCP and UDP only); don't widen the pf ruleset for it. The app asks for one tunnel per call, 8 calls at a time, and shows the time or the reason on each row as its result arrives.
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
- Home (`HomePage.swift`, the first page) shows the engine state, the Routing, Default Route and Kill switch cards, the server and the IP address the world sees through it (with its flag), and a one-minute speed chart. Speed is the byte counters of the engine's tun, found by its address (`TrafficMonitor.tunAddress`, same coupling as `ksTunNet`), read once a second while the window is open (the model owns the monitor, so the chart survives a visit to another page): no service call. It counts everything through the tun, direct traffic included, not only what a server carries.
- An OpenVPN profile's encrypted client key (PKCS#8 or OpenSSL's older PEM form) is opened by the core (`openvpn.DecryptKey`) with the password the app sends as `TunnelSpec.KeyPassword` (API rev 7); sing-box has no password option, so the engine gets the plain key, in memory only. A profile that needs the password and has none waits like one that needs a sign-in. The password sheet is the existing Credentials sheet.
- Lists can be a sing-box rule-set (`.srs`, binary) from a URL or a file: the app sends the bytes as `data` (base64) to `parse_entries` (API rev 8, up to 5 MB) and the core reads them (`core.RuleSetText`, sing-box's own reader) into the same entries a text list gives. What an entry can't say (keywords, regular expressions, inverted or logical rules, rules that also test ports or processes) is skipped and counted. The source JSON form of a rule-set is not read.
- Block STUN (`settings.block_stun`, default on) and the default TLS fingerprint (`settings.tls_fingerprint`, default "" = each server's own), migration 18, `Snapshot.BlockSTUN` and `Snapshot.TLSFingerprint`, API rev 14, both on Settings > Connection. STUN is refused by the core's rule (see `core/CLAUDE.md`), whether or not routing is on, so a browser can't show the real address (WebRTC) while its traffic goes through a server; the cost is that browser video calls may need a TURN server. The fingerprint names are the core's (`core.TLSFingerprints`, mirrored in `Config.tlsFingerprints`); the service validates it, and a change restarts the engine like Block QUIC.
- Block QUIC (`settings.block_quic`, default on; `Snapshot.BlockQUIC`, API rev 9; a switch in Settings): the engine refuses QUIC (UDP 443) that no list matched, after every list, so a browser that hid a site's name inside HTTP/3 falls back to TCP, where the name is in the TLS handshake and a Block list matches. QUIC a list matched is untouched. The service ignores it while routing is off (no lists, no names to match). Changing it restarts the engine.
- Settings are pages in the sidebar's "Settings" group (`Destination.settingsPages`): General (`GeneralSettingsPage`: theme, open at login, quit action, global shortcut, system service, About, Warnings when the service has some), Network (`NetworkSettingsPage`: kill switch, Block IPv6, failover, Always on, Test, Sort by ping), Advanced (`AdvancedSettingsPage`: how server names are found, Block QUIC, Block STUN, TLS fingerprint: what a network or a site may need changed, with safe defaults) and Updates (`UpdatesSettingsPage`: subscriptions, routing lists). A new category is one `Destination` case, one page and one line in each of the two sidebars (the ⌘ shortcuts follow `allCases`). Settings that belong to one feature stay on that feature's page. The Routing switch (Home, the menu bar panel, the top of the Routing page; `settings.disabled`, `Snapshot.ListsOn`) turns every list off at once and leaves only the default route, which applies either way; the Routing page dims and disables its lists while it is off. There are no presets, no release-URL field (`baseURL` stays in the config for `config import`) and no files section.
- Block IPv6 (`settings.block_ipv6`, default on, migration 19, `Snapshot.BlockIPv6`, API rev 15): the tun carries IPv4 only, so with it off a dual-stack network sends IPv6 around the VPN and a site shows the real address. With it on the core gives the tun an IPv6 address (the system then sends IPv6 into it), rejects `ip_version: 6` after the LAN rule and answers apps' AAAA questions empty with a DNS rule (`predefined`, NOERROR). The engine's own lookups of servers' names name their resolver and skip DNS rules (checked in sing-box's `Router.Lookup`), so servers on IPv6-only networks are still found: never set a global `dns.strategy: ipv4_only` for this. There is no "tunnel IPv6" mode: it would need the kill switch's pf ruleset widened for a v6 tun subnet. With the kill switch on, IPv6 from the tun is blocked by pf as well, which is the same result.
- `route_test` (the "Test a domain or address" box on Routing): the service walks the route rules that `core.Build` makes (so the order is the engine's own) for a TCP connection to a validated name or IP, reading the lists' rule-set files where the engine reads them, and says which list decides and the action. It uses the servers' names from the last snapshot with placeholder options (no profile or key is read), so it answers for "once connected" too. It says what it can't show: a name isn't resolved, program and sniffed-protocol rules (QUIC, STUN) need a real connection.
- `exit_ip` (the IP address card on Home): the one place the service fetches. It asks the fixed URLs `exitURLs` (`routetest.go`; never from the socket), https only, through the selected server (`Engine.Fetch`), at most 16 KB, and only an address and a two-letter country code leave `parseExit`. The app draws the flag from the code and the country name from the system's locale. It is looked up when the connection comes up or the active server changes, with a few retries, never on every poll.
- Servers: a flag before the name (`Flags.swift`: an emoji already in the name or the group's, else a country name as a whole word, else a capital two-letter code from a list of common places; "WS" is Samoa's and is not on it), pin (favorites first, `tunnels.pinned`), note (`tunnels.note`, 200 characters), a test button per server, a latency filter (hides servers with no result while on), and quota colors (orange under 15 percent left, red under 5, "Used up" at 0). Pins and notes are the person's: `Store.sync` never writes them. The add-servers sheet reads QR codes from pictures (Vision: the Scan QR image button, a picture dropped on the box, or an image on the clipboard when the person presses Paste): the pasteboard is read only when the button is pressed.
- Failover (`AppModel+Failover.swift`, Settings > Network, off by default): while connected, one request through the active server every 30 s (the test's address and timeout; the second and third check follow within seconds); three misses in a row measure up to 24 other proxy servers (the same subscription first, never OpenVPN) and select the quickest, with the engine's `Select`, no restart. A proxy server never reports failed when its server dies (no session of its own), which is why it probes. It moves only the default selection: a list or the default route that names a server stays blocked while that server is down. A server just left is skipped for ten minutes; at most three switches per half hour.
- The global shortcut (`Hotkey.swift`, General): Carbon `RegisterEventHotKey` (no Accessibility permission; a global key monitor would need it), none until the person records one, needs ⌘, ⌥ or ⌃, and connects or disconnects.
- App updates (`AppUpdate.swift`, Settings > General > About): the app asks GitHub's releases API (`/repos/split-route/macos/releases/latest`, no token, https only) for the latest tag, once a day while it runs when "Check for updates automatically" is on (a failed check waits an hour), or when the user presses the button. It compares dotted numbers with the app's version (a dev build is never told to update) and only keeps the version and the release page (which must be on `github.com/split-route/macos`, else the releases page). Downloading and installing are the user's: the Download button, or "Download updates automatically" (on by default; only after an automatic check). The release carries `Splitroute_<v>_macos.zip` (made by `build-app.sh` with `ditto`, plus `.zip.sha256`) beside the DMG. `UpdateInstaller` downloads the zip to disk (`Application Support/Splitroute/Updates/<v>/`, 0700; https only, 400 MB cap, checksum checked), unpacks it with `ditto`, and `UpdateVerifier` accepts the app only if it satisfies the **running app's own designated requirement** (bundle ID plus certificate fingerprint, every file sealed, nested code and all architectures), is Splitroute at the release's version and is newer. An ad-hoc running app can't pin anything, so it never self-updates (it links to the release page); neither does a Homebrew install (the cask updates it), a translocated or unwritable copy. The staged app is checked again right before the swap. `install` starts `swap.sh` (the script lives in `UpdateInstaller.swapScript`, arguments are paths): it waits for the app to quit, copies the new app next to the old one, renames, rolls back on any failure and reopens the app; the service keeps running and the new app restarts it when its version differs. The menu bar panel shows "Install newer version" only once the download is staged. A newer version shows a green dot and "Newer version is available" under Open Splitroute in the menu bar panel (the icon is untouched), and a green dot with the version beside the Check button.
- App-side preferences (`Prefs.swift`, UserDefaults, never the snapshot or the database, because none changes what the engine runs): sort by ping, always on, disconnect on sleep (+ message), subscription and list auto update, the test method, timeout, result lifetime and address. The app acts on them while it runs (`AppModel+Automation.swift`), driven by the poll: nothing updates or connects after a quit.
  Auto update: subscriptions are due when their last good `updated_at` is older than the interval (or once at launch with "Update on open"); a failed one waits `min(interval, 15 min)` before the next try; `syncSubscription` keeps the selected server and any a list or the final route names, so a scheduled update never drops them. Lists: the release lists' interval is `Prefs.listsIntervalHours`; with auto update off only what the user asks for (or never tried) downloads; imports keep their own refresh time.
  Always on connects when the app opens and when the Mac wakes, if the switch is off, through `setVPN(_, automatic: true)`, which never adds `retry` (a failed server stays failed; retrying bad credentials locks accounts). Disconnect on sleep sets `ServiceLink.suspended` (the snapshot says off, the saved `vpn_on` is untouched, so a crash or quit mid-sleep still wakes connected) and clears it on wake; it does nothing while the kill switch is on, because the service removes the pf rules when the VPN is off and the Mac would wake with no network. The snapshot call at sleep is best-effort: macOS may sleep before the service applies it.
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

Push a tag `vX.Y.Z`: `.github/workflows/release.yml` tests the service, builds the app and the DMG with `build-app.sh` on `macos-26`, publishes the GitHub release
(a tag with a dash is a pre-release) and updates the Homebrew cask. It needs the secrets `SIGNING_P12_BASE64` (`base64 -i <backup>.p12`) and
`SIGNING_P12_PASSWORD` (the certificate from `scripts/make-signing-cert.sh`) and `TAP_TOKEN`; the build sets `REQUIRE_SIGNING_CERT=1`, so it fails instead of
signing ad hoc. By hand: `VERSION=X.Y.Z GOWORK=off ./build-app.sh`, which writes `build/Splitroute.dmg` (named `Splitroute_<version>_macos.dmg`). The app is signed with a self-signed certificate
(`scripts/make-signing-cert.sh`, once; `build-app.sh` uses it when it is in the keychain and signs ad hoc, with a warning, when not) and is not notarized (no Apple
Developer account). The certificate matters because an ad-hoc identity is the build's own hash: every update looks like a new app to the Keychain and to the service's
approval in Login Items. With the certificate the identity is the bundle ID plus the certificate's fingerprint, the same across builds. Keep the private key's
backup safe: if it leaks, anyone can sign as us; if it is lost, the next release changes identity again.

## Planned (needs an Apple developer account)

One step, taken together: sign the app with a developer ID, then
- turn the service into a Network Extension (`NEPacketTunnelProvider`, App Group container; the snapshot becomes
  `providerConfiguration` plus `sendProviderMessage`, `apply.go` and `host.go` move in as they are);
- turn `TunnelKeychain.useKeychain` on and move the saved credentials (and ideally profile and options files, and
  subscription addresses) into the Keychain: the stable signature stops the per-build prompts that make it unusable
  now. Until then these are user-readable 0600 files.
