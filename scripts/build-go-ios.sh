#!/usr/bin/env bash
# Build a universal2 (arm64 + x86_64) go-ios `ios` binary from the pinned,
# audited source already cloned into tools/go-ios (see README "Set up tools/"
# and SECURITY-AUDIT.md). Produces tools/go-ios/bin/ios — a fat Mach-O that
# runs on both Intel and Apple Silicon Macs. scripts/package.sh bundles it into
# the .app so one DMG works everywhere.
#
# CGO is disabled so both slices cross-compile with the stock Go toolchain and
# no C cross-compiler. go-ios talks to usbmuxd over sockets and needs no cgo.
#
# Before building it patches `ios forward` to listen on 127.0.0.1 only
# (scripts/lib/goios-patches.sh). The build stops if that patch did not apply.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/tools/go-ios"
source "$ROOT/scripts/lib/goios-patches.sh"
[[ -d "$SRC" ]] || { echo "tools/go-ios not found — clone it first (see README)" >&2; exit 1; }
cd "$SRC"

# Refuse any other revision: the audit and the patch are for this one.
EXPECTED_GOIOS_REV="2fb34682ef12db97c9fafdf99f1dd1d3522604ad"   # v1.3.2
got_rev="$(git rev-parse HEAD 2>/dev/null || true)"
if [[ "$got_rev" != "$EXPECTED_GOIOS_REV" ]]; then
    echo "go-ios source must be v1.3.2 ($EXPECTED_GOIOS_REV), as recorded in SECURITY-AUDIT.md;" >&2
    echo "tools/go-ios is at ${got_rev:-an unknown revision}. Re-clone it (see README)." >&2
    exit 1
fi

echo "==> patching ios/forward to listen on 127.0.0.1 only"
goios_patch_forward_loopback "$SRC" || exit 1

# Same patched transitive deps the security audit records (SECURITY-AUDIT.md).
GOWORK=off go get golang.org/x/crypto@v0.57.0 golang.org/x/net@v0.60.0
GOWORK=off go mod tidy

echo "==> building go-ios arm64 + amd64 (CGO off, root module only)"
GOWORK=off CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -o bin/ios-arm64 .
GOWORK=off CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -o bin/ios-amd64 .

echo "==> lipo -> universal bin/ios"
lipo -create -output bin/ios bin/ios-arm64 bin/ios-amd64
rm -f bin/ios-arm64 bin/ios-amd64

goios_check_binary_loopback bin/ios || exit 1

echo "==> result:"
lipo -archs bin/ios
file bin/ios
