"""The MCP server asks for a device lease before it drives a device.

No device: the "other agent" is a real child process whose (pid, uniqueid)
is written into this test's own lease directory (conftest.py), and WDA is
either RoutedWDA (test_multi_device) or the real-HTTP fake WDA server, so
the server's own _http choke point runs.
"""
from __future__ import annotations

import dataclasses
import fcntl
import json
import os
import subprocess
import threading
import time

import anyio
import pytest

import devicelease as dl
from test_devicelease_store import decide_as, sleeper, top, wait_for, write_state  # noqa: F401
from test_multi_device import PHONE_16E, PHONE_17, reg, tool_schemas, wda  # noqa: F401
from test_ride_out import dead, load  # noqa: F401
from testsupport.fake_wda_server import FakeWDAServer

K16E = dl.device_key(PHONE_16E)
K17 = dl.device_key(PHONE_17)

OBSERVE = {"ios_status", "ios_window_size", "ios_screenshot", "ios_app_state",
           "ios_start_run"}
NO_DEVICE = {"ios_run_note", "ios_run_section", "ios_finish_run", "ios_devices",
             "sim_list", "sim_enable", "sim_disable"}


def foreign(proc: dl.Proc, key: str, hold_s: float = 600, **kw) -> dl.Outcome:
    """Another session's explicit hold on `key`. Its stored chain is just
    itself, so it is nobody this test process started or descends from."""
    me = dl.Caller(chain=(proc,), anchor=proc, via="imirror-mcp other",
                   cwd="/Users/x/other-wt")
    out = decide_as(me, "acquire", [key], mode="explicit", hold_s=hold_s, purpose="other work",
                    **kw)
    assert out.status == "held", out
    return out


def steal(key: str, proc: dl.Proc) -> None:
    """Hand the current hold on `key` to `proc`, as a lapse and a new grant
    would: a new lease id and epoch, so the old holder's belief is gone."""
    def fn(st, now):
        ks = st["keys"][key]
        e = ks["holders"][-1]
        ks["epoch"] += 1
        e.update(anchor={"pid": proc.pid, "uniqueid": proc.uniq, "name": "sleep"},
                 ancestors=[], label="", lease_id="someone-else", epoch=ks["epoch"])
        return st
    write_state(fn)


def quick(m) -> dl.Locker:
    """The server's lease runtime with a fast heartbeat and no touch
    throttle, so a test sees renewals and revocations in milliseconds."""
    lk = m._leases()
    lk.heartbeat_s = 0.05
    lk.cfg = dataclasses.replace(lk.cfg, touch_s=0.05)
    return lk


# ---- the tool schema -------------------------------------------------------------

def test_drive_and_inspect_tools_take_an_agent_and_observe_tools_do_not(reg):
    for name, schema in tool_schemas(reg.m).items():
        props = schema.get("properties", {})
        if name in OBSERVE | NO_DEVICE:
            assert "agent" not in props, name
        else:
            assert props["agent"]["type"] == "string", name
            assert props["agent"].get("default") == "", name
            assert "agent" not in schema.get("required", []), name
            assert "ios_reserve_device" in props["agent"]["description"], name


# ---- automatic holds ---------------------------------------------------------------

def test_a_tap_on_a_free_phone_takes_a_short_automatic_hold(reg, wda):
    reg.m.ios_tap(1, 2, device="phone1", agent="Explorer")
    h = top(K16E)
    assert h["mode"] == "auto" and h["label"] == "explorer"
    assert h["hold_until_mono"] == 0.0, "an automatic hold lapses when idle"
    assert h["idle_s"] in (300.0, 90.0)          # 90 when run from a bare terminal
    assert "ios_tap" in h["purpose"] and "explorer" in h["purpose"]
    assert top(K17) is None, "the other phone is untouched"


def test_a_phone_another_agent_holds_fails_fast_and_nothing_reaches_wda(reg, wda, sleeper):
    m = reg.m
    foreign(sleeper(), K16E)
    t0 = time.monotonic()
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(1, 2, device="phone1")
    assert time.monotonic() - t0 < 2
    assert e.value.error_kind == "lease" and e.value.error_code == "DEVICE_BUSY"
    msg = str(e.value)
    assert "Nothing was sent" in msg and "phone1" in msg and K16E not in msg
    assert "other work" in msg
    assert "ios_reserve_device(device='phone1', agent=<your name>)" in msg
    assert e.value.fields["retry_after_s"] >= 1
    # Inspect calls and ios_recover are refused too.
    for call in (lambda: m.ios_source(device="phone1"),
                 lambda: m.ios_wait_for("OK", timeout_s=0, device="phone1"),
                 lambda: m.ios_orientation(device="phone1"),
                 lambda: m.ios_alert(device="phone1"),
                 lambda: m.ios_alert("accept", device="phone1"),
                 lambda: m.ios_recover(device="phone1")):
        with pytest.raises(m.MCPToolError) as e:
            call()
        assert e.value.error_code == "DEVICE_BUSY"
    assert wda.calls == []
    # Observe calls are never checked.
    m.ios_screenshot(device="phone1")
    json.loads(m.ios_status(device="phone1"))
    json.loads(m.ios_window_size(device="phone1"))
    assert wda.aliases_for("/actions") == []
    m.ios_tap(1, 2, device="phone2")             # another phone is free
    assert wda.aliases_for("/actions") == ["phone2"]


def test_an_automatic_call_never_waits_even_for_a_hold_about_to_lapse(reg, wda, sleeper):
    foreign(sleeper(), K16E, hold_s=0)

    def nearly_idle(st, now):
        st["keys"][K16E]["holders"][-1]["last_used_mono"] = now - 295
        st["keys"][K16E]["holders"][-1]["mode"] = "auto"
        return st
    write_state(nearly_idle)
    t0 = time.monotonic()
    with pytest.raises(reg.m.MCPToolError) as e:
        reg.m.ios_tap(1, 2, device="phone1")
    assert time.monotonic() - t0 < 1, "the CLI's 20 s auto-wait is off for agents"
    assert e.value.error_code == "DEVICE_BUSY"


def test_inspect_on_a_free_phone_runs_without_taking_it(reg, wda):
    reg.m.ios_source(device="phone1")
    assert top(K16E) is None
    assert any("/source" in p for _, _, p in wda.calls)


def test_two_agents_in_one_session_are_two_holders(reg, wda):
    m = reg.m
    m.ios_tap(1, 2, device="phone1", agent="a")
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(1, 2, device="phone1", agent="b")
    assert e.value.error_code == "DEVICE_BUSY" and 'subagent "a"' in str(e.value)
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(1, 2, device="phone1")
    assert "agent=<your name>" in str(e.value)
    m.ios_tap(3, 4, device="phone1", agent="A")   # labels ignore case
    assert wda.aliases_for("/actions") == ["phone1", "phone1"]


def test_named_subagents_never_both_drive_the_parents_phone(reg, wda):
    """The parent taps unnamed, then two named subagents start. Neither may
    drive while the parent's hold is fresh; once it is idle, exactly one
    takes it."""
    m = reg.m
    m.ios_tap(1, 2, device="phone1")
    for name in ("a", "b"):
        with pytest.raises(m.MCPToolError) as e:
            m.ios_tap(1, 2, device="phone1", agent=name)
        assert e.value.error_code == "DEVICE_BUSY" and "no agent name" in str(e.value)
        assert "ios_reserve_device(device='phone1'" in str(e.value)
    write_state(lambda st, now: (st["keys"][K16E]["holders"][-1].update(
        last_used_mono=now - 31), st)[1])
    m.ios_tap(1, 2, device="phone1", agent="a")
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(1, 2, device="phone1", agent="b")
    assert 'subagent "a"' in str(e.value)
    assert wda.aliases_for("/actions") == ["phone1", "phone1"]


def test_an_inspect_call_after_its_hold_was_lost_runs_once_with_a_warning(reg, wda, sleeper):
    m = reg.m
    m.ios_tap(1, 2, device="phone1")
    steal(K16E, sleeper())
    out = m.ios_source(device="phone1")
    assert out.startswith("WARNING: Your hold on this device ended")
    with pytest.raises(m.MCPToolError) as e:
        m.ios_source(device="phone1")
    assert e.value.error_code == "DEVICE_BUSY"


def test_a_drive_call_after_its_hold_was_lost_says_lost_once(reg, wda, sleeper):
    m = reg.m
    m.ios_tap(1, 2, device="phone1")
    steal(K16E, sleeper())
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(1, 2, device="phone1")
    assert e.value.error_code == "DEVICE_RESERVATION_LOST"
    assert "take a screenshot" in str(e.value)
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(1, 2, device="phone1")
    assert e.value.error_code == "DEVICE_BUSY"
    assert wda.aliases_for("/actions") == ["phone1"]


def test_a_busy_call_through_fastmcp_carries_the_code(reg, wda, sleeper):
    foreign(sleeper(), K16E)
    from mcp.server.fastmcp.exceptions import ToolError
    with pytest.raises(ToolError) as e:
        anyio.run(reg.m.mcp.call_tool, "ios_tap",
                  {"x": 1, "y": 2, "device": "phone1", "agent": "z"})
    assert "code=DEVICE_BUSY" in str(e.value) and "kind=lease" in str(e.value)
    assert wda.calls == []


def test_leases_off_lets_every_call_through(reg, wda, sleeper, monkeypatch):
    foreign(sleeper(), K16E)
    monkeypatch.setenv("IMIRROR_LEASE", "off")    # honoured only under testing here
    reg.m.ios_tap(1, 2, device="phone1")
    assert wda.aliases_for("/actions") == ["phone1"]


# ---- keys ------------------------------------------------------------------------

def test_keys_are_udids_never_aliases(reg):
    m = reg.m
    targets = {t.alias: t for t in m._targets()[1]}
    assert m._lease_key(targets["phone1"]) == K16E
    sim = m._Target(key="S", alias="sim", udid="5b3c1f2a-0000-4000-8000-00000000a1b2",
                    kind="simulator", wda="http://127.0.0.1:8201")
    assert m._lease_key(sim) == "sim:5B3C1F2A-0000-4000-8000-00000000A1B2"


def test_a_pinned_server_finds_its_udid_in_the_device_file_or_locks_the_url(reg, monkeypatch):
    m = reg.m
    legacy = m._LEGACY
    monkeypatch.setattr(legacy, "udid", None)
    monkeypatch.setattr(legacy, "wda", "http://127.0.0.1:8110/")
    assert m._lease_key(legacy) == K17
    monkeypatch.setattr(legacy, "wda", "http://127.0.0.1:8300")
    assert m._lease_key(legacy) == "wda:127.0.0.1:8300"


# ---- mid-call: the _http choke point, sequences, recovery, installs ----------------

@pytest.fixture()
def wire(monkeypatch, tmp_path):
    """A server pinned to the real-HTTP fake WDA, keyed by a known UDID."""
    fake = FakeWDAServer(session="S1").start()
    monkeypatch.setenv("IMIRROR_WDA", fake.url)
    monkeypatch.setenv("IMIRROR_UDID", PHONE_16E)
    monkeypatch.setenv("IMIRROR_DEVICES_FILE", str(tmp_path / "devices.json"))
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path / "runs"))
    for var in ("IMIRROR_TARGET", "IMIRROR_DEFAULT_DEVICE"):
        monkeypatch.delenv(var, raising=False)
    import importlib
    import sys
    sys.modules.pop("imirror_mcp", None)
    m = importlib.import_module("imirror_mcp")
    m._session["id"] = "S1"
    yield m, fake
    m._drop_conn(fake.url)
    fake.stop()


def test_a_hold_taken_away_mid_call_stops_before_the_next_wda_request(wire, sleeper):
    m, fake = wire
    quick(m)
    other = sleeper()
    fake.find_ids["OK"] = ["e1"]
    fake.delays["/session/S1/element"] = [0.6]
    threading.Timer(0.2, steal, (K16E, other)).start()
    with pytest.raises(m.MCPToolError) as e:
        m.ios_find_and_tap("OK")
    assert e.value.error_code == "DEVICE_RESERVATION_LOST"
    assert "Stopped mid-call" in str(e.value) and K16E not in str(e.value)
    assert fake.count("POST", "/session/S1/element") == 1
    assert fake.count("POST", "/session/S1/element/e1/click") == 0


def test_a_sequence_stops_at_the_step_after_its_hold_is_lost(wire, sleeper):
    m, fake = wire
    quick(m)
    other = sleeper()
    fake.delays["/session/S1/actions"] = [0.6]
    threading.Timer(0.2, steal, (K16E, other)).start()
    out = json.loads(m.ios_run_sequence([{"action": "tap", "x": 1, "y": 1},
                                         {"action": "tap", "x": 2, "y": 2},
                                         {"action": "tap", "x": 3, "y": 3}]))
    assert not out["ok"] and out["ran"] == 2
    assert "code=DEVICE_RESERVATION_LOST" in out["steps"][1]["error"]
    assert fake.count("POST", "/session/S1/actions") == 1


def test_a_recovery_wait_keeps_the_hold_and_counts_as_use(dead, monkeypatch):
    """A tap that rides out a chain restart stays in flight: the heartbeat
    renews the hold, so the wait is not idle time, and the hold is still
    there when the call gives up."""
    m, app = dead
    monkeypatch.setattr(m, "_RIDE_OUT_S", 0.8)
    quick(m)
    app.write("starting", reason="usb_reset", chain_epoch=2)
    errors = []

    def tap():
        try:
            m.ios_tap(1, 1, agent="a")
        except m.MCPToolError as e:
            errors.append(e)
    th = threading.Thread(target=tap)
    th.start()
    first = wait_for(lambda: top(f"device:{app_udid()}"), what="the hold")
    used = float(first["last_used_mono"])
    time.sleep(0.4)                              # mid ride-out
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(1, 1, agent="b")
    assert e.value.error_code == "DEVICE_BUSY"
    th.join(5)
    assert errors and errors[0].error_code == "RECOVERING"
    now = top(f"device:{app_udid()}")
    assert now["lease_id"] == first["lease_id"], "the hold survived the wait"
    assert float(now["last_used_mono"]) > used, "the wait counted as use"


def app_udid() -> str:
    from test_ride_out import PHONE
    return PHONE


def test_recover_is_a_drive_call(dead, sleeper, tmp_path):
    m, app = dead
    foreign(sleeper(), f"device:{app_udid()}")
    with pytest.raises(m.MCPToolError) as e:
        m.ios_recover()
    assert e.value.error_code == "DEVICE_BUSY"
    assert not os.path.exists(os.path.join(app.requests, f"restart-{app_udid()}.json"))


def test_an_install_that_lost_its_hold_waiting_for_devicectl_lock_never_runs(
        monkeypatch, tmp_path, sleeper):
    """Lease first, then devicectl.lock: the order that cannot deadlock. A
    hold that ends during the lock wait stops the install before go-ios."""
    monkeypatch.setenv("IMIRROR_WDA", "http://127.0.0.1:8100")
    monkeypatch.setenv("IMIRROR_UDID", PHONE_16E)
    monkeypatch.setenv("IMIRROR_DEVICES_FILE", str(tmp_path / "devices.json"))
    monkeypatch.setenv("IMIRROR_IOS_BIN", "/x/ios")
    monkeypatch.delenv("IMIRROR_TARGET", raising=False)
    import importlib
    import sys
    sys.modules.pop("imirror_mcp", None)
    m = importlib.import_module("imirror_mcp")
    monkeypatch.setattr(m, "_INSTALL_LOCK_POLL_S", 0.02)
    quick(m)
    ran = []
    monkeypatch.setattr(m.subprocess, "run", lambda args, **kw: ran.append(args))
    ipa = tmp_path / "App.ipa"
    ipa.write_bytes(b"PK")
    fd = os.open(tmp_path / "devicectl.lock", os.O_CREAT | os.O_RDWR, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)              # another session is installing
    errors = []

    def install():
        try:
            m.ios_install_app(str(ipa))
        except m.MCPToolError as e:
            errors.append(e)
    th = threading.Thread(target=install)
    th.start()
    wait_for(lambda: top(K16E), what="the install's hold")
    steal(K16E, sleeper())
    time.sleep(0.3)
    os.close(fd)                                # the other install finished
    th.join(5)
    assert errors and errors[0].error_code == "DEVICE_RESERVATION_LOST"
    assert ran == []
