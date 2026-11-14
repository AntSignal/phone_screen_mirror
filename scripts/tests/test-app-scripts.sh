#!/usr/bin/env bash
# Device-free tests for scripts/run.sh, scripts/package.sh and the audits in
# scripts/lib/imirror-procs.sh. `swift test` runs this file (ScriptTests).
#
# The scripts run from a throwaway copy of the repo layout, and every tool
# that could touch the real Mac (ps, open, osascript, swift, codesign, lipo,
# security, hdiutil) is a stub first on PATH. A "running app" is a `sleep`
# the ps stub reports under an iMirror path. Nothing here can quit, launch or
# rebuild a real iMirror.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$HERE/../.." && pwd -P)"
T="$(mktemp -d "${TMPDIR:-/tmp}/imirror-script-tests.XXXXXX")"
T="$(cd "$T" && pwd -P)"
ROOT="$T/root"
APP="$ROOT/build/iMirror.app"
STUBS="$T/stubs"
STATE="$T/state"
TEST_PATH="$STUBS:/usr/bin:/bin"
export T STATE   # the stubs read them
PASSES=0
FAILS=0

kill_fakes() {
    local f
    for f in "$STATE"/apps/*; do [[ -f "$f" ]] && kill "${f##*/}" 2>/dev/null; done
    return 0
}
trap 'kill_fakes; rm -rf "$T"' EXIT

stub() {   # name, body
    printf '#!/bin/sh\n%s\n' "$2" > "$STUBS/$1"
    chmod +x "$STUBS/$1"
}

mkdir -p "$STUBS" "$T/bin" "$T/home"
printf 'binary' > "$T/bin/iMirror"
stub swift 'echo "swift $*" >> "$STATE/calls"
case " $* " in *" --show-bin-path "*) echo "$T/bin" ;; esac'
stub codesign 'echo "codesign $*" >> "$STATE/calls"'
stub lipo 'echo "x86_64 arm64"'
stub security ':'
stub hdiutil 'echo "hdiutil $*" >> "$STATE/calls"'
# Lists every fake app that is still alive, plus one unrelated process.
stub ps 'echo "    1 /sbin/launchd"
for f in "$STATE"/apps/*; do
    [ -f "$f" ] || continue
    pid="${f##*/}"
    kill -0 "$pid" 2>/dev/null && printf "%6s %s\n" "$pid" "$(cat "$f")"
done
exit 0'
# quit-mode: ok (exits), stuck (says ok, never exits), refused.
stub osascript 'pid="$(printf "%s" "$*" | grep -oE "Identifier\(([0-9]+)\)" | grep -oE "[0-9]+")"
echo "osascript $pid" >> "$STATE/calls"
mode="$(cat "$STATE/quit-mode" 2>/dev/null || echo ok)"
case "$mode" in
    ok) kill "$pid"; echo ok ;;
    stuck) echo ok ;;
    *) echo refused ;;
esac'
# Starts a fake app for the bundle; with owner-follows it claims devices.json.
stub open 'echo "open $*" >> "$STATE/calls"
for last; do :; done
( sleep 120 >/dev/null 2>&1 & echo $! > "$STATE/opened.pid" )
pid="$(cat "$STATE/opened.pid")"
printf "%s" "$last/Contents/MacOS/iMirror" > "$STATE/apps/$pid"
if [ -f "$STATE/owner-follows" ]; then
    printf "{\n  \"owner_pid\" : %s,\n  \"schema\" : 1\n}\n" "$pid" > "$T/devices.json"
fi'

# Run nothing unless every risky tool resolves to its stub.
for tool in ps open osascript swift codesign lipo security hdiutil; do
    if [[ "$(PATH="$TEST_PATH" command -v "$tool")" != "$STUBS/$tool" ]]; then
        echo "FATAL: $tool does not resolve to its stub; not running anything" >&2
        exit 1
    fi
done

new_case() {
    kill_fakes
    rm -rf "$ROOT" "$STATE" "$T/devices.json"
    mkdir -p "$ROOT/scripts/lib" "$ROOT/Resources" "$ROOT/mcp-server" "$STATE/apps"
    cp "$REPO/scripts/run.sh" "$REPO/scripts/package.sh" "$ROOT/scripts/"
    cp "$REPO/scripts/lib/imirror-procs.sh" "$ROOT/scripts/lib/"
    echo '<plist/>' > "$ROOT/Resources/Info.plist"
    : > "$ROOT/Resources/iMirror.entitlements"
    for f in imirror_mcp.py wda_bringup.py test_imirror_mcp.py conftest.py; do echo 'x = 1' > "$ROOT/mcp-server/$f"; done
    : > "$STATE/calls"
}

# Fakes an app running from bundle $1; prints its pid.
fake_app() {
    ( sleep 120 >/dev/null 2>&1 & echo $! > "$STATE/fake.pid" )
    local pid; pid="$(cat "$STATE/fake.pid")"
    printf '%s' "$1/Contents/MacOS/iMirror" > "$STATE/apps/$pid"
    echo "$pid"
}

old_bundle() {   # a bundle with a marker that must survive
    mkdir -p "$APP/Contents/MacOS"
    echo old > "$APP/marker"
}

owns_devices() {
    printf '{\n  "owner_pid" : %s,\n  "schema" : 1\n}\n' "$1" > "$T/devices.json"
}

run_script() {   # script, args...
    OUT="$(PATH="$TEST_PATH" HOME="$T/home" IMIRROR_DEVICES_FILE="$T/devices.json" \
           IMIRROR_QUIT_TIMEOUT_S=1 IMIRROR_OWNER_TIMEOUT_S=2 \
           /bin/bash "$ROOT/scripts/$1" "${@:2}" 2>&1)"
    CODE=$?
    CALLS="$(cat "$STATE/calls")"
}

check() {   # description, condition...
    local what="$1"; shift
    if "$@"; then PASSES=$((PASSES + 1)); else
        FAILS=$((FAILS + 1))
        printf 'FAIL: %s\n  exit: %s\n  output:\n%s\n  calls:\n%s\n' "$what" "${CODE:-}" "${OUT:-}" "${CALLS:-}"
    fi
}
has() { [[ "$1" == *"$2"* ]]; }
hasnt() { [[ "$1" != *"$2"* ]]; }

# ---- run.sh ----

new_case
run_script run.sh
check "run.sh, nothing running: builds and opens" [ "$CODE" = 0 ]
check "run.sh opens with -n" has "$CALLS" "open -n $APP"
check "run.sh quits nothing when nothing runs" hasnt "$CALLS" "osascript"
check "run.sh bundles server modules" [ -f "$APP/Contents/Resources/mcp-server/wda_bringup.py" ]
check "run.sh leaves tests out of the bundle" [ ! -e "$APP/Contents/Resources/mcp-server/test_imirror_mcp.py" ]
check "run.sh leaves conftest.py out of the bundle" [ ! -e "$APP/Contents/Resources/mcp-server/conftest.py" ]

new_case; old_bundle; PID="$(fake_app "$APP")"
run_script run.sh
check "run.sh refuses a running bundle" [ "$CODE" = 1 ]
check "the refusal names --restart" has "$OUT" "--restart"
check "the refusal names the pid" has "$OUT" "pid $PID"
check "the refusal comes before the build" hasnt "$CALLS" "swift"
check "the refusal quits nothing" hasnt "$CALLS" "osascript"
check "the refusal opens nothing" hasnt "$CALLS" "open"
check "the refusal keeps the bundle" [ -f "$APP/marker" ]
check "the refusal leaves the app running" kill -0 "$PID"

new_case; old_bundle; PID="$(fake_app "$APP")"; owns_devices "$PID"; touch "$STATE/owner-follows"
run_script run.sh --restart
NEW="$(cat "$STATE/opened.pid" 2>/dev/null)"
check "run.sh --restart succeeds" [ "$CODE" = 0 ]
check "--restart quits exactly the running pid" [ "$(grep -c '^osascript ' <<<"$CALLS")" = 1 ]
check "--restart asks pid $PID to quit" has "$CALLS" "osascript $PID"
check "--restart quits before it deletes" [ ! -f "$APP/marker" ]
check "--restart relaunches" has "$CALLS" "open -n $APP"
check "--restart reports the new owner" has "$OUT" "pid $NEW) and owns devices.json"

new_case; old_bundle; PID="$(fake_app "$APP")"; echo stuck > "$STATE/quit-mode"
run_script run.sh --restart
check "an app that won't exit aborts the restart" [ "$CODE" = 1 ]
check "the abort says so" has "$OUT" "did not exit"
check "the abort deletes nothing" [ -f "$APP/marker" ]
check "the abort opens nothing" hasnt "$CALLS" "open"

new_case; old_bundle; PID="$(fake_app "$APP")"; echo refused > "$STATE/quit-mode"
run_script run.sh --restart
check "AppKit refusing to quit aborts the restart" [ "$CODE" = 1 ]
check "that abort deletes nothing" [ -f "$APP/marker" ]

new_case; old_bundle; PID="$(fake_app "$APP")"; owns_devices "$PID"
run_script run.sh --restart
check "a relaunch that never claims devices.json fails" [ "$CODE" = 1 ]
check "that failure names the stale owner" has "$OUT" "still names pid $PID"

new_case; OTHER="$(fake_app "$T/elsewhere/iMirror.app")"
run_script run.sh
check "an iMirror at another path is not this bundle" [ "$CODE" = 0 ]
check "the other iMirror is never asked to quit" hasnt "$CALLS" "osascript"
check "the other iMirror keeps running" kill -0 "$OTHER"

new_case
run_script run.sh --restart release
check "release still works after --restart" has "$CALLS" "swift build -c release"
new_case
run_script run.sh release
check "release still works as the only argument" has "$CALLS" "swift build -c release"
new_case
run_script run.sh --bogus
check "an unknown flag is a usage error" [ "$CODE" = 2 ]

# ---- package.sh ----

new_case; old_bundle; PID="$(fake_app "$APP")"
run_script package.sh
check "package.sh refuses a running bundle" [ "$CODE" = 1 ]
check "package.sh refuses before the build" hasnt "$CALLS" "swift"
check "package.sh keeps the bundle" [ -f "$APP/marker" ]

new_case; old_bundle; PID="$(fake_app "$APP")"; owns_devices "$PID"; touch "$STATE/owner-follows"
run_script package.sh --restart
check "package.sh --restart succeeds" [ "$CODE" = 0 ]
check "package.sh --restart quits pid $PID" has "$CALLS" "osascript $PID"
check "package.sh --restart relaunches the new build" has "$CALLS" "open -n $APP"
check "package.sh still builds the DMG" has "$CALLS" "hdiutil create"

new_case
run_script package.sh
check "package.sh with nothing running succeeds" [ "$CODE" = 0 ]
check "package.sh launches nothing it didn't quit" hasnt "$CALLS" "open"

# ---- audits ----

source "$REPO/scripts/lib/imirror-procs.sh"
SUP="/Users/u/Library/Application Support/iMirror"

OUT="$(imirror_audit_mcp_servers "$SUP" <<EOF
  101 /Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python $SUP/mcp/current/imirror_mcp.py
  102 /Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python /Users/u/Documents/Github/imirror/mcp-server/imirror_mcp.py
  103 /usr/bin/python3 -m pytest mcp-server/test_imirror_mcp.py
  104 vim imirror_mcp.py
  105 $SUP/mcp/.venv/bin/python /Users/u/Documents/Github/imirror/mcp-server/imirror_mcp.py
  106 $SUP/mcp/.venv/bin/python $SUP/mcp/1.3.0-0123abcd/imirror_mcp.py
EOF
)"
check "a dev-tree server is flagged with its pid" has "$OUT" "WARNING: MCP server pid 102"
check "the frozen server is not flagged" hasnt "$OUT" "pid 101"
check "the venv's python does not hide a dev-tree script" has "$OUT" "WARNING: MCP server pid 105"
check "a frozen copy run by the venv is fine" hasnt "$OUT" "pid 106"
check "pytest and editors are not servers" has "$OUT" "4 MCP server(s) running; 2 not under $SUP/mcp/"
check "flagged servers are counted per script" has "$OUT" "  2 running /Users/u/Documents/Github/imirror/mcp-server/imirror_mcp.py"

OUT="$(imirror_audit_app_instances 500 <<'EOF'
  500 /Users/u/Documents/Github/imirror-antsignal/build/iMirror.app/Contents/MacOS/iMirror
  600 /Users/u/Documents/Github/imirror/build/iMirror.app/Contents/MacOS/iMirror
  700 /Users/u/Documents/Github/imirror-antsignal/build/iMirror.app/Contents/Resources/ios
EOF
)"
check "the owner app is named" has "$OUT" "iMirror pid 500 owns devices.json"
check "a second app is flagged" has "$OUT" "WARNING: another iMirror app, pid 600"
check "go-ios children are not apps" hasnt "$OUT" "700"

OUT="$(imirror_audit_app_instances "" <<<'  500 /x/iMirror.app/Contents/MacOS/iMirror')"
check "one app and no devices.json is not a warning" hasnt "$OUT" "WARNING"

OUT="$(imirror_audit_slot_listeners <<'EOF'
COMMAND   PID  USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME
iMirror 61591 manaf   20u  IPv4 0x01         0t0  TCP 127.0.0.1:8100 (LISTEN)
ios     98082 manaf    8u  IPv6 0x02         0t0  TCP *:8111 (LISTEN)
ios     98093 manaf    9u  IPv6 0x03         0t0  TCP *:9120 (LISTEN)
ios     98095 manaf    9u  IPv4 0x04         0t0  TCP 127.0.0.1:60105 (LISTEN)
foo         1 manaf    9u  IPv6 0x05         0t0  TCP [::1]:8110 (LISTEN)
bar         2 manaf    9u  IPv4 0x06         0t0  TCP 0.0.0.0:8121 (LISTEN)
baz         3 manaf    9u  IPv4 0x07         0t0  TCP 127.0.0.1:8102 (LISTEN)
EOF
)"
check "a wildcard forward is flagged" has "$OUT" "WARNING: *:8111 (ios pid 98082)"
check "a wildcard MJPEG port is flagged" has "$OUT" "WARNING: *:9120"
check "0.0.0.0 is flagged" has "$OUT" "WARNING: 0.0.0.0:8121"
check "the loopback relay is fine" has "$OUT" "ok       127.0.0.1:8100"
check "IPv6 loopback is not a warning" hasnt "$OUT" "WARNING: [::1]"
check "non-slot ports are ignored" hasnt "$OUT" "60105"
check "the summary counts" has "$OUT" "5 slot listener(s), 3 not on loopback"

echo "$PASSES passed, $FAILS failed"
[[ "$FAILS" == 0 ]]
