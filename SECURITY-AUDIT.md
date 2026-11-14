# Dependency Security Audit

Record of every third-party dependency introduced, how it was vetted, and the
residual risk accepted. Re-run the scans on every version bump.

Scanner: `osv-scanner` 2.6.0 (Google, OSV database). Toolchain: Go 1.27.1.
Audit date: 2026-10-09. This record of go-ios v1.3.2 and WebDriverAgent
v16.14.2 is upstream iMirror's (kwamerex101/phone_screen_mirror `6ed6ecd`),
taken as-is when the fork moved to the same pins; the fork has not re-run the
scans. The fork's own source patches follow each dependency.

## Policy (enforced)

Source-available · pinned to exact tag **and** verified commit hash · scanned
with `osv-scanner` · built from source (no prebuilt-binary trust) · loopback-only
at runtime. No `curl | sh`, no unsigned binaries.

## Dependencies

### WebDriverAgent — appium/WebDriverAgent
- Version: **v16.14.2**, commit `d15c0b2dbaa850fa712fba817e51cf8d5026d9f2` (verified).
- License: Apache-2.0.
- Role: on-device XCUITest control app (runs on the iPhone).
- Scan result: **No issues found.**
- Build: by the user in Xcode, signed with their paid Apple Developer account.
- Since v14 the project's deployment floor is iOS 15.0 (was 12.0). The build
  scripts' `proj_floor` follows it.

#### Source patch: typed text is redacted
`FBTypeText` (`WebDriverAgentLib/Categories/XCUIElement+FBTyping.m`) names its
synthesized event `Type '<text>'` and passes `shouldRedact:NO`, so whatever
WDA types, a passcode included, enters testmanagerd's event record. Whether it
then reaches the device log is not verified. `scripts/build-wda.sh` and
`scripts/sim-wda-up.sh` patch it to the fixed name `Type text` with
`shouldRedact:YES` (`scripts/lib/wda-patches.sh`), the same flag WDA's own W3C
actions path already uses. The patch is idempotent and the build fails if it
did not apply. Not covered: with verbose logging on, WDA logs every request's
arguments, typed values included; iMirror never turns that on.

### go-ios — danielpaulus/go-ios
- Version: **v1.3.2**, commit `2fb34682ef12db97c9fafdf99f1dd1d3522604ad` (verified).
- License: MIT.
- Role: USB transport — tunnel (iOS 17+), launch WDA, forward port 8100. Runs on
  the Mac. We build ONLY the root `ios` CLI; the `ncm/` and `restapi/`
  submodules are not built or run.
- Built from source with `GOWORK=off` (root module only), cross-compiled for
  both `arm64` and `amd64` (`CGO_ENABLED=0`) and `lipo`-merged into a universal2
  binary by `scripts/build-go-ios.sh` — still source-built, no prebuilt-binary
  trust. Patched transitive deps (only crypto and net are pinned; Go's
  minimum-version selection raises the rest):

  | Package | Pinned in tag | Patched to | Status |
  |---|---|---|---|
  | golang.org/x/crypto | 0.52.0 | 0.57.0 | ✅ fixed (one residual, see below) |
  | golang.org/x/net | 0.55.0 | 0.60.0 | ✅ fixed |
  | golang.org/x/text | 0.37.0 | 0.42.0 | ✅ fixed |
  | golang.org/x/mod | 0.35.0 | 0.41.0 | ✅ fixed |
  | golang.org/x/sys | 0.45.0 | 0.48.0 | ✅ fixed |
  | stdlib | go 1.26.0 directive | built w/ Go 1.27.1 | ✅ moot (newer than all fixes) |
  | github.com/quic-go/quic-go | 0.59.1 | 0.59.1 | ✅ fixed upstream |

  The quic-go 0.49.1 residual recorded for v1.1.0 is gone: go-ios v1.3.x moved
  to the `quic.Conn` API and ships quic-go 0.59.1, past every listed advisory.
  `scripts/build-go-ios.sh` refuses any other go-ios revision.

#### Source patch: `forward` binds 127.0.0.1
Upstream `ios/forward/forward.go` listens on `0.0.0.0:<hostPort>` (still so in
v1.3.2). iMirror runs `ios forward` for every phone's WDA port (81x1) and MJPEG
port (91x0), so an unpatched build put unauthenticated control of the phone,
and its live screen, on every network the Mac joins. Found 2026-10-19: `lsof`
showed `*:8111` and `*:9120`, and the macOS firewall was off.

`scripts/build-go-ios.sh` patches that one line to `127.0.0.1:%d`
(`scripts/lib/goios-patches.sh`) before it builds. The patch is idempotent, and
the build fails if the exact loopback listen is not there afterwards, if any
`0.0.0.0` is left in the file, or if the built binary still contains
`0.0.0.0:%d`. Every client already dials 127.0.0.1, so nothing else changes.
`scripts/tests/test-build-scripts.sh` covers the patch (run by `swift test`).
The other listeners in the built root module (the tunnel agent, the userspace
tunnel ports) already bind loopback in v1.3.2.

A running app keeps the binary it was built with: rebuild go-ios, rebuild the
app (`scripts/run.sh` copies `tools/go-ios/bin/ios` into it) and restart it.

#### Residual risk: GO-2026-5932 (x/crypto/openpgp)
Flagged against every x/crypto version: the `openpgp` package is deprecated
and has no fix. **Accepted because** nothing in the built root module imports
`golang.org/x/crypto/openpgp` (verified by grep), so the vulnerable code is not
compiled into the binary. The `restapi/` submodule has many stale-dep findings
but is not built or shipped.

## Runtime security

- WDA's HTTP server (:8100) has **no authentication**. Only ever reached over
  USB-forwarded loopback. iMirror's WDAClient hard-rejects any non-127.0.0.1 host,
  and the go-ios forwards bind 127.0.0.1 (source patch above).
- Control is OFF by default; the user must explicitly connect + enable it.
