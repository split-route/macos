#!/bin/sh
# Builds build/Splitroute.app: the Swift menu bar app (app/) and the Go service
# (daemon/, universal) in Contents/Resources, then a zip (what the app updates from) and a DMG. Signed with the
# self-signed certificate from scripts/make-signing-cert.sh when it is in the keychain
# (a stable identity across builds), ad hoc otherwise; not notarized. The tunnel engine (sing-box) is inside the service binary: there is
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
vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/Splitroute" "$BIN/Splitroute"
sed "s/@VERSION@/$VERSION/g" app/Info.plist > "$APP/Contents/Info.plist"
# The app's typeface (Inter, OFL). Registered at launch from here; SwiftPM's
# own resource bundle is not shipped (its lookup breaks in a signed app).
mkdir -p "$APP/Contents/Resources/Fonts"
cp app/Sources/Design/Resources/Fonts/Inter.ttf "$APP/Contents/Resources/Fonts/"
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
cp app/Sources/Design/Resources/Fonts/OFL.txt "$LIC/Inter-OFL.txt"
SINGBOX=$(cd daemon && go list -m -f '{{.Dir}}' github.com/sagernet/sing-box)
cp "$SINGBOX/LICENSE" "$LIC/sing-box.txt"
# GRDB (the app's SQLite layer) is MIT: its notice ships with the binary.
cp app/.build/checkouts/GRDB.swift/LICENSE "$LIC/GRDB.txt"
echo "The service embeds sing-box (https://github.com/SagerNet/sing-box) and Split Route's core (https://github.com/split-route/core); module versions are in daemon/go.sum." > "$LIC/SOURCE.txt"

# The service plist the app registers with SMAppService (Login Items).
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp app/LaunchDaemon.plist "$APP/Contents/Library/LaunchDaemons/io.github.aliraghebi.splitroute.plist"

# A certificate keeps the app's identity the same from build to build (an ad-hoc identity is the build's hash, so
# every update looks like a new app to the Keychain and to the service's approval). SIGN_KEYCHAIN picks a keychain
# other than the search list.
SIGN_IDENTITY=${SIGN_IDENTITY:-Splitroute Signing}
if security find-identity -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
  SIGN=${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"}
  codesign --force $SIGN --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/splitroute"
  codesign --force $SIGN --sign "$SIGN_IDENTITY" "$APP"
  echo "Signed with \"$SIGN_IDENTITY\": $(codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => //p')"
elif [ "${REQUIRE_SIGNING_CERT:-}" = 1 ]; then
  echo "error: REQUIRE_SIGNING_CERT is set but there is no \"$SIGN_IDENTITY\" certificate to sign with" >&2
  exit 1
else
  echo "warning: no \"$SIGN_IDENTITY\" certificate found; signing ad hoc (run scripts/make-signing-cert.sh once). An ad-hoc build is a different app to macOS every time." >&2
  codesign --force --sign - "$APP/Contents/Resources/splitroute"
  codesign --force --sign - "$APP"
fi

# The zipped app the app updates itself from (ditto keeps the signature's seal; a plain zip may not).
ditto -c -k --keepParent "$APP" build/Splitroute.zip

# Drag-to-install disk image with a styled window (app/assets/). dmgbuild writes
# the Finder layout without driving Finder, so it works headless on CI.
VENV=.build/dmgbuild-venv
[ -x "$VENV/bin/dmgbuild" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q dmgbuild==1.6.7; }
swift app/assets/background.swift build/background.tiff
"$VENV/bin/dmgbuild" -s app/assets/dmg-settings.py -D app="$APP" -D background=build/background.tiff \
  Splitroute build/Splitroute.dmg >/dev/null
rm build/background.tiff
echo "$APP build/Splitroute.dmg build/Splitroute.zip"
