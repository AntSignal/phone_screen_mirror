<div align="center">

<img src=".github/assets/hero.svg" alt="iMirror — mirror and control a real iPhone from macOS while the phone stays live" width="100%">

# iMirror

![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Swift](https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white)
![Python](https://img.shields.io/badge/Python-3776AB?logo=python&logoColor=white)
[![Release](https://img.shields.io/github/v/release/kwamerex101/phone_screen_mirror?label=download)](https://github.com/kwamerex101/phone_screen_mirror/releases/latest)

**Mirror a USB-connected iPhone to a macOS window and control it from the Mac — while the phone stays physically usable.**

</div>

Unlike Apple's "iPhone Mirroring", the phone is never locked. iMirror is two
tools in one:

1. **A desktop mirror + remote control** — watch and drive the phone from a Mac
   window.
2. **An agent-driven test rig for real devices** — the bundled
   [MCP server](mcp-server/) lets an AI agent (e.g. Claude) run test flows on the
   physical phone — tap, scroll, type, assert by visible text — and emit a
   self-contained HTML report with screenshots, pass/fail sections, and a
   timelapse. Neither Appium nor Maestro packages real-device evidence reports
   this way; in practice this is the most distinctive part of the project.

Features:

- **The phone keeps its own audio.** iMirror renders the mirror from
  WebDriverAgent's MJPEG stream instead of grabbing the screen as a capture
  device, so iOS never reroutes audio to the Mac (the old CoreMediaIO/QuickTime
  behavior). The phone stays unlocked, usable, and audible while you watch and
  drive it, plus full-resolution PNG screenshots.
- **Toolbar** — Screenshot, a WDA health dot, Control, Settings, and Home.
- **Control** — tap, drag, two-finger trackpad scroll (with flick detection),
  type, Home, driven from the preview.
- **Agent control + test reports** — a full set of `ios_*` MCP tools, opt-in run
  recording, cover/TOC/infographics HTML reports (see
  [MCP server](#mcp-server-drive-the-phone-from-claude)).
- **Automation starts on launch.** Mirroring is built on WebDriverAgent, so the
  app brings it up automatically when it connects to the phone (no Xcode, no
  sudo, no terminal) — a toolbar health dot + auto-reconnect. iOS shows the
  "Automation Running" overlay while this runs; the phone stays unlocked and
  keeps its own audio the whole time. The Settings (⚙) popover has a
  scroll-speed control, a one-click **MCP server install**, the on-device
  **WebDriverAgent app status**, and the app version/build.
- **Auto-installs the runner** — on connect, the app checks whether the
  WebDriverAgent app is on the connected iPhone and installs the bundled build if
  it's missing, with progress and actionable errors (e.g. "not signed for this
  iPhone — re-sign for this device"). A pre-provisioned device just works. A
  runner older than the bundled one (its `CFBundleShortVersionString`, which
  `build-wda.sh` stamps) is reinstalled; a newer one is kept, and a failed
  upgrade keeps the old runner running. The new runner may ask for the
  phone's passcode once ("Enable UI Automation").
- **iOS Simulator support** — no physical phone required: enable any number of
  simulators (from **Settings (⚙) → iOS Simulator**, a shell, or the MCP server's
  `sim_enable`) and iMirror brings WebDriverAgent up on each, so an agent can drive
  and test simulator builds too, several at once. You view the sims in Apple's
  Simulator app; requires Xcode.

The app code is dependency-free Swift (AppKit, Network, CoreGraphics/ImageIO).
Control rides on two vetted, source-built tools —
[`go-ios`](https://github.com/danielpaulus/go-ios) and
[`WebDriverAgent`](https://github.com/appium/WebDriverAgent) — that live under
`tools/` (gitignored) and are bundled into the `.app` at package time.

## Screenshots

<div align="center">

<img src="docs/images/mirror.png" alt="iPhone mirrored live to the Mac" width="300">
&nbsp;&nbsp;
<img src="docs/images/settings.png" alt="iMirror Settings popover" width="360">

</div>

Left: an iPhone mirrored live to the Mac while the phone stays usable — the
mirror follows the phone's **physical orientation**, and tap/drag coordinates
adapt automatically. Right: the **Settings (⚙)** popover — scroll-speed, the
on-device **WebDriverAgent app status**, one-click **MCP server install**, and
the app version/build. (This screenshot predates the current toolbar, which is
now Screenshot, WDA, Control, Settings, Home.)

## Install

Grab the notarized DMG from the
[**latest release**](https://github.com/kwamerex101/phone_screen_mirror/releases/latest),
open it, and drag **iMirror** to Applications. The DMG bundles everything the app
needs — the `go-ios` helper and the WebDriverAgent runner — so there's no Xcode,
no Go, and no `tools/` setup.

1. Connect your iPhone by USB, unlock it, and tap **Trust**.
2. Open iMirror. It installs the WebDriverAgent runner on the phone if it's
   missing and brings it up automatically — the phone stays unlocked and keeps
   its own audio, though iOS shows the "Automation Running" overlay while this
   runs. The health dot goes green once the mirror is live.
3. To control the phone, flip **Control** in the toolbar.

> **One Apple caveat:** the bundled runner is dev-signed for registered devices.
> A brand-new iPhone that isn't in the signing profile can't be auto-installed —
> the app says so and points you at the re-sign step
> (`WDA_DESTINATION=id=<udid> ./scripts/build-wda.sh`). This is an Apple
> code-signing constraint, not a choice. See **Build from source** below.

## Build from source

Everything below is for **building the app yourself** (and producing the DMG
above). `tools/` is gitignored, so a fresh clone starts empty — the `go-ios`
binary and the WebDriverAgent `.ipa` are built here and then bundled into the
`.app` by `scripts/package.sh`.

### Requirements

- macOS 14+ on **Apple Silicon or Intel** — the released DMG is a universal2
  build (built/tested on macOS 26, Xcode 26, Swift 6.3)
- An iPhone connected by USB, unlocked, "Trust This Computer" accepted, with
  **Developer Mode** on (Settings → Privacy & Security → Developer Mode)
- A **paid Apple Developer account** to sign WebDriverAgent (a free account works
  but its cert expires every 7 days)
- For building the `go-ios` helper from source: **Go** and **osv-scanner**
  (`brew install go osv-scanner`)

### Set up `tools/` (one-time)

`tools/` is not committed (it holds large third-party clones). Populate it at the
audited, pinned versions — see [SECURITY-AUDIT.md](SECURITY-AUDIT.md) for the
exact commits and scan results:

```bash
mkdir -p tools && cd tools
git clone --depth 1 --branch v1.3.2 https://github.com/danielpaulus/go-ios
git clone --depth 1 --branch v16.14.2 https://github.com/appium/WebDriverAgent

# (optional but recommended) scan before building:
osv-scanner scan source -r --no-ignore --include-git-root go-ios
osv-scanner scan source -r --no-ignore --include-git-root WebDriverAgent

# build the go-ios CLI from source as a universal2 (arm64 + x86_64) binary,
# patching vulnerable transitive deps — one helper that runs on both Intel and
# Apple Silicon, so the packaged DMG does too. It refuses any go-ios revision
# but the audited v1.3.2:
cd ..            # back to repo root
./scripts/build-go-ios.sh
```

Then install WebDriverAgent on the device once (Xcode):

1. Open `tools/WebDriverAgent/WebDriverAgent.xcodeproj`.
2. Scheme **WebDriverAgentRunner**, destination = your iPhone.
3. For targets **WebDriverAgentRunner** + **WebDriverAgentLib**: Signing &
   Capabilities → *Automatically manage signing* → select your paid Team.
4. **Product → Test (⌘U)** — builds, signs, installs WDA; trust the developer
   cert on the phone when prompted. You can stop the test afterward — the app
   relaunches WDA itself (see below).

   Note: on newer Xcode (tested on Xcode 26), WDA's vendored XCTest headers trip
   clang's `-Wreserved-identifier`; a GUI build needs `-Wno-reserved-identifier`
   in `WARNING_CFLAGS`.

   **Command-line / rebranded build:** [`scripts/build-wda.sh`](scripts/build-wda.sh)
   builds, signs, and packages the runner into an installable `.ipa` from the
   terminal — handling the Xcode 26 accommodations for you (`-allowProvisioningUpdates`,
   warnings-as-errors off) — and fully rebrands the runner: **bundle id**
   (`com.local.imirror.WebDriverAgentRunner`), on-device **name** ("iMirror"), and
   **app icon** (the same logo as the Mac app, applied as a post-build patch +
   re-sign). So it installs as a first-class "iMirror" app under your own identity
   rather than `com.facebook.*`. Run it with your paid Team:
   `DEVELOPMENT_TEAM=<TEAMID> ./scripts/build-wda.sh`, then install with
   `tools/go-ios/bin/ios install --udid=<UDID> --path=build/WebDriverAgent.ipa`.
   The re-sign uses the certificate Xcode signed with (or `WDA_SIGN_IDENTITY=<sha1>`),
   and the script stops unless the runner and its `.xctest` both report
   `TeamIdentifier=$DEVELOPMENT_TEAM`, so a Mac with two "Apple Development"
   identities can no longer produce an ipa iOS refuses (0xe8008015). It also
   stamps the WDA release (from `package.json`) into the runner's
   `CFBundleShortVersionString`, and patches WDA so typed text is redacted
   (`scripts/lib/wda-patches.sh`; `sim-wda-up.sh` applies the same patch). See the
   [rebrand design](docs/2026-07-03-rebrand-wda-and-improvements-design.md) for the
   why/how. (The macOS app's `runwda` is already wired to launch the branded id.)

### Run (from source)

```bash
./scripts/run.sh            # debug build → bundle (with go-ios + icon) → launch
./scripts/run.sh release    # optimized build
```

#### Signing for development

`run.sh` signs ad hoc unless `IMIRROR_SIGN_IDENTITY` is set. An ad hoc
signature changes with every build, so macOS forgets iMirror's Bluetooth and
Documents permissions and asks again. With a stable identity they stay:

```bash
security find-identity -v -p codesigning     # pick an "Apple Development: …" name
export IMIRROR_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
./scripts/run.sh
```

`package.sh` uses it too, ahead of any Developer ID (no hardened runtime, no
timestamp, not notarizable: for this Mac only).

On launch the app connects to the iPhone and brings up WebDriverAgent
automatically (health dot green within ~30 s) — the phone stays unlocked and
keeps its own audio, though iOS shows the "Automation Running" overlay while
this runs. The mirror appears as soon as frames start arriving. **Screenshot**
saves a PNG of the latest frame.

Flip the **Control** switch to send taps / swipes / typing from the preview.
(On a narrow window, Control collapses into the toolbar's `»` overflow menu,
where it still works.) The Settings (⚙) popover also holds a scroll-speed
slider and the one-click **MCP server install** described below.

## How it works

**Video.** WebDriverAgent serves an MJPEG stream on the device (port 9100): a
multipart/x-mixed-replace sequence of JPEG frames. iMirror forwards that port
over USB, reads the stream on a raw socket, decodes each frame to a `CGImage`,
and draws it in the window — roughly 10–20 fps, tuned for glance-and-control
rather than smooth capture. Screenshots save the latest decoded frame as a PNG.
Frame rate and quality are tunable through WDA's session settings
(`mjpegServerFramerate`, `mjpegServerScreenshotQuality`). Since this isn't a
capture device, iOS never reroutes the phone's audio to the Mac, and the phone
is never locked.

**Control.** Clicks/keys on the preview are transformed to device points and sent
to WebDriverAgent (XCUITest) as W3C pointer/key actions. Control is off by
default and armed by the switch (only while the health dot is green).

Scrolling is two-finger trackpad scroll (or click-drag): the gesture is mapped to
a WDA swipe over the same path, respecting the system Natural-Scroll direction. A
fast release is detected as a *flick* and sent as one quick swipe so the scroll
jumps rather than crawling 1:1. Note WDA can't trigger iOS inertial momentum — a
swipe moves content ~1:1 and stops on release — so distance comes from a longer
swipe, not a faster one (the macOS momentum tail is intentionally dropped, since
the phone can't coast). The XCUITest "wait for quiescence" idle-wait is disabled
on session creation, which removes the multi-second stall that previously hit the
first swipe of a session.

**Self-managed transport.** On launch the app spawns `go-ios` as child processes
and runs an in-process loopback relay — one chain per iPhone attached by USB, all
sharing one tunnel. For the first phone (slot 0):

```
iMirror (CFNetwork)  → 127.0.0.1:8100 (relay) → :8101 (ios forward) --USB--> WDA HTTP  :8100
iMirror (raw socket) -------------------------→ :9110 (ios forward) --USB--> WDA MJPEG :9100
   ios tunnel start --userspace             iOS 17+ RSD tunnel (userspace = no root), shared
   ios runwda --udid=U                      launches WebDriverAgent on that phone (no Xcode)
   ios forward --udid=U 8101 8100           USB relay of WDA's HTTP port
   ios forward --udid=U 9110 9100           USB relay of WDA's MJPEG stream
```

**Several iPhones.** Every phone gets a port slot that sticks to its UDID: slot n
uses relay `8100+10n`, forward `8101+10n`, MJPEG `9110+10n` (so the second phone
is `:8110`), and an alias (`phone1`, `phone2`, … — rename it in Settings). Each
phone has its own health probe and recovery ladder and keeps running whether or
not the window shows it; the toolbar's phone picker (⌘] / ⌘[) chooses which one
is mirrored and controlled. A stuck phone restarts only its own chain while
another phone is healthy; the shared tunnel is restarted only when that phone
has no tunnel route or no other phone would notice (rate-limited to once per two
minutes, plus a manual "Restart USB tunnel (all phones)" in Settings). The app
publishes every phone to `~/Library/Application Support/iMirror/devices.json`,
which the MCP server reads — so one MCP server drives them all (see
[mcp-server/README.md](mcp-server/README.md#several-devices)). The app also joins
the WDA session an agent already has on a phone instead of creating its own:
WDA allows one session per phone, and creating one silently ends the agent's.

The MJPEG stream is read directly off its forwarded port over a raw socket, so
it skips the CFNetwork relay entirely — only the WDA HTTP path needs the relay
(see "Why the relay" below).

Children run with a writable working dir (`~/Library/Application Support/iMirror`)
and auto-restart on crash. `runwda` carries a readiness deadline: if WDA isn't
serving within ~40 s the runner is killed and respawned, since a wedged runner
otherwise never exits on its own. Each child's output is kept in a 16 KB ring
(`IMIRROR_DEBUG=1` also writes it to `<label>.log`), and runwda's is read line
by line: "cannot initiate a IDE session … Timed out" means the XCTest "Enable UI
Automation" passcode sheet is up (`reason: needs_passcode`). Restarting the
runner then only raises the sheet again, so for up to 10 minutes the readiness
kill and the ladder's restarts pause, and runwda retries every 15 s so WDA comes
up soon after someone enters the passcode. A locked or untrusting phone is
named the same way (`locked`, `untrusted`). A phone is called down only after two
failed health probes in a row, and a probe that times out while other requests
(say an agent's slow `/source`) are already waiting on WDA counts as busy, not
failed. If WDA stays down, a ladder restarts that phone's own chain first, then
the shared tunnel; each restart gets its full grace from the moment it starts. If it still won't come up, the app stops the chain and
retries by itself after 2 min, then 5 min, then every 10 min; tapping the WDA
dot retries at once. Those retries never restart the shared tunnel while
another phone is working. A separate MJPEG no-frame watchdog covers the case where
WDA is healthy but no video frames arrive: it bounces the MJPEG forward (at
most once a minute) and never restarts a WDA that still answers `/status`. Before each bring-up the
app also sweeps any stray go-ios children left by a previously crashed
instance — most often a tunnel reparented to `launchd` that would otherwise
keep holding the device's RSD state and port 60105 and pin the dot on red. The
health dot shows **green**/**yellow**/**red** and the app auto-reconnects.

Why the relay: `go-ios forward` alone is incompatible with macOS CFNetwork
(URLSession gets `NSURLErrorNetworkConnectionLost` -1005, while plain socket
clients work). The loopback relay normalises the connection, keeping the USB
transport and loopback-only security. If the bundled go-ios is ever missing,
`scripts/wda-up.sh` + `scripts/wda_relay.py` are a manual fallback.

## Files other tools read

All live in `~/Library/Application Support/iMirror/` (with
`IMIRROR_DEVICES_FILE` set, next to that file instead). None of them ever holds
a secret.

**`devices.json`** — every phone and Simulator the app drives, rewritten
atomically on each change (format: `Sources/iMirrorCore/DeviceRegistry.swift`).
Top level: `schema` (1), `owner_pid`, `owner_uniqueid` (the app's kernel
`p_uniqueid`, never reused within a boot: a reader that finds a live `owner_pid`
with a different uniqueid knows the file is stale), `app_version`, `updated_at`,
`goios`, `devices`. Each device has `udid`, `alias`, `kind`, `wda_url`, `state`
(`starting|installing|ready|down|failed`), `detail`, and:

| key | meaning |
|---|---|
| `reason` | absent/null when ready; else one of `usb_reset`, `wda_wedged`, `needs_passcode`, `locked`, `tunnel_down`, `mac_asleep`, `gave_up`, `recovering`, `booting`, `untrusted` (the phone doesn't trust this Mac, or WDA's developer). Accept values you don't know. |
| `state_since` | UTC ISO-8601: when `state` or `reason` last changed |
| `chain_epoch` | +1 each time the phone's chain (runwda + forwards) starts |
| `last_error` | go-ios's last error line for this phone (`msg: error`, ≤200 chars), or absent |
| `next_retry_at` | UTC ISO-8601 while the ladder has given up: when it retries by itself |

**`events.jsonl`** — one JSON object per line, appended; at 5 MB it moves to
`events.jsonl.1` (one old file kept). Keys: `ts` (UTC ISO-8601 with ms),
`udid`, `alias`, `event`, and optionally `from`, `to`, `reason`, `detail`,
`expected` (bool). `event` is one of `state` (`from`/`to` are states),
`restart`, `give_up`, `auto_retry`, `usb_reset` (a reset the app is checking),
`usb_reset_ignored` (its own start/stop did it, or WDA was not up), `request`,
`wake`, `sleep`, `passcode`, `runner_upgrade` (the phone's WebDriverAgent
runner is older than the bundled one and is reinstalled; `from`/`to` are
versions; the new runner may raise the passcode sheet once), `keyboard` (see
below). The same lines go to the unified log, subsystem
`com.local.imirror`, category `events`, in the clear.

A `keyboard` event is about iMirror's Bluetooth keyboard. `detail` is one of
`paired`, `ambiguous` (more than one new Bluetooth central subscribed, so none
was trusted), `timeout` (the 120 s pairing window closed with no new phone),
`connected`, `disconnected`, `typed_test`, `typed_passcode`, `failed` or
`forgotten`. A typing line has `chars`: how many characters were typed, never
what they were. A `failed` line has a `reason`: `bad_request`,
`unknown_action`, `bad_text`, `stale`, `not_attached`, `not_paired`, `busy`,
`bluetooth_unavailable`, `setup_failed`, `not_connected`, `send_failed`, and
for "Type passcode now" `no_file`, `no_passcode` or `untypeable`.

**`expected-resets/<udid>.json`** — written by a client, not the app. Before
`devicectl device install|launch`, write `{"until": <now + 90 s, ISO-8601>,
"by": "devicectl install"}`. A USB reset of that phone before `until` is logged
with `"expected": true`. Recovery still runs as usual; the note only stops the
reset reading as a fault. A note more than 10 min ahead is ignored.

**`requests/restart-<udid>.json`** — written by a client to restart a phone's
chain: `{"udid", "requested_at": ISO-8601, "requested_by": "<short name>"}`.
Write a temp file and rename it in; other names in the folder are ignored. The
app deletes the file, then logs an event `request` whose `detail` is
`accepted` (the chain restarts now; `chain_epoch` goes up), `cooldown` (a
request for this phone was honoured in the last 60 s, so nothing happens),
`stale` (`requested_at` more than 2 min off) or `not_attached`. A request acts
like Settings → Restart: this phone's chain only, never the shared tunnel. It
never types a passcode. While the phone shows `needs_passcode`, don't send one:
a new runner raises the sheet again.

**`requests/keyboard-<udid>.json`** — written by a client to drive iMirror's
Bluetooth keyboard for one phone: `{"udid", "requested_at", "requested_by",
"action": "pair"|"forget"|"test", "text"}`. Write it like a restart request.
- `pair` opens a 120 s pairing window: iMirror advertises as "iMirror Keyboard",
  and the one phone that connects while it is open is tied to this UDID. The
  phone must be attached by USB.
- `test` types `text` into that phone only: 1–32 of `a-z`, `0-9` and space,
  with at least one letter and at most three digits, so it can never be a
  passcode attempt. `text` is refused on any other action.
- `forget` removes the tie.

Any other action, or any other key in the file, is refused (event `keyboard`,
`detail` `failed`). No request can type a passcode; only a click in Settings
does that (below). After each run iMirror
stops advertising and drops its Bluetooth services, so the phone gets its
on-screen keyboard back.

**`keyboard-pairs.json`** — written by the app, mode 0600: `{"<udid>":
{"central": "<CoreBluetooth central UUID>", "paired_at": ISO-8601}}`.

**Settings → iPhones → "Type passcode now"** shows on each paired phone. A
click reads that phone's passcode from the passcode file (the field under the
phone list; default `~/Documents/Github/Purpose/Purpose-iOS/Testing/.env.local`,
stored as `defaults` key `imirror.passcodeFile`). The file is dotenv style
(`KEY=VALUE`, optional `export`, quotes, `#` comments). The key is
`IMIRROR_PASSCODE_<UDID without dashes, upper case>`; failing that,
`ANTSIGNAL_TEST_DEVICE_PASSCODE`, but only when the file's
`ANTSIGNAL_DEVICE_UDID` is this phone. iMirror then presses Shift to wake the
phone, waits 600 ms, types the passcode to that phone's central only (Return
too, unless it is a 4- or 6-digit code), zeroes its copy and logs `keyboard`
`typed_passcode` with `chars`. Nothing but that click starts it; a test
(`PasscodeCallSiteTests`) fails if any other code calls it. A file under
`~/Documents` makes macOS ask once for access to Documents.

Click it only while the phone shows a passcode prompt (check the mirror or a
screenshot first). iMirror cannot tell what the phone shows: on an unlocked
phone the keys go to whatever has focus, and the Return after a non-numeric
code may send them. A click posted by another program (cliclick, an agent's
computer use) also counts as a click.

The first pair or type asks for Bluetooth access (System Settings › Privacy &
Security › Bluetooth). An ad hoc signed build may ask again after each rebuild;
see "Signing for development".

**`scripts/imirror-ctl`** reads and writes these files (system `python3`, no
dependencies). `device` is an alias, a UDID, or a unique UDID prefix/suffix of
4+ characters, as in the MCP server.

```bash
scripts/imirror-ctl status                 # every phone: state, reason, since, epoch
scripts/imirror-ctl status phone2 -n 20    # one phone, with its last 20 events
scripts/imirror-ctl restart phone2         # exit 0 accepted, 3 cooldown, 4 timeout
scripts/imirror-ctl events --device phone2 --since 1h
scripts/imirror-ctl keyboard pair phone2           # waits up to 130 s: paired, ambiguous, timeout
scripts/imirror-ctl keyboard test phone2 "hello 123"
scripts/imirror-ctl keyboard status phone2         # the tie and the last keyboard events
scripts/imirror-ctl keyboard forget phone2
```

`keyboard` exits 0 on `paired`, `typed_test` or `forgotten`, 1 on anything
else the app answered, and 4 when it got no answer. `test`, `forget` and
`status` also take a UDID from `keyboard-pairs.json` for a phone no longer on
USB.

### Sleep and wake

A sleeping Mac drops every phone's USB link. While Automation is on, iMirror
holds a `PreventSystemSleep` power assertion, but only while a client sent a
request through a phone's WDA port in the last 5 minutes, or a phone is
recovering (any `reason` but `gave_up` or `mac_asleep`, and the ladder has
not given up). Otherwise it lets the Mac sleep.
`pmset -g assertions` shows it as "iMirror: …".

**macOS honours that assertion on AC power only.** On battery, idle sleep and a
lid close still sleep the Mac. When the Mac goes to sleep, every phone shows
`reason: mac_asleep` and gets a `sleep` event. On wake, each phone logs `wake`
and its chain restarts at once (`chain_epoch` goes up), without waiting for a
probe to fail.

## Dependency security policy

Supply-chain risk is treated as a first-class constraint:

- **The app itself has zero third-party packages** — Apple system frameworks only.
- **The two control tools are vetted before use** (see [SECURITY-AUDIT.md](SECURITY-AUDIT.md)):
  pinned to exact tags + verified commits, scanned with `osv-scanner`, vulnerable
  transitive deps patched, and **built from source** (no prebuilt-binary trust).
- **No `curl | sh`, no unsigned binaries.** Anything executable is subject to
  macOS Gatekeeper / notarization.
- WebDriverAgent has no auth on the wire, so it is reached over **loopback only**:
  `scripts/build-go-ios.sh` patches go-ios's `forward` to bind 127.0.0.1 (upstream
  binds 0.0.0.0) and refuses to build if the patch did not apply. The go-ios host
  identity (`selfIdentity.plist`) is gitignored.
- WebDriverAgent's text typing names its XCTest event after the typed text and
  does not redact it, so a typed passcode would enter testmanagerd's event
  record. The build scripts patch it to a fixed name with redaction on.

## MCP server (drive the phone from Claude)

[`mcp-server/`](mcp-server/) turns the phone into an **agent-driven test rig**.
An MCP client (e.g. Claude) controls the device directly — screenshot, tap,
swipe, scroll (by direction or until an element is visible), type, hardware
buttons, find-and-tap / wait-for by text, orientation, accessibility source,
app lifecycle (launch / terminate / activate / state / install), deep links,
clipboard, and pass/fail assertions — a full set of `ios_*` tools.

The standout is **test-run recording**: the agent starts a run, names the
sections it tests, asserts checkpoints as pass/fail, and finishes with a
self-contained HTML report — cover page with verdict, pass/fail donut and stat
cards, a failures-first panel, a "what was tested" table of contents, every
step with embedded screenshots, and a looping timelapse of the whole run.
Ask Claude to "test the login flow and give me a report" and you get reviewable
evidence from a *real* device — the distinctive part. (Prefer a simulator? See
**iOS Simulator** below.)

**One-click install.** The app's **Settings (⚙) → MCP server** section registers
this server with your MCP client(s) in one click — it makes a Python venv
(**requires Python 3.10+**; e.g. `brew install python`), installs `mcp[cli]`, and
registers with both **Claude Code** (`claude mcp add`) and **Claude Desktop** (a
safe merge into `claude_desktop_config.json` that leaves your other servers
untouched). It shows installed status + version and flags when a re-register is
needed. Prefer the manual route? See [mcp-server/README.md](mcp-server/README.md).

It talks to the same loopback WDA the app brings up — open iMirror and wait for
the green dot before driving the phone. See
[mcp-server/README.md](mcp-server/README.md) for the tool table and report
walkthrough.

**Headless automation.** The MCP server can also bring WebDriverAgent up on its
own, without the Mac app: set `IMIRROR_AUTOWDA=1` and it runs the same go-ios
tunnel / runwda / forward chain and talks to WDA directly. Useful for driving
the phone from an agent without launching the GUI. A bring-up that fails stops
the children it started, and only those: it never sweeps other go-ios processes,
so the app's other phones are left alone.

**iOS Simulators (optional).** No phone handy, or testing a simulator build?
Enable one or more simulators and iMirror boots each and brings WebDriverAgent up
on it, on its own loopback ports (the first `:8201`, then `:8202`, … — clear of
the phones' `:8100`, `:8110`, …), and lists it to the `imirror` MCP server under
an alias made from its name (`iPhone 17 Pro` → `iphone-17-pro`; `simN` when the
name gives nothing usable). Port and alias stick to the sim's UDID across
relaunches. Agents drive it with the same `ios_*` tools (`device="iphone-17-pro"`),
plus simulator-only `sim_push` / `sim_privacy` / `sim_status_bar`;
`device="sim"` still works while only one simulator is on. You view the sims in
Apple's Simulator app. **Requires Xcode**; each sim builds WebDriverAgent once
(2–3 min, cached afterward in `~/Library/Application Support/iMirror/sim/<UDID>/`).

The enabled set is one list in the app's defaults, and it is the only switch —
the app re-reads it on launch (so enabled sims come back after a relaunch) and
every 2 s while running. Three ways to edit it, none needing the GUI except the
first:

- **Settings (⚙) → iOS Simulator**: pick a sim, **Enable**; each enabled sim gets
  a row with its alias, port, state and a **Disable** button.
- **A shell** — `scripts/imirror-sim.sh` (takes a UDID, the sim's exact name, or
  its alias):

  ```bash
  scripts/imirror-sim.sh list                          # every sim: on/off, alias, port, state
  scripts/imirror-sim.sh enable "iPhone 17 Pro" --wait # returns once WDA is ready
  scripts/imirror-sim.sh enable <UDID> <UDID>          # several at once
  scripts/imirror-sim.sh wait iphone-17-pro 300
  scripts/imirror-sim.sh disable iphone-17-pro         # or: disable all
  ```

  or plain `defaults` (UDIDs only; this replaces the whole list):

  ```bash
  defaults write com.local.imirror imirror.enabledSimulators -array <UDID> <UDID>
  defaults read  com.local.imirror imirror.enabledSimulators
  defaults delete com.local.imirror imirror.enabledSimulators   # all off
  ```

- **The MCP server**: `sim_list`, `sim_enable(simulator, wait_seconds)` and
  `sim_disable(simulator)` edit the same list.

Disabling stops that sim's WebDriverAgent; the sim itself stays booted. Each
sim's runner is supervised: one that exits is relaunched (with backoff), and one
that stops answering `/status` for 90 s is killed and relaunched. The
`imirror-sim` MCP registration (Settings → **Install**) is the older pinned
setup: it only ever drives `:8201`, the first sim enabled.

## Packaging / distribution

```bash
swift scripts/make_icon.swift   # regenerate Resources/AppIcon.icns (one-off)
./scripts/package.sh            # build a DMG (build/iMirror.dmg)
```

`package.sh` builds the release `.app` (bundling go-ios + icon) and makes a DMG.
With a **Developer ID Application** certificate it signs with hardened runtime +
the camera entitlement (and signs the nested go-ios), ready for notarization:

```bash
# one-time:
xcrun notarytool store-credentials imirror --apple-id <id> --team-id <TEAMID> --password <app-pw>
# then:
NOTARY_PROFILE=imirror ./scripts/package.sh   # signs, notarizes, staples
```

Without that cert it ad-hoc signs (runs locally; other Macs show a Gatekeeper
warning). The Mac App Store is not a target: the app spawns go-ios child
processes and drives WebDriverAgent, which the App Sandbox doesn't allow;
distribute the notarized DMG directly.

## Status / limitations

- **Working:** video mirror, screenshot, and control (tap, drag, two-finger
  trackpad scroll with flick detection, type incl. backspace/return/tab, Home).
  The phone keeps its own audio throughout, since mirroring no longer opens a
  capture device.
- **Not currently available:** recording to mp4. It depended on the old
  capture pipeline and was removed with it; it could be rebuilt from MJPEG
  frames later.
- **macOS only** by design. Cross-platform would mean the libusb /
  `quicktime_video_hack` path — a different architecture.
- **Latency:** video is an MJPEG frame stream at roughly 10–20 fps, not a
  frame-tight capture — the mirror trades smoothness for letting the phone keep
  its own audio. Control adds a WDA round-trip on top (tens–hundreds of ms per
  action). Scrolling is not frame-tight and has no inertial coast (a WDA
  limitation, not a tuning knob).
- **Not reachable** (XCUITest limitation): App Switcher, Control Center, Siri.
- **Several phones, one window.** Every iPhone attached by USB is driven at once
  (up to 8, one port slot each); the window mirrors one at a time. A phone paired
  only over Wi-Fi is not picked up. Enabled **iOS Simulators** (up to 8) run
  their own WDA (`:8201`, `:8202`, …) alongside them, each listed to the MCP
  server by its own alias. All
  phones share one go-ios tunnel, so a tunnel restart drops every phone for
  about 20 s.
- **Maintenance reality:** control depends on go-ios + WebDriverAgent tracking
  Apple's private wire protocols, so a new iOS major version can break the chain
  until those projects catch up. Pinned versions in
  [SECURITY-AUDIT.md](SECURITY-AUDIT.md) are what's actually tested.
- **Landscape** adapts via WDA `window/size` (refreshed each poll, and at once
  when the video changes shape; the video follows the rotation through WDA's
  `mjpegFixOrientation`) but hasn't been physically rotation-tested.
- Relaunching the app in quick succession can still briefly wedge the device's
  `testmanagerd`. Recovery now escalates in stages: a readiness-deadline
  auto-restart of the runner, then a chain restart, then a tunnel restart, then
  (if the chain still won't come up) a pause that retries by itself with a
  growing backoff (2 min, 5 min, then every 10 min). A hard crash (rather than a clean quit) can orphan a go-ios
  child; the next launch sweeps it automatically.

## Credits

iMirror is independent software and contains no scrcpy source; it was inspired by
[scrcpy](https://github.com/Genymobile/scrcpy)'s "mirror + control over USB" idea
and applies the equivalent approach to iOS. Control is built on two open-source
tools, fetched into `tools/` at build time (see [SECURITY-AUDIT.md](SECURITY-AUDIT.md)):

- [go-ios](https://github.com/danielpaulus/go-ios) — MIT
- [WebDriverAgent](https://github.com/appium/WebDriverAgent) — Apache-2.0

Distributions that bundle the `go-ios` binary should include its MIT notice.

## Author

Theophilus RexDanquah — [rexdanquah.dev](https://rexdanquah.dev)

## License

MIT — see [LICENSE](LICENSE).
