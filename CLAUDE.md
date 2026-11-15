# phone_screen_mirror

iMirror — mirror and control a real iPhone from macOS. The repo has two parts:

- **macOS app** (Swift) — brings up WebDriverAgent over a self-managed transport
  and mirrors the device screen.
- **MCP server** (`mcp-server/`) — a Python MCP server that drives the device
  (tap/swipe/type/screenshot/…) and records test runs into HTML reports.

## Gates — always run the tests locally

`.github/workflows/ci.yml` runs only the Swift build and tests, only for `main`,
and Actions may be off for the org, so treat the local runs as the gate. Before
committing or opening a PR, run both and make sure they pass:

```bash
mcp-server/.venv/bin/python -m pytest mcp-server   # anything under mcp-server/
swift build && swift test                          # Swift, and scripts/*.sh
```

`swift test` also runs `scripts/tests/test-app-scripts.sh` (the `run.sh` /
`package.sh` running-bundle guard and the `diagnose.sh` audits, every Mac-touching
tool stubbed), so a change to a script is covered there too.

(`mcp-server` runs every suite: `test_imirror_mcp.py`, `test_multi_device.py`,
`test_sim_control.py`, `test_wda_bringup.py` and the device-lease ones,
`test_devicelease*.py` and `test_lease_hook.py`; the live ones skip themselves.
`conftest.py` points every test at its own lease directory, never the live one.)

First-time setup (creates the venv the command above expects):

```bash
python3 -m venv mcp-server/.venv
mcp-server/.venv/bin/pip install "mcp[cli]" pytest
```

The unit tests stub the HTTP layer, so they need **no device and no
WebDriverAgent**. Keep them that way — new tests must not require a phone.

When you change `imirror_mcp.py`, also run a quick compile check:

```bash
mcp-server/.venv/bin/python -m py_compile mcp-server/imirror_mcp.py
```

### Live integration tests (optional, needs a device)

`mcp-server/test_integration.py` exercises the real WebDriverAgent wire and is
**skipped by default**. Run it only with the iMirror app running and its health
dot green:

```bash
IMIRROR_LIVE=1 mcp-server/.venv/bin/python -m pytest mcp-server/test_integration.py -v
```

With two or more phones up, `test_integration_devices.py` checks them together
(leave `IMIRROR_WDA` unset so the server reads the app's device file):

```bash
IMIRROR_LIVE_DEVICES=phone1,phone2 mcp-server/.venv/bin/python -m pytest \
    mcp-server/test_integration_devices.py -v
```

## Deploy is not dev

Sessions do not run this checkout. The app's **Settings → MCP server →
Install/Update** freezes a copy of `mcp-server/` (the copy bundled into the app
when it was built) into `~/Library/Application Support/iMirror/mcp/<version>-<hash8>/`,
imports it with the venv's Python, and only then points `mcp/current` at it.
Claude Code and Claude Desktop are registered at
`~/Library/Application Support/iMirror/mcp/current/imirror_mcp.py`, and any other
path reads as "update available". So once a client is re-registered there, editing,
pulling or checking out a git tree changes nothing a session runs until a rebuilt
app's **Update**. (A registration made before this, or by hand, still runs
whatever tree it names.) Because the server ships `devicelease.py`, the install
also writes the `~/Library/Application Support/iMirror/bin/imirror-lease` launcher.

`scripts/run.sh` and `scripts/package.sh` refuse to replace a `build/iMirror.app`
that is running; `--restart` quits exactly that pid (every phone drops for about
30 s), rebuilds, relaunches and waits for it to own `devices.json`. Build the app
people actually run only at its stable path, never in a worktree that will be
deleted: `devices.json`'s `goios` points into the bundle.

## Conventions

- Keep the MCP server dependency-light: standard library + `mcp[cli]`. The
  timelapse feature shells out to `ffmpeg` if present and degrades gracefully if
  not — don't add it as a hard dependency.
- The server talks to WDA on **loopback only** (WDA has no auth on the wire).
  Never relax the loopback guard in `imirror_mcp.py`.
