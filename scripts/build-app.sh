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
