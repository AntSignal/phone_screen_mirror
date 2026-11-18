# Shared by run.sh, package.sh and diagnose.sh: find, quit and audit iMirror
# processes. Source it; it defines functions only.
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
    local pid owner
    owner="$(imirror_owner_pid)"
    for pid in $(imirror_app_pids "$1"); do
        imirror_quit_pid "$pid" || return 1
        [[ "$pid" == "$owner" ]] && IMIRROR_STOPPED_OWNER=1
    done
    return 0
}

# Quits pid $1 through AppKit and waits for it to exit. Returns 1 if AppKit
# refuses or it outlives IMIRROR_QUIT_TIMEOUT_S (default 10) seconds.
imirror_quit_pid() {
    local reply limit="${IMIRROR_QUIT_TIMEOUT_S:-10}"
    echo "==> quitting iMirror (pid $1)"
    reply="$(imirror_request_quit "$1")"
    if [[ "$reply" != ok ]]; then
        echo "Couldn't ask pid $1 to quit (AppKit said: $reply). Quit it from its menu and re-run." >&2
        return 1
    fi
    if ! imirror_wait_exit "$1" "$limit"; then
        echo "iMirror (pid $1) did not exit within $limit s; nothing was deleted." >&2
        return 1
    fi
    IMIRROR_STOPPED_PIDS="$IMIRROR_STOPPED_PIDS $1"
}

# The executable of pid $1, as ps reports it, or nothing.
imirror_pid_exe() {
    ps -axo pid=,comm= | awk -v want="$1" '
        { pid = $1; c = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", c)
          if (pid == want) print c }'
}

# Prints the devices.json owner when it is an iMirror app running from
# somewhere other than bundle $1. That happens once, when the app moves out
# of build/, and whenever a bundle was deleted under the app, since ps still
# reports the old path.
imirror_other_owner() {
    local owner exe
    owner="$(imirror_owner_pid)"
    [[ -n "$owner" ]] || return 0
    exe="$(imirror_pid_exe "$owner")"
    # Anything else means a stale devices.json and a reused pid.
    if [[ "$exe" == */Contents/MacOS/iMirror && "$exe" != "$1/Contents/MacOS/iMirror" ]]; then
        echo "$owner"
    fi
}

# Refuses (returns 1) when another bundle's app owns devices.json and $2 is not 1.
imirror_guard_other_owner() {
    local pid exe; pid="$(imirror_other_owner "$1")"
    [[ -z "$pid" || "$2" == 1 ]] && return 0
    exe="$(imirror_pid_exe "$pid")"
    echo "iMirror (pid $pid) owns devices.json and runs from ${exe%/Contents/MacOS/iMirror}," >&2
    echo "not $1. Nothing was built or deleted. Re-run with --restart to quit it and" >&2
    echo "launch $1 instead; every phone drops for about 30 s and every agent loses WDA." >&2
    return 1
}

# Quits another bundle's devices.json owner when $2 is 1, else refuses. The
# relaunch then waits for the new app to own devices.json.
imirror_stop_other_owner() {
    imirror_guard_other_owner "$1" "$2" || return 1
    local pid; pid="$(imirror_other_owner "$1")"
    [[ -n "$pid" ]] || return 0
    imirror_quit_pid "$pid" || return 1
    IMIRROR_STOPPED_OWNER=1
}

# Opens bundle $1 and waits for it to run. After a restart of the app that
# owned devices.json, also waits until devices.json names the new pid, since
# that is when agents can reach the phones again. IMIRROR_OWNER_TIMEOUT_S
# (default 30) bounds the wait.
imirror_launch_bundle() {
    local app="$1" limit="${IMIRROR_OWNER_TIMEOUT_S:-30}" new="" owner=""
    # -n: never activate a same-bundle-id app elsewhere.
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

# ---- audits for diagnose.sh; each reads command output on stdin ----

# stdin: `ps -axo pid=,args=`. $1: the iMirror Application Support dir.
# Flags MCP servers not run from the frozen install in $1/mcp/: a git
# tree, which can change under them, or the old upstream app. Only the
# script path is judged, since the venv's python is also under $1/mcp/.
imirror_audit_mcp_servers() {
    awk -v want="$1/mcp/" '
        { pid = $1; line = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line) }
        tolower(line) ~ /python/ && line ~ /(^|[ \/])imirror_mcp\.py( |$)/ {
            total++
            # Paths may hold spaces; the script starts after the last " /".
            match(line, /imirror_mcp\.py( |$)/)
            end = RSTART + 13; start = 0
            for (i = RSTART - 2; i >= 1 && !start; i--) if (substr(line, i, 2) == " /") start = i + 1
            for (i = RSTART - 1; i >= 1 && !start; i--) if (substr(line, i, 1) == " ") start = i + 1
            script = substr(line, start ? start : 1, end - (start ? start : 1) + 1)
            rest = substr(script, length(want) + 1)
            if (index(script, want) != 1 || rest !~ /^[^\/]+\/imirror_mcp\.py$/) {
                other++
                printf "WARNING: MCP server pid %s is not the frozen install: %s\n", pid, line
                by[script]++
            }
        }
        END {
            for (s in by) printf "  %d running %s\n", by[s], s
            printf "%d MCP server(s) running; %d not under %s\n", total, other, want
        }'
}

# stdin: `ps -axo pid=,comm=`. $1: owner_pid from devices.json, or empty.
# Two apps fight over the same phones; only the owner should exist.
imirror_audit_app_instances() {
    awk -v owner="$1" '
        { pid = $1; c = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", c) }
        c ~ /\/iMirror\.app\/Contents\/MacOS\/iMirror$/ { n++; pids[n] = pid; paths[n] = c }
        END {
            for (i = 1; i <= n; i++) {
                if (owner != "" && pids[i] == owner)
                    printf "iMirror pid %s owns devices.json: %s\n", pids[i], paths[i]
                else if (owner != "" || n > 1)
                    printf "WARNING: another iMirror app, pid %s: %s\n", pids[i], paths[i]
                else
                    printf "iMirror pid %s (no devices.json owner): %s\n", pids[i], paths[i]
            }
            if (n == 0) print "(no iMirror app running)"
        }'
}

# stdin: `lsof -nP -iTCP -sTCP:LISTEN`. Slot ports are 81x0 (relay), 81x1
# (forward) and 91x0 (MJPEG) for x = 0..9. WDA has no auth, so anything but
# 127.0.0.1 lets the network drive the phone or watch its screen.
imirror_audit_slot_listeners() {
    awk '
        $1 == "COMMAND" { next }
        {
            name = $9; port = name; sub(/^.*:/, "", port)
            host = substr(name, 1, length(name) - length(port) - 1)
            if (port !~ /^(81[0-9][01]|91[0-9]0)$/) next
            n++
            if (host == "127.0.0.1") printf "ok       %s (%s pid %s)\n", name, $1, $2
            else if (host == "[::1]") printf "ok       %s (%s pid %s, IPv6 loopback)\n", name, $1, $2
            else { bad++; printf "WARNING: %s (%s pid %s) is reachable from the network\n", name, $1, $2 }
        }
        END { if (n == 0) print "(no listeners on slot ports)"; else printf "%d slot listener(s), %d not on loopback\n", n, bad }'
}
