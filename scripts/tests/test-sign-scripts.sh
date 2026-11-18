#!/usr/bin/env bash
# Device-free tests for how scripts/run.sh and scripts/package.sh sign the
# app. `swift test` runs this file (ScriptTests).
#
# Each script runs from a throwaway copy of the repo layout. Every tool that
# builds, signs, reads the keychain, makes a DMG or launches an app (swift,
# codesign, security, lipo, hdiutil, rsync, xcrun, open, ps, osascript) is a
# stub first on PATH, so nothing here builds, signs with a real identity,
# opens iMirror or sees (or quits) a real one.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$HERE/../.." && pwd -P)"
T="$(mktemp -d "${TMPDIR:-/tmp}/imirror-sign-tests.XXXXXX")"
T="$(cd "$T" && pwd -P)"
ROOT="$T/root"
STUBS="$T/stubs"
STATE="$T/state"
TEST_PATH="$STUBS:/usr/bin:/bin"
export STATE
PASSES=0
FAILS=0
trap 'rm -rf "$T"' EXIT

stub() {   # name, body
    printf '#!/bin/sh\n%s\n' "$2" > "$STUBS/$1"
    chmod +x "$STUBS/$1"
}
mkdir -p "$STUBS"

# `swift build --show-bin-path` names a folder holding a fake iMirror.
stub swift 'echo "swift $*" >> "$STATE/calls"
case "$*" in *--show-bin-path*) mkdir -p "$STATE/bin"; : > "$STATE/bin/iMirror"; echo "$STATE/bin" ;; esac
exit 0'
stub codesign 'echo "codesign $*" >> "$STATE/calls"; exit 0'
# open records the bundle; ps then lists it running.
stub open 'echo "open $*" >> "$STATE/calls"
for last; do :; done
printf "%s" "$last" > "$STATE/opened"; exit 0'
stub ps 'echo "    1 /sbin/launchd"
[ -f "$STATE/opened" ] && echo " 4242 $(cat "$STATE/opened")/Contents/MacOS/iMirror"
exit 0'
stub osascript 'echo "osascript $*" >> "$STATE/calls"; echo refused'
stub lipo 'echo "x86_64 arm64"'
stub hdiutil 'echo "hdiutil $*" >> "$STATE/calls"; exit 0'
stub rsync 'exit 0'
stub xcrun 'echo "xcrun $*" >> "$STATE/calls"; exit 0'
# Keychain: $STATE/identities holds the find-identity lines.
stub security 'cat "$STATE/identities" 2>/dev/null; exit 0'

for tool in swift codesign open lipo hdiutil rsync xcrun security ps osascript; do
    if [[ "$(PATH="$TEST_PATH" command -v "$tool")" != "$STUBS/$tool" ]]; then
        echo "FATAL: $tool does not resolve to its stub; not running anything" >&2
        exit 1
    fi
done

check() {   # description, condition...
    local what="$1"; shift
    if "$@"; then PASSES=$((PASSES + 1)); else
        FAILS=$((FAILS + 1))
        printf 'FAIL: %s\n  exit: %s\n  output:\n%s\n  calls:\n%s\n' "$what" "${CODE:-}" "${OUT:-}" "${CALLS:-}"
    fi
}
has() { [[ "$1" == *"$2"* ]]; }
hasnt() { [[ "$1" != *"$2"* ]]; }

fresh() {   # keychain lines
    rm -rf "$ROOT" "$STATE"
    mkdir -p "$ROOT/scripts/lib" "$ROOT/Resources" "$ROOT/mcp-server" "$STATE" "$T/home"
    cp "$REPO/scripts/run.sh" "$REPO/scripts/package.sh" "$ROOT/scripts/"
    cp "$REPO/scripts/lib/imirror-procs.sh" "$ROOT/scripts/lib/"
    printf '<plist/>\n' > "$ROOT/Resources/Info.plist"
    printf '%s\n' "$@" > "$STATE/identities"
    : > "$STATE/calls"
}

run_script() {   # script; IMIRROR_SIGN_IDENTITY comes from $SIGN_AS
    OUT="$(PATH="$TEST_PATH" HOME="$T/home" IMIRROR_SIGN_IDENTITY="${SIGN_AS:-}" IMIRROR_APP= \
        IMIRROR_DEVICES_FILE="$T/devices.json" \
        /bin/bash "$ROOT/scripts/$1" 2>&1)"
    CODE=$?
    CALLS="$(cat "$STATE/calls" 2>/dev/null)"
}

DEV="Apple Development: Dev Person (TEAMDEV001)"
DEVID_HASH=0123456789ABCDEF0123456789ABCDEF01234567
DEVID="  1) $DEVID_HASH \"Developer ID Application: Some Org (TEAMORG001)\""
APP_PATH="$T/home/Applications/iMirror.app"   # run.sh's default install

# ---- run.sh ----

fresh
SIGN_AS="" run_script run.sh
check "run.sh builds and launches" [ "$CODE" = 0 ]
check "run.sh signs ad hoc by default" has "$CALLS" "codesign --force --sign - --timestamp=none $APP_PATH"
check "it says how to keep grants" has "$OUT" "IMIRROR_SIGN_IDENTITY"
check "it opens the stub, not a real app" has "$CALLS" "open -n $APP_PATH"

fresh
SIGN_AS="$DEV" run_script run.sh
check "run.sh with an identity succeeds" [ "$CODE" = 0 ]
check "run.sh signs with IMIRROR_SIGN_IDENTITY" has "$CALLS" "codesign --force --sign $DEV --timestamp=none $APP_PATH"
check "it never signs ad hoc then" hasnt "$CALLS" "--sign - "
check "dev signing needs no hardened runtime" hasnt "$CALLS" "--options runtime"

# ---- package.sh ----

fresh "$DEVID" "     1 valid identities found"
SIGN_AS="$DEV" run_script package.sh
check "package.sh with an identity succeeds" [ "$CODE" = 0 ]
check "IMIRROR_SIGN_IDENTITY beats a Developer ID" has "$CALLS" "codesign --force --sign $DEV --timestamp=none"
check "the Developer ID is not used then" hasnt "$CALLS" "$DEVID_HASH"
check "no hardened runtime for dev signing" hasnt "$CALLS" "--options runtime"
check "a dev-signed DMG is never notarized" hasnt "$CALLS" "notarytool"
check "it says the DMG is for this Mac" has "$OUT" "development-signed DMG"

fresh "$DEVID" "     1 valid identities found"
SIGN_AS="" run_script package.sh
check "package.sh still prefers a Developer ID" has "$CALLS" "--sign $DEVID_HASH"
check "that path keeps the hardened runtime" has "$CALLS" "--options runtime --timestamp"

fresh "     0 valid identities found"
SIGN_AS="" run_script package.sh
check "package.sh with no identity succeeds" [ "$CODE" = 0 ]
check "package.sh falls back to ad hoc" has "$CALLS" "codesign --force --sign - --entitlements"

echo "$PASSES passed, $FAILS failed"
[[ "$FAILS" == 0 ]]
