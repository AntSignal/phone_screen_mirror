# Source patches build-wda.sh and sim-wda-up.sh apply to the pinned
# WebDriverAgent tree before they build. Source it; it defines functions
# only. Each patch is idempotent and checks its own result, so a WDA bump
# that moves the patched code fails the build instead of shipping a leak.

WDA_TYPING_FILE="WebDriverAgentLib/Categories/XCUIElement+FBTyping.m"
# The event name each typing call must carry after the patch.
WDA_TYPING_NAME='NSString *name = @"Type text";'

# True when FBTypeText's event has a fixed name and is redacted.
wda_typing_is_redacted() {
    grep -qF "$WDA_TYPING_NAME" "$1" \
        && grep -q 'shouldRedact:YES' "$1" \
        && ! grep -q 'shouldRedact:NO' "$1" \
        && ! grep -qF "Type '%@" "$1"
}

# FBTypeText names its event "Type '<text>'" and sets shouldRedact:NO, so
# typed text (a passcode, too) lands in testmanagerd's event record. Give
# the event a fixed name and redact it. $1 is the WDA source dir.
wda_patch_redact_typing() {
    local f="$1/$WDA_TYPING_FILE"
    if [[ ! -f "$f" ]]; then
        echo "WDA patch: $f not found" >&2
        return 1
    fi
    # Leave a patched file alone, so Xcode does not rebuild it every run.
    if ! wda_typing_is_redacted "$f"; then
        /usr/bin/perl -0pi -e '
            s/NSString \*name = text\.length <= MAX_TEXT_ABBR_LEN\b.*?;\n/NSString *name = \@"Type text";\n/s;
            s/shouldRedact:NO\]/shouldRedact:YES]/g;' "$f"
    fi
    if wda_typing_is_redacted "$f"; then
        return 0
    fi
    echo "WDA patch FAILED: $f still names or keeps typed text." >&2
    echo "WebDriverAgent moved FBTypeText; update scripts/lib/wda-patches.sh." >&2
    return 1
}
