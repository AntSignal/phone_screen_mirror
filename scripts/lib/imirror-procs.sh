# Shared by run.sh and package.sh: find and quit iMirror processes. Source
# it; it defines functions only.
#
# Processes are matched by their exact executable path, never by bundle id:
# the fork and the old upstream app are both com.local.imirror, so anything
# keyed on the bundle id can quit or count the wrong app.

IMIRROR_STOPPED_PIDS=""     # set by imirror_stop_bundle
IMIRROR_STOPPED_OWNER=0     # 1 when a stopped pid owned devices.json

imirror_devices_file() {
    printf '%s\n' "${IMIRROR_DEVICES_FILE:-$HOME/Library/Application Support/iMirror/devices.json}"
}

# The owner_pid in devices.json, or nothing.
imirror_owner_pid() {
    local f; f="$(imirror_devices_file)"
    [[ -f "$f" ]] || return 0
    { grep -oE '"owner_pid"[[:space:]]*:[[:space:]]*[0-9]+' "$f" 2>/dev/null || true; } \
        | grep -oE '[0-9]+$' | head -1 || true
}

# Pids whose executable is exactly <bundle>/Contents/MacOS/iMirror.
imirror_app_pids() {
    ps -axo pid=,comm= | awk -v exe="$1/Contents/MacOS/iMirror" '
        { pid = $1; c = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", c)
          if (c == exe) print pid }'
}

# Asks one app instance to quit through AppKit, so applicationWillTerminate
# stops its go-ios children. SIGTERM would skip that and orphan them.
# Prints ok, refused or nil.
imirror_request_quit() {
    osascript -l JavaScript -e "ObjC.import('AppKit');
        var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($1);
        a.isNil() ? 'nil' : (a.terminate ? 'ok' : 'refused')" 2>&1
}

# Waits up to $2 seconds for pid $1 to exit.
imirror_wait_exit() {
    local deadline=$((SECONDS + $2))
    while kill -0 "$1" 2>/dev/null; do
        (( SECONDS < deadline )) || return 1
        sleep 0.2
    done
}

# Refuses (returns 1) when an app runs from bundle $1 and $2 is not 1.
imirror_guard_bundle() {
    local pids; pids="$(imirror_app_pids "$1")"
    [[ -z "$pids" || "$2" == 1 ]] && return 0
    echo "iMirror (pid $(echo $pids)) is running from $1." >&2
    echo "Nothing was built or deleted. Re-run with --restart to quit it, rebuild and" >&2
    echo "relaunch it; every phone drops for about 30 s and every agent loses WDA." >&2
    return 1
}

# Quits every app running from bundle $1 when $2 is 1, else refuses. Returns 1,
# with nothing quit or deleted, unless each one exits within
# IMIRROR_QUIT_TIMEOUT_S (default 10) seconds.
imirror_stop_bundle() {
    imirror_guard_bundle "$1" "$2" || return 1
    local pid owner reply limit="${IMIRROR_QUIT_TIMEOUT_S:-10}"
    owner="$(imirror_owner_pid)"
    for pid in $(imirror_app_pids "$1"); do
        echo "==> quitting iMirror (pid $pid)"
        reply="$(imirror_request_quit "$pid")"
        if [[ "$reply" != ok ]]; then
            echo "Couldn't ask pid $pid to quit (AppKit said: $reply). Quit it from its menu and re-run." >&2
            return 1
        fi
        if ! imirror_wait_exit "$pid" "$limit"; then
            echo "iMirror (pid $pid) did not exit within $limit s; nothing was deleted." >&2
            return 1
        fi
        IMIRROR_STOPPED_PIDS="$IMIRROR_STOPPED_PIDS $pid"
        [[ "$pid" == "$owner" ]] && IMIRROR_STOPPED_OWNER=1
    done
    return 0
}

# Opens bundle $1 and waits for it to run. After a restart of the app that
# owned devices.json, also waits until devices.json names the new pid, since
# that is when agents can reach the phones again. IMIRROR_OWNER_TIMEOUT_S
# (default 30) bounds the wait.
imirror_launch_bundle() {
    local app="$1" limit="${IMIRROR_OWNER_TIMEOUT_S:-30}" new="" owner=""
    # -n: never activate a same-bundle-id app running from another path.
    open -n "$app"
    local deadline=$((SECONDS + limit))
    while (( SECONDS < deadline )); do
        new="$(imirror_app_pids "$app")"
        new="${new%%$'\n'*}"
        if [[ -n "$new" ]]; then
            if [[ "$IMIRROR_STOPPED_OWNER" != 1 ]]; then
                echo "    iMirror is running (pid $new)"
                return 0
            fi
            owner="$(imirror_owner_pid)"
            if [[ "$owner" == "$new" ]]; then
                echo "    iMirror is running (pid $new) and owns devices.json"
                return 0
            fi
        fi
        sleep 0.5
    done
    if [[ -z "$new" ]]; then
        echo "iMirror did not start from $app within $limit s." >&2
    else
        echo "iMirror (pid $new) started, but devices.json still names pid ${owner:-none} after $limit s." >&2
        echo "Check that Automation is on in the new window." >&2
    fi
    return 1
}
