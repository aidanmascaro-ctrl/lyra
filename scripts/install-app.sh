#!/bin/bash
# Puts the built app in /Applications so it can live in the Dock: quits a running Lyra (a recording in progress
# is finalised and processed on the next launch), replaces /Applications/Lyra.app with build/Lyra.app, opens it.
# Run scripts/build-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE=build/Lyra.app
TARGET=/Applications/Lyra.app
[[ -d "$SOURCE" ]] || { echo "No $SOURCE: run scripts/build-app.sh first." >&2; exit 1; }

if pgrep -x Lyra >/dev/null; then
    osascript -e 'tell application id "au.aidos.lyra" to quit' >/dev/null || true
    for _ in $(seq 1 30); do pgrep -x Lyra >/dev/null || break; sleep 1; done
    if pgrep -x Lyra >/dev/null; then
        echo "Lyra is still running after 30 s; quit it from the menu bar and run this again." >&2
        exit 1
    fi
fi

rm -rf "$TARGET"
ditto "$SOURCE" "$TARGET"
open "$TARGET"
echo "Installed $TARGET"
