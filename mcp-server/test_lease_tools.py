"""ios_reserve_device, ios_release_device and ios_device_leases.

No device: the other agents are real child processes whose holds and
tickets are written into this test's own lease directory (conftest.py),
and WDA is RoutedWDA from test_multi_device.
"""
from __future__ import annotations

import json
import threading
import time

import anyio
import pytest

import devicelease as dl
from test_devicelease_store import decide_as, sleeper, top  # noqa: F401
from test_lease_hook import K16E, K17, foreign
from test_multi_device import reg, tool_schemas, wda  # noqa: F401


def reserve(m, **kw) -> dict:
    async def go():
        return await m.ios_reserve_device(**kw)
    return json.loads(anyio.run(go))


def other(proc: dl.Proc) -> dl.Caller:
    return dl.Caller(chain=(proc,), anchor=proc, via="imirror-mcp other",
                     cwd="/Users/x/other-wt")


# ---- reserving ---------------------------------------------------------------------

def test_reserve_on_a_free_phone_holds_it_for_hold_s(reg, wda):
    out = reserve(reg.m, device="phone1", agent="tester", hold_s=600)
    assert out["status"] == "held" and out["devices"] == ["phone1"]
    assert out["agent"] == "tester" and out["lease_id"]
    assert out["expires_at"].endswith("Z") and 590 <= out["expires_in_s"] <= 600
    h = top(K16E)
    assert h["mode"] == "explicit" and h["label"] == "tester"
    # Calling again renews it, and the holder's own taps go straight through.
    again = reserve(reg.m, device="phone1", agent="tester", hold_s=3600)
    assert again["lease_id"] == out["lease_id"]
    assert top(K16E)["hold_until_mono"] - top(K16E)["last_used_mono"] > 3590
    # An agent's hold still ends 20 minutes after it was last used.
    assert 1190 <= again["expires_in_s"] <= 1200
    reg.m.ios_tap(1, 2, device="phone1", agent="tester")
    with pytest.raises(reg.m.MCPToolError) as e:
        reg.m.ios_tap(1, 2, device="phone1", agent="someone")
    assert e.value.error_code == "DEVICE_BUSY"
    assert wda.aliases_for("/actions") == ["phone1"]


def test_reserve_clamps_wait_to_85_s_and_hold_to_an_hour(reg, monkeypatch):
    seen = {}

    async def fake(self, keys, **kw):
        seen.update(kw)
        return dl.Outcome(status="held", keys=tuple(keys), lease_id="L")
    monkeypatch.setattr(dl.Locker, "acquire_async", fake)
    reserve(reg.m, device="phone1", wait_s=500, hold_s=99999)
    assert 84 < seen["wait_s"] <= 85 and seen["hold_s"] == 3600


def test_a_retried_reserve_waits_only_what_is_left(reg, monkeypatch):
    """A lost belief is retried once. Each try used to get the full wait,
    so one call could block 170 s, past Claude Code's 120 s."""
    waits = []

    async def fake(self, keys, *, wait_s, **kw):
        waits.append(wait_s)
        await anyio.sleep(0.3)
        status = "lost" if len(waits) == 1 else "queued"
        return dl.Outcome(status=status, keys=tuple(keys), ticket="t", position=1)
    monkeypatch.setattr(dl.Locker, "acquire_async", fake)
    out = reserve(reg.m, device="phone1", wait_s=0.5)
    assert out["status"] == "queued" and len(waits) == 2
    assert waits[0] == pytest.approx(0.5, abs=0.05) and waits[1] < 0.25


def test_a_busy_phone_queues_the_caller_and_names_the_holder(reg, sleeper):
    foreign(sleeper(), K16E)
    t0 = time.monotonic()
    out = reserve(reg.m, device="phone1", agent="b", wait_s=0.6)
    assert 0.5 <= time.monotonic() - t0 < 5
    assert out["status"] == "queued" and out["position"] == 1 and out["ticket"]
    assert out["hint"] == ("call ios_reserve_device again with the same agent to keep "
                           "your place")
    h = out["holder"]
    assert h["agent"] is None and h["purpose"] == "other work"
    assert "pid" in h["session"] and "other-wt" in h["session"]
    assert h["since"] and h["idle_s"] >= 0
    again = reserve(reg.m, device="phone1", agent="b", wait_s=0)
    assert again["ticket"] == out["ticket"] and again["position"] == 1
    third = reserve(reg.m, device="phone1", agent="c", wait_s=0)
    assert third["position"] == 2, "another agent in this session queues behind"


def test_a_waiter_gets_the_phone_as_soon_as_the_holder_releases(reg, sleeper):
    p = sleeper()
    foreign(p, K16E)
    threading.Timer(0.4, decide_as, (other(p), "release", [K16E])).start()
    t0 = time.monotonic()
    out = reserve(reg.m, device="phone1", agent="b", wait_s=20)
    assert out["status"] == "held" and time.monotonic() - t0 < 5
    assert top(K16E)["label"] == "b" and top(K16E)["claim_until_mono"] is None


def test_two_phones_are_reserved_all_or_nothing(reg, sleeper):
    foreign(sleeper(), K17)
    out = reserve(reg.m, device="phone1,phone2", agent="b", wait_s=0)
    assert out["status"] == "queued" and out["devices"] == ["phone1", "phone2"]
    assert top(K16E) is None, "the free phone is not taken alone"


def test_a_wait_that_would_deadlock_is_refused(reg, sleeper):
    p = sleeper()
    foreign(p, K17)
    assert reserve(reg.m, device="phone1", agent="a")["status"] == "held"
    queued = decide_as(other(p), "acquire", [K16E], mode="explicit", wait=True)
    assert queued.status == "queued"
    with pytest.raises(reg.m.MCPToolError) as e:
        reserve(reg.m, device="phone2", agent="a", wait_s=1)
    assert e.value.error_code == "DEVICE_DEADLOCK" and "phone2" in str(e.value)


def test_reserve_through_fastmcp(reg):
    blocks = anyio.run(reg.m.mcp.call_tool, "ios_reserve_device",
                       {"device": "phone2", "agent": "x", "wait_s": 0})
    content = blocks[0] if isinstance(blocks, tuple) else blocks
    assert json.loads(content[0].text)["status"] == "held"
    schema = tool_schemas(reg.m)["ios_reserve_device"]["properties"]
    assert set(schema) == {"device", "agent", "wait_s", "hold_s", "purpose"}
    assert schema["wait_s"]["default"] == 60 and schema["hold_s"]["default"] == 900


# ---- releasing ---------------------------------------------------------------------

def test_release_hands_the_phone_to_the_next_in_line_at_once(reg, sleeper):
    p = sleeper()
    reserve(reg.m, device="phone1", agent="a")
    assert decide_as(other(p), "acquire", [K16E], mode="explicit", wait=True).status == "queued"
    out = json.loads(reg.m.ios_release_device(device="phone1", agent="a"))
    assert out == {"released": ["phone1"], "not_held": []}
    assert top(K16E)["anchor"]["pid"] == p.pid


def test_release_never_frees_another_agents_hold_in_this_session(reg):
    reserve(reg.m, device="phone1", agent="a")
    for agent in ("b", ""):
        out = json.loads(reg.m.ios_release_device(device="phone1", agent=agent))
        assert out == {"released": [], "not_held": ["phone1"]}
    assert top(K16E)["label"] == "a"


def test_release_gives_up_a_place_in_line(reg, sleeper):
    foreign(sleeper(), K16E)
    reserve(reg.m, device="phone1", agent="b", wait_s=0)
    reg.m.ios_release_device(device="phone1", agent="b")
    out = reserve(reg.m, device="phone1", agent="c", wait_s=0)
    assert out["position"] == 1


# ---- showing ---------------------------------------------------------------------

def test_device_leases_shows_holder_queue_and_ages(reg, sleeper):
    foreign(sleeper(), K16E)
    reserve(reg.m, device="phone1", agent="b", wait_s=0)
    reserve(reg.m, device="phone2", agent="b")
    out = json.loads(reg.m.ios_device_leases(agent="b"))
    assert out["leases"] == "on"
    rows = {d["alias"]: d for d in out["devices"]}
    assert rows["phone1"]["key"] == K16E and rows["phone1"]["state"] == "busy"
    assert rows["phone1"]["queue"] == 1 and rows["phone1"]["your_position"] == 1
    assert rows["phone1"]["holder"]["purpose"] == "other work"
    assert rows["phone1"]["waiting"][0]["purpose"] == "agent 'b' reserved it"
    assert rows["phone1"]["waiting"][0]["agent"] == "b"
    assert rows["phone2"]["state"] == "yours" and rows["phone2"]["holder"]["agent"] == "b"
    one = json.loads(reg.m.ios_device_leases(device="phone2"))
    assert [d["alias"] for d in one["devices"]] == ["phone2"]
    assert one["devices"][0]["state"] == "busy", "unnamed: not b's view"


def test_devices_and_status_show_each_lease(reg, wda, sleeper, monkeypatch):
    import devicelease
    monkeypatch.setattr(devicelease.Locker, "unlocked_servers",
                        lambda self: [{"pid": 4242, "kind": "mcp", "reason": "old",
                                       "command": "python imirror_mcp.py"}])
    foreign(sleeper(), K16E)
    out = json.loads(reg.m.ios_devices())
    assert out["leases"] == "on"
    assert out["servers_ignoring_leases"] == [{"pid": 4242, "kind": "mcp", "reason": "old"}]
    rows = {d["alias"]: d for d in out["devices"]}
    assert rows["phone1"]["lease"]["state"] == "busy"
    assert rows["phone1"]["lease"]["holder"]["purpose"] == "other work"
    assert rows["phone2"]["lease"] == {"state": "free", "holder": None, "queue": 0,
                                       "your_position": None}
    st = json.loads(reg.m.ios_status(device="phone1"))
    assert st["lease"]["state"] == "busy"


def test_the_instructions_tell_agents_how_to_share_a_device(reg):
    text = reg.m.mcp.instructions
    assert "ios_reserve_device(device, agent=<your name>) — repeat while queued" in text
    assert "ios_release_device" in text and "DEVICE_BUSY" in text


def test_a_running_server_registers_as_one_that_takes_leases(reg):
    import os
    reg.m._register_lease_server()
    folder = os.path.join(os.environ["IMIRROR_LEASE_DIR"], "servers")
    names = os.listdir(folder)
    assert len(names) == 1 and names[0].startswith(f"{os.getpid()}-")
    with open(os.path.join(folder, names[0])) as f:
        assert json.load(f)["version"] == reg.m.__version__
    assert all(x["pid"] != os.getpid() for x in reg.m._leases().unlocked_servers())
