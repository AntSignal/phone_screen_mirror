# Source patches build-go-ios.sh applies to the pinned go-ios tree before it
# builds. Source it; it defines functions only. Each patch is idempotent and
# checks its own result, so a go-ios bump that moves the patched line fails
# the build instead of quietly shipping the unpatched behaviour.

# The exact listen call each patch must leave behind.
GOIOS_FORWARD_LOOPBACK='l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", hostPort))'

# `ios forward` listens on 0.0.0.0, so the WDA port (no auth) and the MJPEG
# screen were open to the whole LAN. Bind 127.0.0.1 instead: every client in
# this repo already dials 127.0.0.1. $1 is the go-ios source dir.
goios_patch_forward_loopback() {
    local f="$1/ios/forward/forward.go"
    if [[ ! -f "$f" ]]; then
        echo "go-ios patch: $f not found" >&2
        return 1
    fi
    sed -i '' 's/fmt\.Sprintf("0\.0\.0\.0:%d", hostPort)/fmt.Sprintf("127.0.0.1:%d", hostPort)/' "$f"
    # Exactly one loopback listen, and no wildcard listen left anywhere.
    if [[ "$(grep -cF "$GOIOS_FORWARD_LOOPBACK" "$f")" == 1 ]] \
        && ! grep -q '0\.0\.0\.0' "$f" \
        && ! grep -qE 'net\.Listen\("tcp", *":' "$f"; then
        return 0
    fi
    echo "go-ios patch FAILED: $f does not listen on 127.0.0.1 only." >&2
    echo "go-ios moved its forward listener; update scripts/lib/goios-patches.sh." >&2
    return 1
}

# A built binary must not carry the wildcard format string. $1 is the binary.
goios_check_binary_loopback() {
    if strings "$1" | grep -qF '0.0.0.0:%d'; then
        echo "go-ios check FAILED: $1 still contains a 0.0.0.0 listener." >&2
        return 1
    fi
    return 0
}
