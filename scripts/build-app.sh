#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP=build/Lyra.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Lyra" "$APP/Contents/MacOS/Lyra"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The app icon is drawn at build time (no image files in the repo).
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
swift scripts/make-icon.swift "$ICON_TMP/AppIcon.iconset"
iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

ID="${LYRA_SIGN_ID:-Lyra Local}"
# Captured first: `grep -q` exits on the first match, and under pipefail the SIGPIPE it gives
# `security` would fail the pipeline and force a false ad-hoc fallback.
IDENTITIES="$(security find-identity -v -p codesigning || true)"
if grep -qF "\"$ID\"" <<<"$IDENTITIES"; then
    codesign --force --deep -s "$ID" "$APP"
else
    echo "WARNING: signing identity '$ID' not found; using ad-hoc signature. macOS permissions will reset on every rebuild." >&2
    codesign --force --deep -s - "$APP"
fi
echo "Built $APP"
