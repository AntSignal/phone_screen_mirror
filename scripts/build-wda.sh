#!/usr/bin/env bash
# Build WebDriverAgent at the pinned upstream tag, fully rebranded to iMirror,
# WITHOUT forking. The bundle id is a build setting; the on-device display name and
# app icon are applied to Xcode's generated runner .app as a post-build patch and
# re-sign (Xcode's XCTest runner wrapper has a default name and no icon, and neither
# INFOPLIST_KEY_* nor the .xctest's own plist affect that wrapper). A WDA version
# bump is just a re-clone + re-run of this script. Produces one installable .ipa.
#
# Requires: Xcode, a connected iPhone (for provisioning), and a PAID Apple Team
# (DEVELOPMENT_TEAM). Re-signs with the same "Apple Development" certificate
# Xcode signed the runner with, which belongs to $DEVELOPMENT_TEAM. Set
# WDA_SIGN_IDENTITY=<sha1> to choose one; the team check still applies.
#
#   DEVELOPMENT_TEAM=<TEAMID> ./scripts/build-wda.sh
#   tools/go-ios/bin/ios install --udid=<UDID> --path=build/WebDriverAgent.ipa
set -euo pipefail

# Emits a single "IPHONEOS_DEPLOYMENT_TARGET=<v>" build-setting arg on stdout,
# or nothing. Additive: only overrides when the active SDK's own minimum
# deployment target meets WebDriverAgent's 15.0 floor, so older Xcode
# (whose floor is < 15.0) is left exactly as before. Set
# WDA_DEPLOYMENT_TARGET to force a specific value (e.g. 15.0 to opt out).
wda_deployment_setting() {  # $1 = sdk name: iphonesimulator | iphoneos
    local sdk="$1" proj_floor="15.0" sdk_min sdkpath plist lowest
    if [[ -n "${WDA_DEPLOYMENT_TARGET:-}" ]]; then
        echo "IPHONEOS_DEPLOYMENT_TARGET=${WDA_DEPLOYMENT_TARGET}"; return 0
    fi
    sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null)" || return 0
    plist="$sdkpath/SDKSettings.plist"
    [[ -f "$plist" ]] || return 0
    sdk_min="$(/usr/libexec/PlistBuddy -c "Print :SupportedTargets:$sdk:MinimumDeploymentTarget" "$plist" 2>/dev/null)" || return 0
    [[ -n "$sdk_min" ]] || return 0
    lowest="$(printf '%s\n%s\n' "$proj_floor" "$sdk_min" | sort -V | head -1)"
    # Vendored targets may still say 12.0, so set it at 15.0 too.
    if [[ "$lowest" == "$proj_floor" ]]; then
        echo "IPHONEOS_DEPLOYMENT_TARGET=$sdk_min"
    fi
    return 0
}
# The TeamIdentifier codesign reports for $1, or nothing.
wda_team_of() {
    { codesign -dvv "$1" 2>&1 || true; } | awk -F= '$1 == "TeamIdentifier" { print $2 }'
}

# SHA-1 of the certificate that signed $1. $2 is a scratch dir, since
# --extract-certificates writes codesign0.. into the current directory.
wda_signer_sha1() {
    ( cd "$2" && rm -f codesign0 codesign1 codesign2 \
        && codesign -d --extract-certificates "$1" ) >/dev/null 2>&1 || return 1
    [[ -f "$2/codesign0" ]] || return 1
    openssl x509 -inform DER -in "$2/codesign0" -noout -fingerprint -sha1 2>/dev/null \
        | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F'
}

# Every "Apple Development" identity in the keychain, one SHA-1 per line.
wda_dev_identities() {
    security find-identity -v -p codesigning | grep 'Apple Development' \
        | grep -oE '[0-9A-F]{40}' || true
}

# The identity to re-sign with. A Mac with two "Apple Development" identities
# made grep -m1 pick the wrong team, and installs failed with 0xe8008015.
# $1 runner, $2 scratch dir, $3 wanted team.
wda_pick_identity() {
    local runner="$1" scratch="$2" team="$3" id ids probe
    if [[ -n "${WDA_SIGN_IDENTITY:-}" ]]; then
        echo "$WDA_SIGN_IDENTITY"; return 0
    fi
    ids="$(wda_dev_identities)"
    id="$(wda_signer_sha1 "$runner" "$scratch" || true)"
    if [[ -n "$id" ]] && grep -qx "$id" <<<"$ids"; then
        echo "$id"; return 0
    fi
    # Not in the keychain: find the team by test-signing.
    probe="$scratch/team-probe"
    for id in $ids; do
        cp /usr/bin/true "$probe"
        codesign --force --sign "$id" "$probe" >/dev/null 2>&1 || continue
        if [[ "$(wda_team_of "$probe")" == "$team" ]]; then
            echo "$id"; return 0
        fi
    done
    return 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WDA_SRC="$ROOT/tools/WebDriverAgent"
PROJ="$WDA_SRC/WebDriverAgent.xcodeproj"
source "$ROOT/scripts/lib/wda-patches.sh"
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your paid Apple Team id}"
DERIVED="$ROOT/build/wda-derived"
BUNDLE_ID="com.local.imirror.WebDriverAgentRunner"
DISPLAY_NAME="iMirror"

# Additive Xcode-27 accommodation: only set when the device SDK's own
# minimum deployment target meets WDA's 15.0 (see
# wda_deployment_setting above). Empty on older Xcode, so nothing changes.
depset=()
dep_setting="$(wda_deployment_setting iphoneos)"
[[ -n "$dep_setting" ]] && depset=("$dep_setting")

echo "==> patching WebDriverAgent so typed text is redacted"
wda_patch_redact_typing "$WDA_SRC" || exit 1

echo "==> building rebranded WebDriverAgentRunner (bundle id $BUNDLE_ID)"
# Xcode-26 build accommodations for the vendored WDA:
#   -allowProvisioningUpdates : register the new branded App ID + mint a dev profile
#       (else "No profiles for '<id>' were found").
#   GCC_TREAT_WARNINGS_AS_ERRORS=NO : WDA's vendored XCTest PrivateHeaders trip
#       clang's -Wreserved-identifier (35 errors on Xcode 26).
# Do NOT override PRODUCT_NAME (it applies to ALL targets, renaming
#   WebDriverAgentLib's header-map namespace and breaking <WebDriverAgentLib/*.h>
#   imports), and do NOT pass RUN_CLANG_STATIC_ANALYZER=NO or
#   CLANG_ENABLE_EXPLICIT_MODULES=NO (they break header-map lookups too).
# WDA_DESTINATION defaults to a device-agnostic build. To onboard a NEW device,
# point it at that device so -allowProvisioningUpdates registers its UDID into the
# profile (else install fails with "A valid provisioning profile ... was not found"):
#   WDA_DESTINATION="id=<UDID>" ./scripts/build-wda.sh
xcodebuild build-for-testing \
    -project "$PROJ" \
    -scheme WebDriverAgentRunner \
    -destination "${WDA_DESTINATION:-generic/platform=iOS}" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    "${depset[@]+"${depset[@]}"}"

PROD="$DERIVED/Build/Products/Debug-iphoneos"
RUNNER="$PROD/WebDriverAgentRunner-Runner.app"
[[ -d "$RUNNER" ]] || { echo "runner app not found at $RUNNER" >&2; exit 1; }

# --- Brand the generated runner .app: app icon + display name, then re-sign. ---
echo "==> branding the runner (icon + name '$DISPLAY_NAME') and re-signing"
ASSETS="$ROOT/build/wda-assets"
ICONSET="$ROOT/build/AppIcon.xcassets/AppIcon.appiconset"
rm -rf "$ROOT/build/AppIcon.xcassets" "$ASSETS"; mkdir -p "$ICONSET" "$ASSETS"

# 1024 iMirror icon (same artwork as the Mac app), flattened to opaque (iOS rejects
# alpha), compiled into an asset catalog with actool.
swift "$ROOT/scripts/make_ios_icon.swift" "$ASSETS/icon-1024.png"
sips -s format jpeg "$ASSETS/icon-1024.png" --out "$ASSETS/icon.jpg"      >/dev/null
sips -s format png  "$ASSETS/icon.jpg"      --out "$ICONSET/icon-1024.png" >/dev/null
cat > "$ICONSET/Contents.json" <<'JSON'
{ "images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],
  "info":{"author":"xcode","version":1} }
JSON
xcrun actool "$ROOT/build/AppIcon.xcassets" --compile "$ASSETS" \
  --platform iphoneos --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist "$ASSETS/partial.plist" >/dev/null

# Preserve the runner's entitlements (get-task-allow etc.) across the re-sign —
# without them the XCUITest runner can't attach and WDA never goes ready.
codesign -d --entitlements :- "$RUNNER" > "$ASSETS/ent.plist" 2>/dev/null
grep -q "get-task-allow" "$ASSETS/ent.plist" || { echo "runner entitlements missing get-task-allow" >&2; exit 1; }

# Inject icon + name into the wrapper, then merge actool's CFBundleIcons keys.
cp "$ASSETS/Assets.car" "$RUNNER/Assets.car"
cp "$ASSETS"/AppIcon*.png "$RUNNER/" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $DISPLAY_NAME" "$RUNNER/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$RUNNER/Info.plist"
# Stamp the WDA release: the app reinstalls a phone's older runner.
WDA_VERSION="$(/usr/bin/plutil -extract version raw "$WDA_SRC/package.json" 2>/dev/null || true)"
[[ -n "$WDA_VERSION" ]] || { echo "could not read the WDA version from $WDA_SRC/package.json" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $WDA_VERSION" "$RUNNER/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $WDA_VERSION" "$RUNNER/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $WDA_VERSION" "$RUNNER/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $WDA_VERSION" "$RUNNER/Info.plist"
/usr/libexec/PlistBuddy -c "Merge '$ASSETS/partial.plist'" "$RUNNER/Info.plist"

# Re-sign inside out with Xcode's identity: nested code, then the runner.
SIGNID="$(wda_pick_identity "$RUNNER" "$ASSETS" "$DEVELOPMENT_TEAM" || true)"
[[ -n "$SIGNID" ]] || { echo "no 'Apple Development' identity for team $DEVELOPMENT_TEAM found" >&2; exit 1; }
echo "    signing identity $SIGNID"
shopt -s nullglob
for nested in "$RUNNER"/PlugIns/*.xctest/Frameworks/* "$RUNNER"/PlugIns/*.xctest \
              "$RUNNER"/Frameworks/*; do
    codesign --force --sign "$SIGNID" --preserve-metadata=identifier,entitlements "$nested"
done
shopt -u nullglob
codesign --force --sign "$SIGNID" --entitlements "$ASSETS/ent.plist" "$RUNNER"
codesign --verify --deep --strict "$RUNNER"

# The runner and its test bundle must both carry the team, or iOS refuses
# the install. --verify does not check which team signed.
for signed in "$RUNNER" "$RUNNER"/PlugIns/*.xctest; do
    got="$(wda_team_of "$signed")"
    if [[ "$got" != "$DEVELOPMENT_TEAM" ]]; then
        echo "signed with the wrong team: $signed has TeamIdentifier=${got:-none}," >&2
        echo "but DEVELOPMENT_TEAM is $DEVELOPMENT_TEAM (identity $SIGNID)." >&2
        exit 1
    fi
done

# Package the runner .app into an installable .ipa (Payload/<App> then zip).
rm -rf "$ROOT/build/Payload" "$ROOT/build/WebDriverAgent.ipa"
mkdir -p "$ROOT/build/Payload"
cp -R "$RUNNER" "$ROOT/build/Payload/"
( cd "$ROOT/build" && zip -qr WebDriverAgent.ipa Payload )
rm -rf "$ROOT/build/Payload"
echo "==> ipa: $ROOT/build/WebDriverAgent.ipa  (id ${BUNDLE_ID}.xctrunner, name '$DISPLAY_NAME', branded icon, WDA $WDA_VERSION)"
