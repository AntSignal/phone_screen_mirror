#!/usr/bin/env bash
# Build iMirror, wrap the executable into a proper .app bundle (so TCC camera
# permission works), sign it, and launch it.
#
# Signs with $IMIRROR_SIGN_IDENTITY (e.g. an "Apple Development: …" name from
# `security find-identity -v -p codesigning`) when set, else ad hoc. An ad hoc
# signature changes with every build, so macOS forgets the Bluetooth and
# Documents grants and asks again; a real identity keeps them.
#
#   ./scripts/run.sh [debug|release] [--restart]
#
# The app lives at $IMIRROR_APP, default ~/Applications/iMirror.app. Not in
# build/: a disk-cleanup job deletes old build folders under ~/Documents/Github,
# and that took the running app's bundled go-ios with it.
#
# It refuses to replace a bundle that is running: deleting it under the live
# app leaves `open` activating the old binary, and devices.json's goios path
# points into it. It also refuses while an iMirror from another path owns
# devices.json. --restart quits those apps first (every phone drops for about
# 30 s), then relaunches and waits for the new app to own devices.json.
#
# Pure Apple toolchain (swift, codec/codesign, /bin). No third-party tools.
set -euo pipefail

# -P: running apps report physical paths; compare those.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
source "$ROOT/scripts/lib/imirror-procs.sh"

usage() { echo "usage: $0 [debug|release] [--restart]"; }
CONFIG=debug
RESTART=0
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --restart) RESTART=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

APP="${IMIRROR_APP:-$HOME/Applications/iMirror.app}"
mkdir -p "$(dirname "$APP")"
# Physical path, as ps reports it.
APP="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
# Refuse before building; quit only after a good build.
imirror_guard_bundle "$APP" "$RESTART" || exit 1
imirror_guard_other_owner "$APP" "$RESTART" || exit 1

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/iMirror"

imirror_stop_bundle "$APP" "$RESTART" || exit 1
imirror_stop_other_owner "$APP" "$RESTART" || exit 1

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iMirror"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Bundle the go-ios binary so the app can manage the USB forward itself
# (no external relay script / terminal needed).
GOIOS="$ROOT/tools/go-ios/bin/ios"
if [[ -x "$GOIOS" ]]; then
    cp "$GOIOS" "$APP/Contents/Resources/ios"
    echo "    bundled go-ios"
else
    echo "    WARNING: $GOIOS not found — app will fall back to scripts/wda-up.sh"
fi

# Bundle the MCP server so the in-app one-click MCP install works from the .app.
mkdir -p "$APP/Contents/Resources/mcp-server"
# Every server module, not just imirror_mcp.py: it imports wda_bringup, and a
# bundle missing that file fails at import. Tests stay out of the app.
for py in "$ROOT"/mcp-server/*.py; do
    case "$(basename "$py")" in test_*|conftest.py) continue ;; esac
    cp "$py" "$APP/Contents/Resources/mcp-server/" 2>/dev/null || true
done
[[ -f "$ROOT/mcp-server/requirements.txt" ]] && \
    cp "$ROOT/mcp-server/requirements.txt" "$APP/Contents/Resources/mcp-server/" || true

if [[ -n "${IMIRROR_SIGN_IDENTITY:-}" ]]; then
    echo "==> signing with $IMIRROR_SIGN_IDENTITY (local dev)"
    codesign --force --sign "$IMIRROR_SIGN_IDENTITY" --timestamp=none "$APP"
else
    echo "==> ad-hoc signing (local dev; set IMIRROR_SIGN_IDENTITY to keep permission grants)"
    codesign --force --sign - --timestamp=none "$APP"
fi

echo "==> launching"
imirror_launch_bundle "$APP" || exit 1
echo "    (logs: Console.app, filter 'iMirror'; or: log stream --predicate 'eventMessage CONTAINS \"iMirror\"')"
