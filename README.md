# Split Route for macOS

A VPN app for macOS with routing lists. Connect a tunnel, then decide per list whether its traffic goes direct,
is blocked, or goes through a tunnel, and pick a specific tunnel for each list if you run several. Tunnels run in
the engine from [`split-route/core`](https://github.com/split-route/core) (sing-box in-process); OpenVPN profiles
work today, more protocols follow.

- `app/`: the menu bar app (Swift, macOS 13+; the Liquid Glass look needs macOS 26).
- `daemon/`: the service (Go). It runs as root because the tunnel device needs it, holds your tunnels, lists and
  settings, and talks to the app over a unix socket. Credentials stay in the Keychain and in the service's memory.

Lists come from [routing-rules](https://github.com/aliraghebi/routing-rules), from a URL you import, or are your
own. An imported or release list is only ever applied after it parses and passes its size and checksum checks.

## Build

```sh
./build-app.sh                # build/Splitroute.app and build/Splitroute.dmg
VERSION=0.1.0 ./build-app.sh
```

Needs Xcode (macOS 26 SDK) and Go. The app is ad-hoc signed, not notarized: macOS asks you to allow it once
(System Settings > Privacy & Security), and the service under Login Items.

## Develop

The daemon depends on the core as a Go module. To work on both side by side, put them in one folder with a
`go.work`:

```
split-route/
  core/    macos/    go.work   # go 1.27.1; use ./core ./macos/daemon
```

Verify:

```sh
cd daemon && gofmt -l . && go vet ./... && go test -race ./...
cd app && swift build
```

See `CLAUDE.md` for the rules the code keeps.

## License

GPL-3.0-or-later. The service embeds sing-box, which carries the same license plus a clause that no derivative
may use the name "sing-box"; this project does not.
