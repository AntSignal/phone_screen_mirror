# iMirror MCP server

An MCP (Model Context Protocol) server that lets an MCP client — e.g. Claude —
**drive the iPhone directly**: take device screenshots, tap, swipe, scroll (by
direction or until an element is visible), type, press hardware buttons,
find-and-tap by visible text, read the accessibility tree, and check status.
Useful for testing flows on a real device without clicking the Mac UI by hand.

It is a thin client over WebDriverAgent. The **iMirror app** must be running and
its toolbar health dot **green** — the app brings WDA up at `127.0.0.1:8100` via
its self-managed transport (userspace tunnel + runwda + forward + relay).

## Tools

| Tool | What it does |
|------|--------------|
| `ios_status` | WDA ready? + iOS version / device name, which server answered (`server_version`, `script_path`) and which endpoint (`target`, `wda_endpoint`, `selected_udid`); with iMirror's device file, also the app's view (`app_state`, `reason`, `state_since`, `chain_epoch`, `next_retry_at`, `last_error`) and the phone's last 5 events |
| `ios_devices` | every device this server can drive (alias, UDID, port, ready?, the app's view as above, how its WDA sessions were got) and which one is the default |
| `ios_reserve_device(device, agent, wait_s, hold_s)` | reserve a device for yourself, waiting in line (≤ 85 s per call) if another agent has it: `held` or `queued` (see [Sharing a device between agents](#sharing-a-device-between-agents)) |
| `ios_release_device(device, agent)` | release it; the next agent in line gets it at once |
| `ios_device_leases(device)` | who holds each device, since when, how long idle, and who waits |
| `ios_recover` | ask iMirror to restart a phone's WDA chain, then wait ≤30 s: `accepted`, `cooldown` (one ran in the last minute) or `timeout` |
| `ios_window_size` | logical screen size (points) for the current orientation |
| `ios_screenshot` | full-res device screenshot (PNG, or JPEG on a device via `IMIRROR_SCREENSHOT_QUALITY`) — no macOS Screen Recording perm needed |
| `ios_tap(x, y)` | tap at a point (points, top-left origin) |
| `ios_swipe(from_x, from_y, to_x, to_y, duration_ms, settle_ms)` | swipe / drag / scroll; `settle_ms` waits after so a following screenshot/source isn't mid-scroll |
| `ios_scroll(direction, distance_pct, x_pct, y_pct, duration_ms, settle_ms)` | scroll by content direction (`up`/`down`/`left`/`right`) a % of the screen; returns the from/to points + distance |
| `ios_scroll_to(text, direction, max_swipes, distance_pct, settle_ms)` | scroll (capped at 20 swipes) until an element with that label/name/value is on screen |
| `ios_type(text)` | type into the focused field (`\n`=return, `\b`=backspace) |
| `ios_press_button(name)` | `home` / `volumeUp` / `volumeDown` |
| `ios_alert(action, button_label)` | `get` a system alert's text and buttons (`present: false` when none), or `accept` / `dismiss` it, optionally by exact button label. Alert text is never recorded in run reports |
| `ios_find_and_tap(text)` | find an element by visible label/name and tap it |
| `ios_wait_for(text, timeout_s)` | poll until an element with that label/name appears |
| `ios_orientation(set_to)` | get orientation, or set `PORTRAIT` / `LANDSCAPE` |
| `ios_source` | accessibility hierarchy of the current screen: a compact text tree (at most 400 elements, 20,000 characters, 240 per field) or raw XML |
| `ios_start_run(label)` | begin recording a test run (opt-in) |
| `ios_run_section(title)` | start a named section — groups following steps under it in the report + TOC |
| `ios_run_note(text, status)` | add a checkpoint — `info` / `pass` / `fail` |
| `ios_finish_run(video)` | write the HTML report (+ `gif`/`mp4` timelapse) and stop recording |
| `sim_push(bundle_id, payload_json)` | *(simulator only)* deliver a push notification from an APNs payload |
| `sim_privacy(action, service, bundle_id)` | *(simulator only)* grant/revoke/reset a permission without the consent dialog |
| `sim_status_bar(time, clear)` | *(simulator only)* freeze the status bar (full bars, 100%, fixed time) for clean screenshots |
| `sim_list()` | every Simulator on the Mac: enabled in iMirror?, its alias, WDA port and state |
| `sim_enable(simulator, wait_seconds)` | have the iMirror app run WDA on a Simulator (UDID, exact name or alias); it then becomes a device by its alias. `wait_seconds` ≤ 100; a first WDA build takes 2–3 min |
| `sim_disable(simulator)` | stop WDA on a Simulator (or `"all"`); the sim stays booted |

Every device tool also takes an optional **`device`** argument — see
[Several devices](#several-devices). The run-report tools, `ios_devices` and
`sim_list` / `sim_enable` / `sim_disable` don't. Every tool that changes or
inspects a device also takes an optional **`agent`** name (see below).

## Sharing a device between agents

Several agents (sessions, their subagents, `Testing/run.sh`) share the same
phones and Simulators. To use a device:

```
ios_reserve_device(device="phone1", agent="<your name>")   # repeat while "queued"
... drive it, passing agent="<your name>" on every call ...
ios_release_device(device="phone1", agent="<your name>")
```

- **`held`** returns `lease_id` and `expires_at`. The hold lasts `hold_s`
  (default 900, 60–3600) even while you are idle, but ends anyway after 20
  minutes unused. Calling again while you hold it renews it.
- **`queued`** returns your `position`, the `holder` (`agent`, `session`,
  `since`, `idle_s`) and a `ticket`. One call waits at most `wait_s` (default
  60, at most 85: Claude Code moves a tool call to the background at 120 s).
  Call again with the same `agent` within 30 s to keep your place. When the
  holder releases, the first in line gets the device at once.
- **Without a reservation**, your first tap, type or launch on a free device
  takes it for you; it frees after 5 idle minutes or when your session ends.
- **`DEVICE_BUSY`** means another agent holds the device and nothing was sent.
  Wait in line with `ios_reserve_device` or use another device; don't retry the
  call in a loop. `ios_screenshot`, `ios_status` and `ios_device_leases` work on
  any device.
- **`agent`**: subagents of one session share one MCP server, so pass your own
  name on every call. Two names are two holders. `ios_release_device` frees
  only that name's hold. `"phone1,phone2"` reserves both or neither, and a
  wait that would deadlock fails with `DEVICE_DEADLOCK`.
- `ios_devices` and `ios_status` show each device's `lease`. `ios_devices`
  lists `servers_ignoring_leases`: MCP servers on this Mac (an older install)
  that drive devices without asking.
- Scripts use the `imirror-lease` CLI (below), which shares the same state.

## Several devices

The iMirror app runs WebDriverAgent on every iPhone attached by USB, each on its
own loopback port, and lists them (plus every enabled Simulator, each by an
alias made from its name) in `~/Library/Application Support/iMirror/devices.json`.
This server reads that file (re-reading it when it changes), so one server
drives them all:

```
ios_devices                                  -> phone1 (:8100), phone2 (:8110),
                                                iphone-17-pro (:8201), iphone-16e (:8202)
ios_find_and_tap text="Settings" device="phone2"
ios_screenshot device="iphone-16e"           # a simulator, by its alias
sim_enable simulator="iPad Air 13-inch (M3)" wait_seconds=100
ios_screenshot device="00008140"             # a UDID, or a unique UDID prefix/suffix (4+ chars)
ios_run_sequence steps=[…] device="phone1"   # one device for the whole sequence
```

- **Omitting `device`** is fine with one phone attached (enabled Simulators
  don't count; the simctl `sim_*` tools default to the Simulator when only one
  is on). With several phones it fails with the list of devices rather than
  guess — set `IMIRROR_DEFAULT_DEVICE=<alias or UDID>` in the server's
  environment to give omitted calls a default instead.
- **`device="sim"`** is the single-simulator name from before simulators had
  aliases of their own: it still means the Simulator while exactly one is on,
  and is refused as ambiguous with several.
- **Parallel across devices, in order per device.** Each call runs on its own
  worker thread and holds only its device's lock: a 10 s `ios_wait_for` on
  phone1 doesn't delay phone2, while two calls to phone1 still run one after
  another (WDA has one XCUITest queue per phone). Claude Code only sends tool
  calls from one message concurrently when the tools are marked read-only, so
  screenshots, source reads, waits and asserts on two phones overlap; taps and
  other changes from one agent run one after another (parallel changes need
  separate agents).
- **One recorded run spans every device.** Each step (and screenshot file) is
  tagged with its device's alias, and the report shows a chip per step.
- **Modes.** Set `IMIRROR_WDA` and the server is pinned to that one target,
  exactly as before (the `imirror-sim` registration does this). Without it the
  server uses the device file, and falls back to `127.0.0.1:8100` when there is
  no live file (an older iMirror app, or the app isn't running). `ios_devices`
  reports which mode it is in. `IMIRROR_DEVICES_FILE` overrides the file's path.
- **A pinned default never falls back.** With `IMIRROR_DEFAULT_DEVICE` set
  (run.sh sets it per agent) and no live file, a call that names no device
  fails with `DEVICE_FILE_INVALID` instead of driving `:8100`, which may be
  another phone. A pin of `default`, or of `IMIRROR_UDID`, still uses it.
- The file is only trusted while the app that wrote it is running, and only
  loopback entries are used — WDA has no auth on the wire. "Running" means
  the `owner_pid` is a live process that is not a zombie and, when the file
  has `owner_uniqueid`, is the very process that wrote it (macOS's kernel
  uniqueid is never reused within a boot, unlike a pid).

## Sharing a phone: WDA sessions

WebDriverAgent keeps **one session per phone**, and creating a session ends
the one that was there. Several clients share each phone (the iMirror app's
mirror, every agent's MCP server), so this server avoids creating one:

- **It joins the session already on the phone.** With no session of its own
  it reads `GET /status` and adopts the active one, re-applying its two
  settings (no idle wait; `screenshotQuality`); it creates one only when the
  phone has none. Screenshots, `ios_window_size` and `ios_source` use WDA's
  sessionless routes and never create one.
- **A miss is not a dead session.** WDA answers 404 for four things. Only
  `invalid session id` replaces the session: the reply names the session now
  active, which is adopted (another client made it), or none (WDA restarted:
  a new one is created). `no such element` is a clean miss; a click that hits
  `stale element reference` re-finds the element once; any other 4xx raises
  `WDA_HTTP_<code>`.
- **`SESSION_CONTESTED`** means another session replaced this server's twice
  within 60 s (a WDA restart does not count), so something keeps creating
  sessions on that phone: another agent's server, an
  old iMirror server, or iMirror itself while a system alert is up. The action
  was not run. Take a screenshot; tap a system alert by coordinates if one is
  showing; otherwise check `ios_devices` rather than retrying in a loop. Its
  per-device `session` counts (`created`, `adopted`, `lost`) show the history.

Calls are serialised per phone within one server process; across servers,
device leases order them (next section).

A server exits as soon as its client is gone: when its stdin closes, or when
its parent process changes (it was orphaned). It does not wait for a tool
call still blocked on WDA.

## Device leases: `imirror-lease`

`devicelease.py` records which agent may drive each phone (`device:<UDID>`)
or Simulator (`sim:<UDID>`), so agents can wait in line for a device instead of
trampling each other's WDA session. A hold belongs to a process and covers its
children: `--anchor-pid`, else the nearest `claude` process, else the terminal
tab's shell. It ends on release, after it sits idle, when its time is up, or
when that process exits. State lives in
`~/Library/Application Support/iMirror/leases/`.

The app's MCP Install writes the CLI launcher
`~/Library/Application Support/iMirror/bin/imirror-lease`:

```bash
imirror-lease whoami                       # which process my holds belong to
imirror-lease status                       # every device: holder, queue
imirror-lease acquire device:<UDID> --wait-s 600 --anchor-pid $$
imirror-lease release device:<UDID> --anchor-pid $$
```

Exit codes: 0 ok, 2 usage, 3 busy, 4 deadlock, 5 not held or lost, 6 the lease
system itself failed. Leases are cooperative: they order only the callers that
ask, and this server asks before every device call.

### How the server's tools use leases

Each device tool has an access class:

| Class | Tools | On a device someone else holds |
|-------|-------|--------------------------------|
| observe | `ios_status`, `ios_devices`, `ios_screenshot`, `ios_window_size`, `ios_app_state`, `ios_start_run` | runs; never checked |
| inspect | `ios_source`, `ios_wait_for`, `ios_await_idle`, `ios_assert_*`, `ios_clipboard_get`, `ios_orientation` and `ios_alert` reads | `DEVICE_BUSY` |
| drive | everything else, `ios_recover` included | `DEVICE_BUSY` |

- **A drive call on a free device takes it** for the caller: an automatic
  hold that ends after 5 idle minutes, or when the caller's Claude session
  exits. An inspect call on a free device runs without taking it.
- **`DEVICE_BUSY` fails at once and sends nothing.** It names the holder and
  says how to wait in line (`ios_reserve_device`). Don't retry the call in a loop.
- **`agent`**: every drive and inspect tool takes an optional `agent` name.
  Subagents of one session share one MCP server, so the name is the only
  thing that tells them apart: two names in one session are two holders, and
  once a named agent holds a device, an unnamed call from that session is
  refused too.
- **A hold can end mid-call** (it lapsed, the user freed the device, or a run
  you started took it). The server re-checks before every WDA request,
  devicectl/simctl run and `ios_run_sequence` step, and stops with
  `DEVICE_RESERVATION_LOST`; the rest of the call is not sent. The next call
  that finds its hold gone gets `DEVICE_RESERVATION_LOST` once: take a
  screenshot before acting again.
- **Waiting is use.** While a call is in flight (riding out a WDA restart,
  `ios_recover`, or an install waiting for `devicectl.lock`) a heartbeat
  renews the hold every few seconds, so the wait never counts as idle time.
  Order is lease, then the per-device call lock, then `devicectl.lock`, so
  they cannot deadlock.
- Keys are UDIDs, never aliases. A server pinned by `IMIRROR_WDA` finds its
  UDID through `IMIRROR_UDID` or the device file's `wda_url`; with neither it
  locks `wda:127.0.0.1:<port>`, which excludes only other pinned servers.

## When a phone's WDA restarts

The iMirror app restarts a phone's chain by itself after a USB reset or a
wedged WDA, and says so in `devices.json` (see "Files other tools read" in the
top-level README). A call that cannot reach WDA reads that file, never
`/status`, so dozens of servers don't hammer a booting WDA:

- **Restarting** (`starting`, `installing`, or a `reason` such as `usb_reset`,
  `wda_wedged`, `tunnel_down`): the call waits up to 30 s for `ready`. Then a
  read (screenshot, source, status, waits, asserts) is retried once. A tap,
  type, swipe or launch is **never** repeated, because it may already have
  reached the phone: it fails with `RECOVERING` and `retry_after_s=0`. Still
  restarting after 30 s: `RECOVERING` with `retry_after_s` and `reason`.
- **`NEEDS_PASSCODE`** (`reason` `needs_passcode` or `locked`): fails at once.
  iMirror types the passcode if auto-passcode is set up for that phone;
  otherwise a person must.
- **`DEVICE_GAVE_UP`**: the app has stopped retrying; `next_retry_at` says
  when it tries again by itself. `ios_recover` asks for a retry now.
- The app checks WDA every 3 s, so a call can fail before the file says
  anything. The call gives it 5 s to notice. A phone the app still calls
  `ready` after that gets the plain `unreachable`/`wedged` error, as before.

**A lost reply to a change.** A tap, type, swipe, alert accept or launch whose
reply never came back fails with `kind=outcome_unknown`: WDA may already have
done it, so it is never sent again. Look at the screen before repeating it. It
is re-sent only when it failed before its first byte left (a refused connection,
or a send that failed at once), and a kept-alive socket WDA closed while idle is
replaced before a request goes out on it. Reads (and the POSTs that only find
elements or read state) are still retried. During a restart, such a call waits
like any other change and keeps `kind=outcome_unknown` with `code=RECOVERING`.

The extra values ride in the error's tail, e.g.
`[kind=unreachable code=RECOVERING reason=usb_reset retry_after_s=15]`.

`ios_recover(device)` writes a restart request for the app. The app takes one
per phone per minute (`cooldown` otherwise), so several agents asking at once
restart it once. It never types a passcode.

**Installs reset the phone's USB link.** `ios_install_app` on a phone takes
`devicectl.lock` next to `devices.json`, the same flock `antsignalctl device
install|launch` takes, so two sessions never install at once and reset each
other. It waits up to 15 minutes, then goes ahead. While it holds the lock it
writes `expected-resets/<udid>.json` (`{"until": now+90 s, "by": "go-ios
install"}`) before and after go-ios runs, so iMirror logs the reset that follows
as expected. A Simulator install takes neither.

## Setup

The app's one-click install (Settings → MCP server) does all of this for you, and
registers a frozen copy at `~/Library/Application Support/iMirror/mcp/current/`
rather than this tree (see the main README). The steps below are the manual,
run-from-the-checkout route, which is what you want while developing the server.

```bash
python3 -m venv mcp-server/.venv
mcp-server/.venv/bin/pip install -r mcp-server/requirements.txt pytest
```

(`requirements.txt` pins `mcp[cli]`; `pytest` is for the unit suite below.)

Register with Claude Code (run from the repo root):

```bash
claude mcp add imirror --scope local -- \
  "$PWD/mcp-server/.venv/bin/python" "$PWD/mcp-server/imirror_mcp.py"
```

Or add to a client config (e.g. Claude Desktop `claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "imirror": {
      "command": "/abs/path/phone_screen_mirror/mcp-server/.venv/bin/python",
      "args": ["/abs/path/phone_screen_mirror/mcp-server/imirror_mcp.py"]
    }
  }
}
```

Restart the client so it picks up the new server. Then start the iMirror app,
wait for the green dot, and the tools are live.

Override the target (default `http://127.0.0.1:8100`) with `IMIRROR_WDA` — it must
stay on loopback.

Screenshots are PNG by default. On a physical device, set `IMIRROR_SCREENSHOT_QUALITY`
to `1` (medium JPEG) or `2` (low JPEG) for smaller, faster-to-encode frames; `0` keeps
lossless PNG. The default is target-aware — `1` on a device, `0` on the simulator,
where WDA ignores the JPEG path and returns PNG regardless.

`IMIRROR_SNAPSHOT_MAX_DEPTH` (1–200) sets WDA's `snapshotMaxDepth` on each session
this server makes or joins. A lower depth makes a heavy `/source` cheaper, and a
heavy one can kill the runner and reset the phone's USB link. It is unset by
default (WDA's own 50), because WDA applies it to every element lookup too: an
element nested deeper is not found at all. Measure on the phone before setting it.

## Running against an iOS Simulator

The same tools drive a booted Simulator — a simulator shares the Mac's loopback,
so there's no tunnel/relay and (unlike a device) no signing or paid team. Bring
WDA up on the sim, then point the server at it with `IMIRROR_TARGET=simulator`:

```bash
# 1) build + launch WDA on the booted sim (stays in the foreground; Ctrl-C stops)
PORT=8100 ./scripts/sim-wda-up.sh              # or: ./scripts/sim-wda-up.sh "iPhone 16 Pro"

# 2) run the MCP server against it
IMIRROR_TARGET=simulator IMIRROR_WDA=http://127.0.0.1:8100 \
  mcp-server/.venv/bin/python mcp-server/imirror_mcp.py
```

`IMIRROR_TARGET` (`device` default, or `simulator`) switches the few non-WDA
paths: `ios_install_app` uses `xcrun simctl install booted` instead of go-ios,
the volume buttons are rejected up front (physical-device-only), the `sim_*`
tools become available, and "can't reach WDA" hints drop the health-dot wording.
The interaction tools are identical either way.

`sim-wda-up.sh` rebrands the runner to iMirror (app icon + "iMirror" display name
+ the `com.local.imirror.WebDriverAgentRunner` bundle id), matching the on-device
build — so the sim's App Library / Spotlight shows iMirror, not a stock
`WebDriverAgentRunner-Runner`. It needs the vendored WebDriverAgent under `tools/`
(see `scripts/build-wda.sh`); in a worktree, point it at your main checkout with
`WDA_PROJECT=/path/to/WebDriverAgent.xcodeproj`.

That iMirror icon is the XCUITest **runner** — don't tap it to launch it. A test
runner only works when `xcodebuild` starts it (the script does this); launched
standalone it crashes at load with a `Library not loaded: …lib_TestingInterop.dylib`
dyld error. If you see that dialog, click **Ignore** and start WDA via the script.

## Test reports (opt-in)

The server can record a **test run** and emit a self-contained HTML report — a
cover with the overall verdict, a summary with a pass/fail donut, stat cards and
an action breakdown (all inline SVG/CSS — no JS libraries), a failures-first
panel, a "what was tested" table of contents, and the full timeline of every
action with embedded screenshots and pass/fail checkpoints. Recording is off
until you call `ios_start_run`, so normal device control is unaffected.

1. `ios_start_run("login flow")` — begin recording.
2. `ios_run_section("Sign in")` — name each area you test. Steps recorded after it
   are grouped under that section in the report + TOC, with a per-section pass/fail
   rollup. (Optional — steps before the first section land in an implicit one.)
3. Drive the flow as usual. Every tap / swipe / scroll / type / find / wait is
   logged, and each `ios_screenshot` is saved to the run directory.
4. `ios_run_note("home screen shown", status="pass")` — mark checkpoints
   (`info` / `pass` / `fail`; any `fail` flips the report verdict to FAIL).
5. `ios_finish_run()` — writes `report.html` and returns its path. By default it
   also stitches the run's screenshots into a looping `timelapse.gif` shown atop
   the report (pass `video="mp4"` or `video="none"`). The timelapse needs `ffmpeg`
   on `PATH` and ≥2 screenshots; otherwise the report is still written with a note
   that it was skipped. Screenshots are embedded in the HTML; the timelapse is
   saved beside it, so a video-bearing report is the whole run folder.

Runs are stored under `~/.imirror/runs/<timestamp>-<label>/` (override the base
with the `IMIRROR_RUNS_DIR` env var). The bundled **`ios-test-report` skill**
(`.claude/skills/`) walks Claude through this end to end — ask it to "test a flow
and give me a report".

## Tests

No device or WebDriverAgent is needed. Most tests stub the HTTP layer;
`test_wda_wire.py` runs the real wire layer against
`testsupport/fake_wda_server.py`, a keep-alive loopback server that answers
with the vendored WDA's real reply bodies and can stall, drop a connection,
or hand the phone's session to another client:

```bash
mcp-server/.venv/bin/pip install pytest
mcp-server/.venv/bin/python -m pytest mcp-server
```

`conftest.py` gives every test its own lease directory, so no test touches the
leases live sessions use. `test_devicelease.py` covers the pure rules;
`test_devicelease_store.py` runs the CLI and the store against real child
processes, also under the Mac's own `/usr/bin/python3` (3.9).
`test_lease_hook.py` drives the tools against another agent's hold (a real
child process) and checks nothing reaches WDA, including mid-call losses
over real HTTP; `test_lease_tools.py` covers reserving, queueing and releasing.

## Security

WebDriverAgent has **no authentication** on the wire, so the server refuses any
non-loopback target. These tools fully control the phone — use only on a device
you own, with consent.
