"""The MCP server rides out a chain restart instead of failing at once.

When WDA stops answering, the iMirror app is often already restarting that
phone's chain and says so in devices.json. These tests write that file (and
events.jsonl, and read the restart requests) in a temp folder, and drive a
real-HTTP fake WDA, so no phone is needed.
"""
from __future__ import annotations

import importlib
import json
import os
import socket
import sys
import threading
import time

import pytest

from testsupport.fake_wda_server import FakeWDAServer

PHONE = "00008140-0006423002D3401C"
OTHER = "00008150-001928E01404401C"


def free_port() -> int:
    """A loopback port nothing listens on, so a connect is refused."""
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class App:
    """Plays the iMirror app: writes devices.json and events.jsonl."""

    def __init__(self, folder: str, port: int):
        self.folder, self.port = folder, port
        self.devices = os.path.join(folder, "devices.json")
        self.events = os.path.join(folder, "events.jsonl")
        self.requests = os.path.join(folder, "requests")

    def write(self, state: str = "ready", **extra) -> None:
        dev = {"udid": PHONE, "alias": "phone1", "kind": "device",
               "wda_url": f"http://127.0.0.1:{self.port}", "state": state, **extra}
        doc = {"schema": 1, "owner_pid": os.getpid(), "app_version": "test",
               "updated_at": "2026-11-13T00:00:00Z", "goios": "", "devices": [dev]}
        tmp = self.devices + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(doc, f)
        os.replace(tmp, self.devices)

    def later(self, seconds: float, fn, *args, **kw) -> threading.Thread:
        def run():
            time.sleep(seconds)
            fn(*args, **kw)
        th = threading.Thread(target=run, daemon=True)
        th.start()
        return th

    def log(self, udid: str, event: str, path: str | None = None, **kw) -> None:
        line = {"ts": kw.pop("ts", "2026-11-13T10:00:00.000Z"), "udid": udid,
                "alias": "phone1", "event": event, **kw}
        with open(path or self.events, "a", encoding="utf-8") as f:
            f.write(json.dumps(line) + "\n")


@pytest.fixture()
def fake():
    server = FakeWDAServer().start()
    yield server
    server.stop()


def load(monkeypatch, tmp_path):
    for var in ("IMIRROR_WDA", "IMIRROR_TARGET", "IMIRROR_DEFAULT_DEVICE", "IMIRROR_UDID"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setenv("IMIRROR_DEVICES_FILE", str(tmp_path / "devices.json"))
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path / "runs"))
    sys.modules.pop("imirror_mcp", None)
    m = importlib.import_module("imirror_mcp")
    monkeypatch.setattr(m, "_RIDE_OUT_S", 3.0)
    monkeypatch.setattr(m, "_RIDE_OUT_POLL_S", 0.05)
    monkeypatch.setattr(m, "_NOTICE_S", 0.3)
    monkeypatch.setattr(m, "_RECOVER_WAIT_S", 3.0)
    return m


@pytest.fixture()
def live(fake, monkeypatch, tmp_path):
    """List mode, one phone whose WDA is the running fake."""
    app = App(str(tmp_path), int(fake.url.rsplit(":", 1)[1]))
    app.write(chain_epoch=1)
    m = load(monkeypatch, tmp_path)
    url = fake.url
    yield m, app
    m._drop_conn(url)


@pytest.fixture()
def dead(monkeypatch, tmp_path):
    """List mode, one phone whose WDA port refuses connections."""
    app = App(str(tmp_path), free_port())
    app.write(chain_epoch=1)
    return load(monkeypatch, tmp_path), app


# ---- the pure rule ---------------------------------------------------------------

@pytest.mark.parametrize("state,reason,phase", [
    ("ready", None, "ready"),
    ("ready", "usb_reset", "recovering"),
    ("starting", None, "recovering"),
    ("installing", None, "recovering"),
    ("down", "usb_reset", "recovering"),
    ("down", "wda_wedged", "recovering"),
    ("down", "tunnel_down", "recovering"),
    ("down", "recovering", "recovering"),
    ("starting", "booting", "recovering"),
    ("down", "needs_passcode", "needs_passcode"),
    ("starting", "locked", "needs_passcode"),
    ("down", "gave_up", "gave_up"),
    ("failed", None, "gave_up"),
    ("down", None, "recovering"),            # an app without `reason`
    ("down", "mac_asleep", "down"),
    (None, None, "down"),
])
def test_chain_phase(dead, state, reason, phase):
    m, _ = dead
    assert m._chain_phase(state, reason) == phase


def test_error_tail_carries_extra_fields_as_single_tokens(dead):
    m, _ = dead
    e = m.MCPToolError("x", kind=m.ErrorKind.UNREACHABLE, code="RECOVERING",
                       fields={"retry_after_s": 15, "reason": "usb reset]", "skip": None})
    assert str(e) == "x [kind=unreachable code=RECOVERING retry_after_s=15 reason=usb_reset_]"
    assert e.fields == {"retry_after_s": 15, "reason": "usb reset]"}


def test_device_file_chain_fields_are_read(dead):
    m, app = dead
    app.write("down", reason="gave_up", state_since="2026-11-13T10:00:00Z", chain_epoch=7,
              last_error="x" * 500, next_retry_at="2026-11-13T10:02:00Z")
    t = m._resolve("phone1")
    assert (t.reason, t.state_since, t.chain_epoch, t.next_retry_at) == (
        "gave_up", "2026-11-13T10:00:00Z", 7, "2026-11-13T10:02:00Z")
    assert len(t.last_error) == 200
    app.write("ready", chain_epoch=True)       # a bool is not an epoch
    assert m._resolve("phone1").chain_epoch is None


# ---- riding out ------------------------------------------------------------------

def test_a_read_waits_for_the_restart_then_retries_once(fake, live):
    m, app = live
    port, url = int(fake.url.rsplit(":", 1)[1]), fake.url
    fake.stop()
    m._drop_conn(url)                           # its kept-alive socket too
    app.write("starting", reason="usb_reset", chain_epoch=2)
    back = FakeWDAServer()

    def come_back():
        back.start(port)
        app.write("ready", chain_epoch=2)
    app.later(0.4, come_back)
    try:
        t0 = time.monotonic()
        img = m.ios_screenshot()
        assert img.data.startswith(b"\x89PNG")
        assert time.monotonic() - t0 >= 0.3
        # The new WDA saw only the retry, no polling.
        assert back.paths() == ["/status", "/screenshot"]
    finally:
        m._drop_conn(back.url)
        back.stop()


def test_a_wedged_read_rides_out_the_restart_too(fake, live):
    m, app = live
    fake.drops["/screenshot"] = 3               # _req gives up: WEDGED
    app.write("down", reason="wda_wedged", chain_epoch=1)
    app.later(0.2, app.write, "ready", chain_epoch=2)
    assert m.ios_screenshot().data.startswith(b"\x89PNG")
    assert fake.count("GET", "/screenshot") == 4


def test_a_tap_waits_but_is_never_repeated(dead):
    m, app = dead
    app.write("starting", reason="usb_reset", chain_epoch=2)
    app.later(0.3, app.write, "ready", chain_epoch=2)
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(10, 20)
    assert e.value.error_code == "RECOVERING"
    assert e.value.fields["retry_after_s"] == 0
    assert "not retried" in str(e.value) and "retry_after_s=0" in str(e.value)


def test_a_tap_cut_off_by_a_restart_waits_and_still_says_outcome_unknown(fake, live):
    """WDA took the tap, then the chain restarted before it answered. The call
    rides out the restart like any change, but keeps kind=outcome_unknown, so
    the agent looks before tapping again, and the tap is not sent again."""
    m, app = live
    m.ios_tap(1, 1)
    actions = f"/session/{fake.active}/actions"
    fake.drops[actions] = 1
    app.write("starting", reason="usb_reset", chain_epoch=2)
    app.later(0.3, app.write, "ready", chain_epoch=2)
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(10, 20)
    assert e.value.error_kind == m.ErrorKind.OUTCOME_UNKNOWN
    assert e.value.error_code == "RECOVERING"
    assert "not retried" in str(e.value)
    assert fake.count("POST", actions) == 2


def test_still_recovering_after_the_budget_says_when_to_retry(dead, monkeypatch):
    m, app = dead
    monkeypatch.setattr(m, "_RIDE_OUT_S", 0.3)
    app.write("starting", reason="usb_reset", state_since="2026-11-13T10:00:00Z",
              chain_epoch=2)
    t0 = time.monotonic()
    with pytest.raises(m.MCPToolError) as e:
        m.ios_source()
    assert 0.3 <= time.monotonic() - t0 < 2
    assert e.value.error_code == "RECOVERING"
    assert e.value.fields == {"reason": "usb_reset", "retry_after_s": 15}
    assert "since 2026-11-13T10:00:00Z" in str(e.value)


# Only a lock can be auto-unlocked; the sheet is never typed by itself.
@pytest.mark.parametrize("reason,where", [("needs_passcode", "never types that by itself"),
                                          ("locked", "turned on auto-unlock")])
def test_a_phone_waiting_for_its_passcode_fails_at_once(dead, reason, where):
    m, app = dead
    app.write("starting", reason=reason, chain_epoch=2)
    t0 = time.monotonic()
    with pytest.raises(m.MCPToolError) as e:
        m.ios_screenshot()
    assert time.monotonic() - t0 < 1            # nothing to wait for
    assert e.value.error_code == "NEEDS_PASSCODE"
    assert where in str(e.value)
    assert "Type passcode now" in str(e.value)
    assert "never type a passcode yourself" in str(e.value)


def test_a_passcode_prompt_during_the_wait_ends_it(dead):
    m, app = dead
    app.write("starting", reason="usb_reset", chain_epoch=2)
    app.later(0.2, app.write, "starting", reason="needs_passcode", chain_epoch=2)
    with pytest.raises(m.MCPToolError) as e:
        m.ios_screenshot()
    assert e.value.error_code == "NEEDS_PASSCODE"


def test_a_phone_the_app_gave_up_on_says_when_it_retries(dead):
    m, app = dead
    app.write("down", reason="gave_up", last_error="runwda exited", chain_epoch=3,
              next_retry_at="2099-01-01T00:00:00Z")
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(1, 2)
    assert e.value.error_code == "DEVICE_GAVE_UP"
    assert "next_retry_at=2099-01-01T00:00:00Z" in str(e.value)
    assert e.value.fields["retry_after_s"] > 0
    assert "runwda exited" in str(e.value) and "ios_recover" in str(e.value)


def test_an_old_apps_failed_state_is_a_give_up_without_a_retry_time(dead):
    m, app = dead
    app.write("failed")
    with pytest.raises(m.MCPToolError) as e:
        m.ios_screenshot()
    assert e.value.error_code == "DEVICE_GAVE_UP"
    assert "will not try again by itself" in str(e.value)


def test_a_phone_the_app_calls_ready_gets_the_plain_error(dead):
    m, _ = dead
    t0 = time.monotonic()
    with pytest.raises(m.MCPToolError) as e:
        m.ios_screenshot()
    assert 0.3 <= time.monotonic() - t0 < 1.5   # the notice window only
    assert e.value.error_kind == "unreachable" and e.value.error_code is None


def test_a_read_rides_out_a_restart_the_app_has_not_noticed_yet(fake, live):
    # The call fails while the file still says ready.
    m, app = live
    port, url = int(fake.url.rsplit(":", 1)[1]), fake.url
    fake.stop()
    m._drop_conn(url)
    back = FakeWDAServer()

    def come_back():
        back.start(port)
        app.write("ready", chain_epoch=2)
    app.later(0.15, app.write, "starting", reason="usb_reset", chain_epoch=2)
    app.later(0.5, come_back)
    try:
        assert m.ios_screenshot().data.startswith(b"\x89PNG")
        assert back.paths() == ["/status", "/screenshot"]
    finally:
        m._drop_conn(back.url)
        back.stop()


def test_a_chain_that_restarted_during_the_call_counts_as_recovered(dead):
    m, app = dead
    app.write("ready", chain_epoch=2)
    t = m._resolve("phone1")
    err = m.MCPToolError("gone", kind=m.ErrorKind.UNREACHABLE)
    assert m._ride_out(t, err, 1, lambda: "again") == "again"
    with pytest.raises(m.MCPToolError) as e:
        m._ride_out(t, err, 1, None)
    assert e.value.error_code == "RECOVERING" and e.value.fields["retry_after_s"] == 0
    with pytest.raises(m.MCPToolError) as e:   # same epoch: nothing restarted
        m._ride_out(t, err, 2, lambda: "again")
    assert e.value is err


def test_a_phone_that_leaves_the_file_gets_the_plain_error(dead):
    m, app = dead
    app.write("starting", reason="usb_reset", chain_epoch=2)
    app.later(0.2, lambda: os.unlink(app.devices))
    with pytest.raises(m.MCPToolError) as e:
        m.ios_screenshot()
    assert e.value.error_code is None


def test_a_retried_read_leaves_no_fail_step_in_the_run(fake, live):
    m, app = live
    m.ios_start_run("ride")
    port, url = int(fake.url.rsplit(":", 1)[1]), fake.url
    fake.stop()
    m._drop_conn(url)                           # its kept-alive socket too
    app.write("starting", reason="usb_reset", chain_epoch=2)
    back = FakeWDAServer()
    back.find_ids["OK"] = ["e1"]

    def come_back():
        back.start(port)
        app.write("ready", chain_epoch=2)
    app.later(0.3, come_back)
    try:
        assert m.ios_assert_visible("OK", timeout_s=0).startswith("PASS")
        assert not [s for s in m._run["steps"] if m._step_is_fail(s)]
    finally:
        m._drop_conn(back.url)
        back.stop()


def test_a_failed_ride_out_records_one_fail_step(dead, monkeypatch, tmp_path):
    m, app = dead
    monkeypatch.setattr(m, "_RIDE_OUT_S", 0.2)
    m._run.update(active=True, dir=str(tmp_path), steps=[], started=time.time())
    app.write("starting", reason="usb_reset", chain_epoch=2)
    with pytest.raises(m.MCPToolError):
        m.ios_assert_visible("OK", timeout_s=0)
    fails = [s for s in m._run["steps"] if m._step_is_fail(s)]
    assert len(fails) == 1
    assert fails[0]["verdict"]["error_code"] == "RECOVERING"


# ---- events in ios_status / ios_devices ------------------------------------------

def test_status_shows_the_apps_view_and_the_last_five_events(live):
    m, app = live
    app.write("ready", chain_epoch=4, state_since="2026-11-13T10:05:00Z")
    app.log(PHONE, "state", path=app.events + ".1", to="old")
    for i in range(7):
        app.log(PHONE, "state", ts=f"2026-11-13T10:00:0{i}.000Z", to=f"s{i}")
        app.log(OTHER, "restart")
    with open(app.events, "a") as f:
        f.write("not json\n{\"udid\": [1]}\n")
    out = json.loads(m.ios_status())
    assert out["app_state"] == "ready" and out["chain_epoch"] == 4
    assert out["state_since"] == "2026-11-13T10:05:00Z" and out["reason"] is None
    assert [e["to"] for e in out["events"]] == ["s2", "s3", "s4", "s5", "s6"]
    assert "udid" not in out["events"][0]


def test_events_fall_back_to_the_rotated_file(live):
    m, app = live
    app.log(PHONE, "give_up", path=app.events + ".1", reason="gave_up")
    app.log(PHONE, "auto_retry")
    events = m._recent_events({PHONE})[PHONE]
    assert [e["event"] for e in events] == ["give_up", "auto_retry"]


def test_events_are_read_from_the_end_of_a_big_file(live, monkeypatch):
    m, app = live
    monkeypatch.setattr(m, "_EVENTS_TAIL_BYTES", 4096)
    app.log(PHONE, "state", to="ancient")
    for _ in range(200):
        app.log(OTHER, "state", detail="x" * 40)
    app.log(PHONE, "usb_reset", expected=True)
    events = m._recent_events({PHONE})[PHONE]
    assert events == [{"ts": "2026-11-13T10:00:00.000Z", "event": "usb_reset",
                       "expected": True}]


def test_devices_lists_each_phones_reason_and_events(live, monkeypatch):
    m, app = live
    monkeypatch.setattr(m, "_probe_status", lambda t: {"wda_ready": False})
    app.write("down", reason="gave_up", next_retry_at="2026-11-13T10:10:00Z", chain_epoch=9)
    app.log(PHONE, "give_up")
    d = json.loads(m.ios_devices())["devices"][0]
    assert (d["app_state"], d["reason"], d["chain_epoch"], d["next_retry_at"]) == (
        "down", "gave_up", 9, "2026-11-13T10:10:00Z")
    assert [e["event"] for e in d["events"]] == ["give_up"]


# ---- ios_recover -----------------------------------------------------------------

def answer_request(app: App, detail: str, then=None) -> threading.Thread:
    """Wait for a restart request, consume it and log the answer, as the app does."""
    path = os.path.join(app.requests, f"restart-{PHONE}.json")
    seen: dict = {}

    def run():
        for _ in range(200):
            if os.path.exists(path):
                with open(path, encoding="utf-8") as f:
                    seen.update(json.load(f))
                os.unlink(path)
                app.log(PHONE, "request", ts=m_iso_now(), detail=detail)
                if then:
                    then()
                return
            time.sleep(0.02)
    th = threading.Thread(target=run, daemon=True)
    th.start()
    th.seen = seen  # type: ignore[attr-defined]
    return th


def m_iso_now() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z")


def test_recover_writes_a_request_and_waits_for_the_new_chain(live):
    m, app = live

    def restart():
        app.write("starting", reason="recovering", chain_epoch=2)
        app.later(0.2, app.write, "ready", chain_epoch=2)
    th = answer_request(app, "accepted", then=restart)
    out = json.loads(m.ios_recover())
    th.join(1)
    assert out["result"] == "accepted"
    assert out["app_state"] == "ready" and out["chain_epoch"] == 2
    assert th.seen["udid"] == PHONE and th.seen["requested_by"].startswith("imirror-mcp")
    assert th.seen["requested_at"].endswith("Z")


def test_recover_reports_a_cooldown_at_once(live):
    m, app = live
    answer_request(app, "cooldown")
    t0 = time.monotonic()
    out = json.loads(m.ios_recover())
    assert out["result"] == "cooldown" and time.monotonic() - t0 < 2


def test_recover_takes_the_first_answer_after_its_request(live):
    # A later cooldown answers another agent's request, not ours.
    m, app = live
    since = m._parse_iso("2026-11-13T10:00:00.000Z")
    app.log(PHONE, "request", ts="2026-11-13T10:00:00.000Z", detail="accepted")
    app.log(PHONE, "request", ts="2026-11-13T10:00:00.400Z", detail="cooldown")
    assert m._request_outcome(PHONE, since) == "accepted"


def test_recover_sees_an_answer_in_the_same_millisecond(live, monkeypatch):
    m, app = live
    monkeypatch.setattr(m, "_RECOVER_WAIT_S", 0.3)
    real = m.datetime

    class Clock(real):
        @classmethod
        def now(cls, tz=None):
            return real(2026, 11, 13, 10, 0, 0, 123999, tzinfo=tz)
    monkeypatch.setattr(m, "datetime", Clock)
    app.log(PHONE, "request", ts="2026-11-13T10:00:00.123Z", detail="cooldown")
    assert json.loads(m.ios_recover())["result"] == "cooldown"


@pytest.mark.parametrize("detail", ["not_attached", "stale"])
def test_recover_returns_at_once_when_the_app_restarts_nothing(live, detail):
    m, app = live
    answer_request(app, detail)
    t0 = time.monotonic()
    out = json.loads(m.ios_recover())
    assert out["result"] == detail and out["hint"]
    assert time.monotonic() - t0 < 2


def test_recover_ignores_an_answer_to_an_older_request(live, monkeypatch):
    m, app = live
    monkeypatch.setattr(m, "_RECOVER_WAIT_S", 0.3)
    app.log(PHONE, "request", ts="2020-01-01T00:00:00.000Z", detail="cooldown")
    out = json.loads(m.ios_recover())
    assert out["result"] == "timeout"


def test_recover_times_out_and_withdraws_an_unread_request(live, monkeypatch):
    m, app = live
    monkeypatch.setattr(m, "_RECOVER_WAIT_S", 0.3)
    out = json.loads(m.ios_recover())
    assert out["result"] == "timeout" and "older build" in out["hint"]
    assert os.listdir(app.requests) == []


def test_recover_needs_the_device_file(monkeypatch, tmp_path, fake):
    monkeypatch.setenv("IMIRROR_WDA", fake.url)
    monkeypatch.delenv("IMIRROR_UDID", raising=False)
    monkeypatch.setenv("IMIRROR_DEVICES_FILE", str(tmp_path / "devices.json"))
    sys.modules.pop("imirror_mcp", None)
    m = importlib.import_module("imirror_mcp")
    with pytest.raises(m.MCPToolError) as e:
        m.ios_recover()
    assert e.value.error_code == "DEVICE_FILE_INVALID"
