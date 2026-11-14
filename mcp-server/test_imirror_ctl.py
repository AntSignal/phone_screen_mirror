"""Unit tests for scripts/imirror-ctl. No app or phone: every shared file is
written to a temp dir and IMIRROR_DEVICES_FILE points the script at it."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import stat
from datetime import datetime, timedelta, timezone

import pytest

HERE = os.path.dirname(__file__)
_path = os.path.join(HERE, "..", "scripts", "imirror-ctl")
_loader = importlib.machinery.SourceFileLoader("imirror_ctl", _path)
_spec = importlib.util.spec_from_loader("imirror_ctl", _loader)
ctl = importlib.util.module_from_spec(_spec)
_loader.exec_module(ctl)

PHONE_16E = "00008140-0006423002D3401C"
PHONE_17 = "00008150-001928E01404401C"
SIM = "5B3C1F2A-0000-4000-8000-00000000A1B2"
NOW = datetime(2026, 11, 13, 10, 0, 0, tzinfo=timezone.utc)

DEVICES = [
    {"udid": PHONE_16E, "alias": "phone1", "kind": "device", "state": "ready", "chain_epoch": 3},
    {"udid": PHONE_17, "alias": "phone2", "kind": "device", "state": "down", "reason": "gave_up",
     "state_since": "2026-11-13T09:58:00Z", "chain_epoch": 1, "next_retry_at": "2026-11-13T10:02:00Z"},
    {"udid": SIM, "alias": "sim-17", "kind": "simulator", "state": "ready"},
]


@pytest.fixture
def app_dir(tmp_path, monkeypatch):
    path = tmp_path / "devices.json"
    write_devices(path, DEVICES)
    monkeypatch.setenv("IMIRROR_DEVICES_FILE", str(path))
    return tmp_path


def write_devices(path, devices, pid=None):
    path.write_text(json.dumps({"schema": 1, "owner_pid": pid or os.getpid(), "devices": devices}))


def ev(ts, udid, event, **kw):
    return json.dumps({"ts": ts, "udid": udid, "alias": "x", "event": event, **kw})


# ---- resolve: the MCP server's rules ----

def test_resolve_alias_udid_prefix_suffix():
    assert ctl.resolve("PHONE2", DEVICES)["udid"] == PHONE_17
    assert ctl.resolve(PHONE_16E.lower(), DEVICES)["alias"] == "phone1"
    assert ctl.resolve("00008150", DEVICES)["alias"] == "phone2"
    assert ctl.resolve("e01404401c", DEVICES)["alias"] == "phone2"


def test_resolve_refuses_a_suffix_two_phones_share():
    with pytest.raises(ctl.CtlError, match="several"):
        ctl.resolve("401C", DEVICES)


def test_resolve_refuses_short_or_unknown():
    with pytest.raises(ctl.CtlError, match="matches no device"):
        ctl.resolve("1C", DEVICES)
    with pytest.raises(ctl.CtlError, match="matches no device"):
        ctl.resolve("phone9", DEVICES)


# ---- since and events ----

def test_parse_since_units_and_iso():
    assert ctl.parse_since("90s", NOW) == NOW - timedelta(seconds=90)
    assert ctl.parse_since("1h", NOW) == NOW - timedelta(hours=1)
    assert ctl.parse_since("2d", NOW) == NOW - timedelta(days=2)
    assert ctl.parse_since("2026-11-13T09:00:00Z", NOW) == NOW - timedelta(hours=1)
    with pytest.raises(ctl.CtlError):
        ctl.parse_since("yesterday", NOW)


def test_read_events_old_file_first_skips_bad_lines_and_filters(tmp_path):
    (tmp_path / "events.jsonl.1").write_text(ev("2026-11-13T08:00:00.000Z", PHONE_17, "restart") + "\n")
    (tmp_path / "events.jsonl").write_text("\n".join([
        ev("2026-11-13T09:30:00.000Z", PHONE_16E, "state"),
        '{"ts": "cut off',
        ev("2026-11-13T09:40:00.000Z", PHONE_17, "give_up"),
    ]) + "\n")
    assert [e["event"] for e in ctl.read_events(str(tmp_path), PHONE_17)] == ["restart", "give_up"]
    since = NOW - timedelta(hours=1)
    assert [e["event"] for e in ctl.read_events(str(tmp_path), None, since)] == ["state", "give_up"]


def test_format_event_shows_transition_and_expected():
    line = ctl.format_event(json.loads(ev("t", PHONE_17, "state", **{"from": "ready", "to": "down",
                                                                      "reason": "usb_reset"})))
    assert "state ready -> down reason=usb_reset" in line
    assert ctl.format_event({"event": "usb_reset", "expected": True}).endswith("expected")


# ---- restart requests ----

def test_write_request_is_atomic_and_private(tmp_path):
    path = ctl.write_request(str(tmp_path), PHONE_17, NOW)
    assert os.path.basename(path) == f"restart-{PHONE_17}.json"
    body = json.loads(open(path).read())
    assert body == {"udid": PHONE_17, "requested_at": "2026-11-13T10:00:00.000Z",
                    "requested_by": "imirror-ctl"}
    assert os.listdir(tmp_path / "requests") == [os.path.basename(path)]
    assert stat.S_IMODE(os.stat(tmp_path / "requests").st_mode) == 0o700


def test_write_request_refuses_a_path_in_the_udid(tmp_path):
    with pytest.raises(ctl.CtlError):
        ctl.write_request(str(tmp_path), "../x", NOW)


def test_request_outcome_only_counts_answers_after_the_request():
    events = [json.loads(ev("2026-11-13T09:59:00.000Z", PHONE_17, "request", detail="accepted")),
              json.loads(ev("2026-11-13T10:00:00.500Z", PHONE_16E, "request", detail="cooldown"))]
    assert ctl.request_outcome(events, PHONE_17, NOW) is None
    events.append(json.loads(ev("2026-11-13T10:00:00.400Z", PHONE_17, "request", detail="cooldown")))
    assert ctl.request_outcome(events, PHONE_17, NOW) == "cooldown"


class FakeApp:
    """Plays the app: on the first wait it answers the request."""

    def __init__(self, folder, answer, bump=True):
        self.folder, self.answer, self.bump, self.t, self.calls = folder, answer, bump, 0.0, 0

    def clock(self):
        return self.t

    def sleep(self, s):
        self.t += s
        self.calls += 1
        if self.calls != 1 or self.answer is None:
            return
        req = self.folder / "requests" / f"restart-{PHONE_17}.json"
        assert req.exists(), "the request was written before waiting"
        req.unlink()
        with open(self.folder / "events.jsonl", "a") as f:
            f.write(ev(ctl.iso(NOW + timedelta(seconds=1)), PHONE_17, "request", detail=self.answer) + "\n")
        if self.bump:
            devs = [dict(d, chain_epoch=2) if d["udid"] == PHONE_17 else d for d in DEVICES]
            write_devices(self.folder / "devices.json", devs)


def run_restart(app_dir, fake):
    return ctl.restart(DEVICES[1], str(app_dir / "devices.json"), clock=fake.clock, sleep=fake.sleep, now=NOW)


def test_restart_accepted_once_the_epoch_moves(app_dir):
    result, latest = run_restart(app_dir, FakeApp(app_dir, "accepted"))
    assert result == "accepted"
    assert latest["chain_epoch"] == 2


def test_restart_reports_cooldown(app_dir):
    result, _ = run_restart(app_dir, FakeApp(app_dir, "cooldown", bump=False))
    assert result == "cooldown"


def test_restart_times_out_and_withdraws_the_request(app_dir):
    fake = FakeApp(app_dir, None)
    result, _ = run_restart(app_dir, fake)
    assert result == "timeout"
    assert fake.t >= ctl.RESTART_WAIT_S
    assert os.listdir(app_dir / "requests") == []


# ---- main ----

def test_status_one_device_prints_reason_and_events(app_dir, capsys):
    (app_dir / "events.jsonl").write_text(ev("2026-11-13T09:58:00.000Z", PHONE_17, "give_up") + "\n")
    assert ctl.main(["status", "phone2"]) == 0
    out = capsys.readouterr().out
    assert "gave_up" in out and "2026-11-13T10:02:00Z" in out and "give_up" in out


def test_status_all_lists_every_device(app_dir, capsys):
    assert ctl.main(["status"]) == 0
    out = capsys.readouterr().out
    assert "phone1" in out and "phone2" in out and "sim-17" in out


def test_restart_refuses_a_dead_app(app_dir, capsys):
    write_devices(app_dir / "devices.json", DEVICES, pid=999_999)
    assert ctl.main(["restart", "phone2"]) == 1
    assert not (app_dir / "requests").exists()


def test_restart_refuses_a_simulator(app_dir, capsys):
    assert ctl.main(["restart", "sim-17"]) == 1
    assert "Simulator" in capsys.readouterr().err
