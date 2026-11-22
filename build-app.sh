#!/bin/sh
# Builds build/Splitroute.app: the Swift menu bar app (app/) and the Go service
# (daemon/, universal) in Contents/Resources, then a DMG. Ad-hoc signed; not
# notarized. The tunnel engine (sing-box) is inside the service binary: there is
# no separate engine to build, bundle or pin.
set -eu
cd "$(dirname "$0")"
VERSION=${VERSION:-dev}
APP=build/Splitroute.app
# The sing-box build tags the core needs (core.RequiredTags); without them the
# service starts but can't run a tunnel.
TAGS=with_gvisor,with_quic,with_utls,with_wireguard,with_openvpn

(cd app && swift build -c release --arch arm64 --arch x86_64)
BIN=$(cd app && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# SwiftPM records the deployment target as the SDK version, so AppKit would run
# the app in compatibility mode (no Liquid Glass on macOS 26+). Record the real SDK.
vtool -set-build-version macos 13.0 "$(xcrun --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/Splitroute" "$BIN/Splitroute"
sed "s/@VERSION@/$VERSION/g" app/Info.plist > "$APP/Contents/Info.plist"
swift app/assets/icon.swift "$APP/Contents/Resources/AppIcon.icns"

# The service. CGO off keeps it a single static-ish binary per architecture.
for arch in arm64 amd64; do
  (cd daemon && CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -trimpath -tags "$TAGS" \
    -ldflags "-s -w -X main.version=$VERSION" -o "../build/splitroute-$arch" .)
done
lipo -create build/splitroute-arm64 build/splitroute-amd64 -output "$APP/Contents/Resources/splitroute"
rm build/splitroute-arm64 build/splitroute-amd64

# Licenses of what the service contains. Split Route and sing-box are
# GPL-3.0-or-later; sing-box's license adds that no derivative may use its name.
LIC="$APP/Contents/Resources/Licenses"
mkdir -p "$LIC"
cp LICENSE "$LIC/SplitRoute.txt"
SINGBOX=$(cd daemon && go list -m -f '{{.Dir}}' github.com/sagernet/sing-box)
cp "$SINGBOX/LICENSE" "$LIC/sing-box.txt"
echo "The service embeds sing-box (https://github.com/SagerNet/sing-box) and Split Route's core (https://github.com/split-route/core); module versions are in daemon/go.sum." > "$LIC/SOURCE.txt"

# The service plist the app registers with SMAppService (Login Items).
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp app/LaunchDaemon.plist "$APP/Contents/Library/LaunchDaemons/io.github.aliraghebi.splitroute.plist"

codesign --force --sign - "$APP/Contents/Resources/splitroute"
codesign --force --sign - "$APP"

# Drag-to-install disk image with a styled window (app/assets/). dmgbuild writes
# the Finder layout without driving Finder, so it works headless on CI.
VENV=.build/dmgbuild-venv
[ -x "$VENV/bin/dmgbuild" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q dmgbuild==1.6.7; }
swift app/assets/background.swift build/background.tiff
"$VENV/bin/dmgbuild" -s app/assets/dmg-settings.py -D app="$APP" -D background=build/background.tiff \
  Splitroute build/Splitroute.dmg >/dev/null
rm build/background.tiff
echo "$APP build/Splitroute.dmg"
