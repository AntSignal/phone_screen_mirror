#!/usr/bin/env bash
# Device-free tests for scripts/build-go-ios.sh, scripts/build-wda.sh and
# the build half of scripts/sim-wda-up.sh.
# `swift test` runs this file (ScriptTests).
#
# Each script runs from a throwaway copy of the repo layout. Every tool that
# builds, signs, reads the keychain or boots a Simulator (git, go, lipo,
# strings, xcodebuild, xcrun, open, swift, sips, codesign, security, openssl)
# is a stub first on PATH, so nothing here compiles go-ios or WebDriverAgent
# or touches a real identity or Simulator.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$HERE/../.." && pwd -P)"
T="$(mktemp -d "${TMPDIR:-/tmp}/imirror-build-tests.XXXXXX")"
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

# ---- go-ios stubs ----
# The clone's revision is whatever $STATE/rev says.
stub git '[ "$1 $2" = "rev-parse HEAD" ] && cat "$STATE/rev"'
# `go build -o X` writes forward.go into X, so the "binary" carries its strings.
stub go 'echo "go $*" >> "$STATE/calls"
out=""; prev=""
for a; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    cat ios/forward/forward.go > "$out"
    [ -f "$STATE/leak-wildcard" ] && echo "0.0.0.0:%d" >> "$out"
fi
exit 0'
stub lipo 'echo "lipo $*" >> "$STATE/calls"
if [ "$1" = "-create" ]; then out="$3"; shift 3; cat "$@" > "$out"; exit 0; fi
echo "x86_64 arm64"'
stub strings 'cat "$@"'
stub file 'echo "$1: Mach-O universal binary"'

# ---- WebDriverAgent stubs ----
# The derived runner: an Info.plist, one test bundle and one framework.
stub xcodebuild 'echo "xcodebuild $*" >> "$STATE/calls"
prev=""; for a; do [ "$prev" = "-derivedDataPath" ] && d="$a"; prev="$a"; done
case "$*" in *Simulator*) plat=iphonesimulator ;; *) plat=iphoneos ;; esac
r="$d/Build/Products/Debug-$plat/WebDriverAgentRunner-Runner.app"
mkdir -p "$r/PlugIns/WebDriverAgentRunner.xctest/Frameworks/Inner.framework" "$r/Frameworks/XCTest.framework"
cat > "$r/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>x</string></dict></plist>
PLIST'
stub xcrun 'if [ "$1" = "simctl" ]; then
    echo "xcrun $*" >> "$STATE/calls"
    echo "    iPhone 17 (11111111-2222-3333-4444-555555555555) (Booted)"
    exit 0
fi
if [ "$1" = "actool" ]; then
    prev=""; for a; do
        [ "$prev" = "--compile" ] && c="$a"
        [ "$prev" = "--output-partial-info-plist" ] && p="$a"
        prev="$a"
    done
    : > "$c/Assets.car"
    printf "%s\n" "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" "<plist version=\"1.0\"><dict><key>CFBundleIcons</key><dict/></dict></plist>" > "$p"
    exit 0
fi
exit 1'
stub open 'exit 0'
stub swift 'for last; do :; done; : > "$last"'
stub sips 'prev=""; for a; do [ "$prev" = "--out" ] && : > "$a"; prev="$a"; done'
# Keychain: $STATE/identities holds "<sha1> <team>" lines, in keychain order.
stub security 'n=1
while read -r h t; do echo "  $n) $h \"Apple Development: Dev ($t)\""; n=$((n + 1)); done < "$STATE/identities"
echo "     $((n - 1)) valid identities found"'
stub openssl 'prev=""; for a; do [ "$prev" = "-in" ] && f="$a"; prev="$a"; done
echo "sha1 Fingerprint=$(cut -d" " -f2 "$f" | sed "s/../&:/g; s/:\$//")"'
# Signatures: a path we re-signed reports its signer team; anything else
# reports the team Xcode signed with ($STATE/xcode_signer, xcode_team).
stub codesign 'echo "codesign $*" >> "$STATE/calls"
key() { printf "%s" "$1" | shasum | cut -c1-16; }
team_of_hash() { awk -v h="$1" "\$1 == h { print \$2 }" "$STATE/identities"; }
case "$1" in
-dvv)
    if [ -f "$STATE/sig/$(key "$2")" ]; then t="$(team_of_hash "$(cat "$STATE/sig/$(key "$2")")")"
    else t="$(cat "$STATE/xcode_team")"; fi
    echo "Executable=$2" >&2
    echo "TeamIdentifier=${t:-not set}" >&2 ;;
-d)
    case "$2" in
    --entitlements) echo "<plist><dict><key>get-task-allow</key><true/></dict></plist>" ;;
    --extract-certificates) printf "CERT %s" "$(cat "$STATE/xcode_signer")" > codesign0 ;;
    esac ;;
--force)
    for last; do :; done
    mkdir -p "$STATE/sig"; echo "$3" > "$STATE/sig/$(key "$last")"
    echo "signed $3 $last" >> "$STATE/signed" ;;
esac
exit 0'

for tool in git go lipo strings xcodebuild xcrun open swift sips codesign security openssl; do
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

run_script() {   # script; env comes from the caller
    OUT="$(PATH="$TEST_PATH" HOME="$T/home" /bin/bash "$ROOT/scripts/$1" 2>&1)"
    CODE=$?
    CALLS="$(cat "$STATE/calls" 2>/dev/null)"
}

# ---- build-go-ios.sh ----

FORWARD='package forward

func Forward(device ios.DeviceEntry, hostPort uint16, phonePort uint16) (*ConnListener, error) {
	l, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", hostPort))
	if err != nil {
		return nil, err
	}
	return &ConnListener{listener: l}, nil
}'

goios_case() {   # forward.go body
    rm -rf "$ROOT" "$STATE"
    mkdir -p "$ROOT/scripts/lib" "$ROOT/tools/go-ios/ios/forward" "$STATE" "$T/home"
    cp "$REPO/scripts/build-go-ios.sh" "$ROOT/scripts/"
    cp "$REPO/scripts/lib/"*.sh "$ROOT/scripts/lib/"
    [[ -n "$1" ]] && printf '%s\n' "$1" > "$ROOT/tools/go-ios/ios/forward/forward.go"
    echo "$GOIOS_REV" > "$STATE/rev"
    : > "$STATE/calls"
}
GOIOS_REV=2fb34682ef12db97c9fafdf99f1dd1d3522604ad   # v1.3.2
FWD="$ROOT/tools/go-ios/ios/forward/forward.go"

goios_case "$FORWARD"
run_script build-go-ios.sh
check "build-go-ios.sh builds after patching" [ "$CODE" = 0 ]
check "forward binds 127.0.0.1" grep -qF 'fmt.Sprintf("127.0.0.1:%d", hostPort)' "$FWD"
check "no wildcard listen is left" bash -c "! grep -q '0\\.0\\.0\\.0' '$FWD'"
check "the patch runs before go build" has "$OUT" "patching ios/forward"
check "go-ios was built" has "$CALLS" "go build -o bin/ios-arm64"
check "the universal binary exists" [ -f "$ROOT/tools/go-ios/bin/ios" ]
check "x/crypto is raised to the audited version" has "$CALLS" "golang.org/x/crypto@v0.57.0"
check "x/net is raised to the audited version" has "$CALLS" "golang.org/x/net@v0.60.0"
check "quic-go is no longer forced down" hasnt "$CALLS" "quic-go"
cp "$FWD" "$T/after-first"
: > "$STATE/calls"
run_script build-go-ios.sh
check "a second build still passes (idempotent)" [ "$CODE" = 0 ]
check "a second build leaves forward.go as it was" cmp -s "$FWD" "$T/after-first"

goios_case "${FORWARD/fmt.Sprintf(\"0.0.0.0:%d\", hostPort)/fmt.Sprintf(\":%d\", hostPort)}"
run_script build-go-ios.sh
check "a moved listener fails the build" [ "$CODE" = 1 ]
check "the failure says the patch failed" has "$OUT" "patch FAILED"
check "nothing is built after a failed patch" hasnt "$CALLS" "go "

goios_case "$FORWARD"; echo 3661ad60e066231c9fb38b3a492117d730580882 > "$STATE/rev"
run_script build-go-ios.sh
check "another go-ios revision is refused" [ "$CODE" = 1 ]
check "the refusal names the wanted version" has "$OUT" "must be v1.3.2"
check "nothing is built from another revision" hasnt "$CALLS" "go "
check "another revision's forward.go is left alone" grep -qF '"0.0.0.0:%d"' "$FWD"

goios_case ""
run_script build-go-ios.sh
check "a missing forward.go fails the build" [ "$CODE" = 1 ]
check "nothing is built without forward.go" hasnt "$CALLS" "go "

goios_case "$FORWARD"; touch "$STATE/leak-wildcard"
run_script build-go-ios.sh
check "a binary that still has 0.0.0.0 fails" [ "$CODE" = 1 ]
check "that failure names the check" has "$OUT" "check FAILED"

# ---- build-wda.sh ----

H1=1111111111111111111111111111111111111111   # another team, first in the keychain
H2=2222222222222222222222222222222222222222   # the right team
H9=9999999999999999999999999999999999999999   # not in the keychain
RUNNER_REL="build/wda-derived/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app"

# The lines of WDA v16.14.2's FBTypeText that the patch rewrites.
TYPING='BOOL FBTypeText(NSString *text, NSUInteger typingSpeed, NSError **error)
{
  NSString *name = text.length <= MAX_TEXT_ABBR_LEN
    ? [NSString stringWithFormat:@"Type '"'"'%@'"'"'", text]
    : [NSString stringWithFormat:@"Type '"'"'%@…'"'"'", [text substringToIndex:MAX_TEXT_ABBR_LEN]];
  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc] initWithName:name];
  XCPointerEventPath *ep = [[XCPointerEventPath alloc] initForTextInput];
  [ep typeText:text
      atOffset:0.0
   typingSpeed:typingSpeed
  shouldRedact:NO];
  [eventRecord addPointerEventPath:ep];
  return [FBXCTestDaemonsProxy synthesizeEventWithRecord:eventRecord error:error];
}'
TYPING_REL="tools/WebDriverAgent/WebDriverAgentLib/Categories/XCUIElement+FBTyping.m"

wda_tree() {   # FBTypeText body; a fresh repo layout with a WDA tree
    rm -rf "$ROOT" "$STATE"
    mkdir -p "$ROOT/scripts/lib" "$ROOT/tools/WebDriverAgent/WebDriverAgentLib/Categories" \
        "$ROOT/tools/WebDriverAgent/WebDriverAgent.xcodeproj" "$STATE" "$T/home"
    cp "$REPO/scripts/build-wda.sh" "$REPO/scripts/sim-wda-up.sh" "$ROOT/scripts/"
    cp "$REPO/scripts/lib/"*.sh "$ROOT/scripts/lib/"
    printf '%s\n' "$1" > "$ROOT/$TYPING_REL"
    echo '{"name": "appium-webdriveragent", "version": "16.14.2"}' > "$ROOT/tools/WebDriverAgent/package.json"
    : > "$STATE/calls"; : > "$STATE/signed"
}
typing_redacted() {
    grep -qF 'NSString *name = @"Type text";' "$ROOT/$TYPING_REL" \
        && grep -q 'shouldRedact:YES' "$ROOT/$TYPING_REL" \
        && ! grep -q 'shouldRedact:NO' "$ROOT/$TYPING_REL" \
        && ! grep -qF "Type '%@" "$ROOT/$TYPING_REL"
}

wda_case() {   # xcode signer hash, keychain lines...
    wda_tree "$TYPING"
    echo "$1" > "$STATE/xcode_signer"
    echo "RIGHTTEAM1" > "$STATE/xcode_team"
    shift
    printf '%s\n' "$@" > "$STATE/identities"
}
signed_with() { grep -q "^signed $1 " "$STATE/signed"; }
never_signed_with() { ! grep -q "^signed $1 " "$STATE/signed"; }
line_of() { grep -n "$1" "$STATE/signed" | head -1 | cut -d: -f1; }

wda_case "$H2" "$H1 WRONGTEAM9" "$H2 RIGHTTEAM1"
DEVELOPMENT_TEAM=RIGHTTEAM1 run_script build-wda.sh
check "build-wda.sh signs and packages" [ "$CODE" = 0 ]
check "it re-signs with the runner's own identity" signed_with "$H2"
check "it never uses the first keychain identity of another team" never_signed_with "$H1"
check "the test bundle is re-signed" grep -q "PlugIns/WebDriverAgentRunner.xctest$" "$STATE/signed"
check "frameworks are re-signed" grep -q "Frameworks/XCTest.framework$" "$STATE/signed"
check "nested code is signed before the runner" \
    [ "$(line_of 'xctest$')" -lt "$(line_of 'Runner.app$')" ]
check "the ipa is written" [ -f "$ROOT/build/WebDriverAgent.ipa" ]
check "the team is checked on the runner" has "$CALLS" "codesign -dvv $ROOT/$RUNNER_REL"
check "typed text is redacted before the build" typing_redacted
check "the runner carries the WDA version" \
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/$RUNNER_REL/Info.plist")" = 16.14.2 ]
check "the ipa line names the WDA version" has "$OUT" "WDA 16.14.2"
cp "$ROOT/$TYPING_REL" "$T/typing-after-first"
: > "$STATE/calls"
DEVELOPMENT_TEAM=RIGHTTEAM1 run_script build-wda.sh
check "a second WDA build still passes (idempotent)" [ "$CODE" = 0 ]
check "a second WDA build leaves FBTypeText as it was" cmp -s "$ROOT/$TYPING_REL" "$T/typing-after-first"

wda_case "$H2" "$H2 RIGHTTEAM1"
printf '%s\n' "${TYPING/shouldRedact:NO/shouldRedact:flag}" > "$ROOT/$TYPING_REL"
DEVELOPMENT_TEAM=RIGHTTEAM1 run_script build-wda.sh
check "a moved FBTypeText fails the WDA build" [ "$CODE" = 1 ]
check "that failure says the WDA patch failed" has "$OUT" "WDA patch FAILED"
check "nothing is built after a failed WDA patch" hasnt "$CALLS" "xcodebuild"

wda_case "$H2" "$H2 RIGHTTEAM1"
echo '{}' > "$ROOT/tools/WebDriverAgent/package.json"
DEVELOPMENT_TEAM=RIGHTTEAM1 run_script build-wda.sh
check "no WDA version fails the build" [ "$CODE" = 1 ]
check "no ipa without a WDA version" [ ! -f "$ROOT/build/WebDriverAgent.ipa" ]

wda_case "$H2" "$H1 WRONGTEAM9" "$H2 RIGHTTEAM1"
WDA_SIGN_IDENTITY="$H1" DEVELOPMENT_TEAM=RIGHTTEAM1 run_script build-wda.sh
check "a wrong-team WDA_SIGN_IDENTITY fails" [ "$CODE" = 1 ]
check "the failure names the team it got" has "$OUT" "TeamIdentifier=WRONGTEAM9"
check "the failure names the wanted team" has "$OUT" "DEVELOPMENT_TEAM is RIGHTTEAM1"
check "no ipa after a wrong team" [ ! -f "$ROOT/build/WebDriverAgent.ipa" ]

wda_case "$H9" "$H1 WRONGTEAM9" "$H2 RIGHTTEAM1"
DEVELOPMENT_TEAM=RIGHTTEAM1 run_script build-wda.sh
check "a signer missing from the keychain falls back by team" [ "$CODE" = 0 ]
check "the fallback picks the identity of the team" signed_with "$H2"

wda_case "$H9" "$H1 WRONGTEAM9"
DEVELOPMENT_TEAM=RIGHTTEAM1 run_script build-wda.sh
check "no identity of the team fails" [ "$CODE" = 1 ]
check "that failure names the team" has "$OUT" "for team RIGHTTEAM1"

# ---- sim-wda-up.sh (build half; test-without-building is a stub) ----

SIM_UDID=11111111-2222-3333-4444-555555555555
run_sim() {
    OUT="$(PATH="$TEST_PATH" HOME="$T/home" WDA_SIM_BUILD_DIR="$T/simbuild" \
        WDA_PROJECT="$ROOT/tools/WebDriverAgent/WebDriverAgent.xcodeproj" PORT=8299 \
        /bin/bash "$ROOT/scripts/sim-wda-up.sh" "$SIM_UDID" 2>&1)"
    CODE=$?
    CALLS="$(cat "$STATE/calls" 2>/dev/null)"
}

wda_tree "$TYPING"
run_sim
check "sim-wda-up.sh builds and launches" [ "$CODE" = 0 ]
check "the Simulator WDA has typed text redacted" typing_redacted
check "the Simulator WDA is built after the patch" has "$CALLS" "xcodebuild build-for-testing"

wda_tree "${TYPING/shouldRedact:NO/shouldRedact:flag}"
run_sim
check "a moved FBTypeText stops the Simulator build" [ "$CODE" = 1 ]
check "nothing is built for the Simulator then" hasnt "$CALLS" "xcodebuild"

echo "$PASSES passed, $FAILS failed"
[[ "$FAILS" == 0 ]]
