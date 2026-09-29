"""Live tests for driving several devices at once through one server.

SKIPPED unless IMIRROR_LIVE_DEVICES names two or more devices, e.g.

    IMIRROR_LIVE_DEVICES=phone1,phone2 mcp-server/.venv/bin/python -m pytest \\
        mcp-server/test_integration_devices.py -v

The server reads the iMirror app's device file (or IMIRROR_DEVICES_FILE), so
IMIRROR_WDA must NOT be set. Every test here is read-only: status, screenshots,
and ios_wait_for on text that is never on screen (the timing probe).
"""
from __future__ import annotations

import json
import os
import time

import anyio
import pytest

NAMES = [n.strip() for n in os.environ.get("IMIRROR_LIVE_DEVICES", "").split(",") if n.strip()]

pytestmark = pytest.mark.skipif(
    len(NAMES) < 2 or "IMIRROR_WDA" in os.environ,
    reason="set IMIRROR_LIVE_DEVICES=<alias>,<alias> (and leave IMIRROR_WDA unset)",
)

ABSENT = "__imirror_never_on_screen__"
WAIT_S = 3.0


@pytest.fixture(scope="module")
def m():
    import imirror_mcp
    return imirror_mcp


def test_every_named_device_is_listed_and_ready(m):
    out = json.loads(m.ios_devices())
    assert out["mode"] == "list", out
    rows = {d["alias"]: d for d in out["devices"]}
    for name in NAMES:
        assert name in rows, f"{name} not in {sorted(rows)}"
        assert rows[name]["wda_ready"], rows[name]


def test_each_device_answers_as_itself(m):
    """Screenshots taken by alias come back from different screens."""
    shots = {name: m.ios_screenshot(device=name).data for name in NAMES}
    assert len(set(shots.values())) == len(NAMES)
    for name in NAMES:
        st = json.loads(m.ios_status(device=name))
        assert st["ready"] is True and st["alias"] == name


def test_one_run_records_every_device(m, tmp_path, monkeypatch):
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path))
    m.ios_start_run("live-devices")
    for name in NAMES:
        m.ios_screenshot(device=name)
    report = m.ios_finish_run(video="none")
    html = open(report, encoding="utf-8").read()
    for name in NAMES:
        assert f'<span class="dev">{name}</span>' in html


def _wait_absent(m, calls: list[str]) -> float:
    """Run ios_wait_for(ABSENT) on each named device at once, through FastMCP
    exactly as a client would; return the wall time."""
    async def run():
        async def one(name):
            try:
                await m.mcp.call_tool("ios_wait_for",
                                      {"text": ABSENT, "timeout_s": WAIT_S, "device": name})
            except Exception:
                pass                              # the expected not-found timeout
        async with anyio.create_task_group() as tg:
            for name in calls:
                tg.start_soon(one, name)
    start = time.monotonic()
    anyio.run(run)
    return time.monotonic() - start


def test_different_devices_run_in_parallel(m):
    a, b = NAMES[:2]
    solo = {n: _wait_absent(m, [n]) for n in (a, b)}
    both = _wait_absent(m, [a, b])
    print(f"solo {solo}, together {both:.2f}s")
    assert both < 0.75 * (solo[a] + solo[b]), (solo, both)


def test_one_device_runs_its_calls_in_order(m):
    a = NAMES[0]
    solo = _wait_absent(m, [a])
    pair = _wait_absent(m, [a, a])
    print(f"solo {solo:.2f}s, same-device pair {pair:.2f}s")
    assert pair >= 1.6 * solo, (solo, pair)
