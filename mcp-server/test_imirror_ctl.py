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


# ---- keyboard ----

def test_keyboard_request_names_the_action_and_carries_no_passcode(tmp_path):
    path = ctl.write_keyboard_request(str(tmp_path), PHONE_16E, NOW, "test", "hello 123")
    assert os.path.basename(path) == f"keyboard-{PHONE_16E}.json"
    assert json.loads(open(path).read()) == {"udid": PHONE_16E, "requested_at": "2026-11-13T10:00:00.000Z",
                                             "requested_by": "imirror-ctl", "action": "test",
                                             "text": "hello 123"}
    pair = json.loads(open(ctl.write_keyboard_request(str(tmp_path), PHONE_16E, NOW, "pair")).read())
    assert pair["action"] == "pair" and "text" not in pair


@pytest.mark.parametrize("text", ["123456", "0000", "Hello", "hi!", "", "a" * 33, None,
                                  "a 1234", "x123456", "1a2b3c4d", "pin 12 34"])
def test_keyboard_test_text_refuses_digits_only_and_odd_text(tmp_path, text):
    with pytest.raises(ctl.CtlError):
        ctl.write_keyboard_request(str(tmp_path), PHONE_16E, NOW, "test", text)
    assert not (tmp_path / "requests").exists() or os.listdir(tmp_path / "requests") == []


@pytest.mark.parametrize("text", ["a", "hello 123", "1 a 2 b 3", "z" * 32])
def test_keyboard_test_text_allows_words_with_up_to_three_digits(tmp_path, text):
    path = ctl.write_keyboard_request(str(tmp_path), PHONE_16E, NOW, "test", text)
    assert json.loads(open(path).read())["text"] == text


def test_keyboard_pair_and_forget_take_no_text(tmp_path):
    with pytest.raises(ctl.CtlError, match="takes no text"):
        ctl.write_keyboard_request(str(tmp_path), PHONE_16E, NOW, "pair", "hello")
    with pytest.raises(ctl.CtlError, match="unknown"):
        ctl.write_keyboard_request(str(tmp_path), PHONE_16E, NOW, "passcode")


def test_keyboard_outcome_skips_links_other_phones_and_older_answers():
    events = [json.loads(ev("2026-11-13T09:59:00.000Z", PHONE_16E, "keyboard", detail="paired")),
              json.loads(ev("2026-11-13T10:00:01.000Z", PHONE_16E, "keyboard", detail="connected")),
              json.loads(ev("2026-11-13T10:00:01.000Z", PHONE_17, "keyboard", detail="paired")),
              json.loads(ev("2026-11-13T10:00:02.000Z", PHONE_16E, "request", detail="accepted"))]
    assert ctl.keyboard_outcome(events, PHONE_16E, NOW, "pair") is None
    events.append(json.loads(ev("2026-11-13T10:00:03.000Z", PHONE_16E, "keyboard", detail="timeout")))
    assert ctl.keyboard_outcome(events, PHONE_16E, NOW, "pair")["detail"] == "timeout"
    assert ctl.keyboard_outcome(events, PHONE_16E, NOW, "test") is None


class FakeKeyboardApp:
    """Plays the app: on the first wait it answers with `detail`."""

    def __init__(self, folder, **answer):
        self.folder, self.answer, self.t, self.calls = folder, answer, 0.0, 0

    def clock(self):
        return self.t

    def sleep(self, s):
        self.t += s
        self.calls += 1
        if self.calls != 1 or not self.answer:
            return
        (self.folder / "requests" / f"keyboard-{PHONE_16E}.json").unlink()
        with open(self.folder / "events.jsonl", "a") as f:
            f.write(ev(ctl.iso(NOW + timedelta(seconds=1)), PHONE_16E, "keyboard", detail="connected") + "\n")
            f.write(ev(ctl.iso(NOW + timedelta(seconds=2)), PHONE_16E, "keyboard", **self.answer) + "\n")


def test_keyboard_waits_for_the_answer(tmp_path):
    fake = FakeKeyboardApp(tmp_path, detail="typed_test", chars=9)
    answer = ctl.keyboard(PHONE_16E, str(tmp_path), "test", "hello 123", clock=fake.clock, sleep=fake.sleep,
                          now=NOW)
    assert answer["detail"] == "typed_test" and answer["chars"] == 9


def test_keyboard_pair_waits_past_the_apps_window_then_withdraws(tmp_path):
    fake = FakeKeyboardApp(tmp_path)
    assert ctl.keyboard(PHONE_16E, str(tmp_path), "pair", clock=fake.clock, sleep=fake.sleep, now=NOW) is None
    assert fake.t >= 130
    assert os.listdir(tmp_path / "requests") == []


def test_describe_keyboard_gives_counts_and_hints_never_text():
    line = ctl.describe_keyboard("phone1", {"detail": "typed_test", "chars": 9})
    assert line == "typed_test: phone1, 9 chars"
    assert "pair it first" in ctl.describe_keyboard("phone1", {"detail": "failed", "reason": "not_paired"})
    assert "older build" in ctl.describe_keyboard("phone1", None)


def test_keyboard_device_falls_back_to_a_paired_udid_off_usb():
    pairs = {"00008101-AAAA": {"central": "C", "paired_at": "t"}}
    assert ctl.keyboard_device("phone1", DEVICES, pairs)["udid"] == PHONE_16E
    assert ctl.keyboard_device("00008101-aaaa", DEVICES, pairs)["udid"] == "00008101-AAAA"
    with pytest.raises(ctl.CtlError):
        ctl.keyboard_device("phone9", DEVICES, pairs)


def test_keyboard_status_prints_the_tie_and_keyboard_events_only(app_dir, capsys):
    (app_dir / "keyboard-pairs.json").write_text(json.dumps(
        {PHONE_16E: {"central": "4F2C0D3A-0000-4000-8000-000000000001", "paired_at": "2026-11-13T09:00:00.000Z"}}))
    (app_dir / "events.jsonl").write_text("\n".join([
        ev("2026-11-13T09:00:00.000Z", PHONE_16E, "keyboard", detail="paired"),
        ev("2026-11-13T09:01:00.000Z", PHONE_16E, "wake"),
        ev("2026-11-13T09:02:00.000Z", PHONE_16E, "keyboard", detail="typed_test", chars=5),
    ]) + "\n")
    assert ctl.main(["keyboard", "status", "phone1"]) == 0
    out = capsys.readouterr().out
    assert "paired via this Mac, central 4F2C0D3A" in out
    assert "typed_test chars=5" in out and "wake" not in out


def test_keyboard_status_shows_the_dongle_transport_and_peer(app_dir, capsys):
    (app_dir / "keyboard-pairs.json").write_text(json.dumps(
        {PHONE_16E: {"transport": "dongle", "slot": "00008101aaaa", "peer": "4a:3b:2c:1d:0e:ff",
                     "paired_at": "2026-11-15T09:00:00.000Z"}}))
    (app_dir / "events.jsonl").write_text(
        ev("2026-11-15T09:00:00.000Z", PHONE_16E, "keyboard", detail="paired", transport="dongle") + "\n")
    assert ctl.main(["keyboard", "status", "phone1"]) == 0
    out = capsys.readouterr().out
    assert "paired via dongle, slot 00008101aaaa, peer 4a:3b:2c:1d:0e:ff" in out
    assert "detail=paired transport=dongle" in out
    assert ctl.main(["status", "phone1"]) == 0
    assert "keyboard      paired via dongle" in capsys.readouterr().out
    assert ctl.main(["status", "phone1", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["keyboard"]["peer"] == "4a:3b:2c:1d:0e:ff"


def test_describe_keyboard_hints_for_the_dongle():
    assert "plug it in" in ctl.describe_keyboard("phone1", {"detail": "failed", "reason": "dongle_unavailable",
                                                            "transport": "dongle"})


def test_keyboard_status_of_an_unpaired_phone(app_dir, capsys):
    assert ctl.main(["keyboard", "status", "phone2"]) == 0
    assert "not paired" in capsys.readouterr().out


def test_keyboard_refuses_a_simulator_and_a_dead_app(app_dir, capsys):
    assert ctl.main(["keyboard", "pair", "sim-17"]) == 1
    write_devices(app_dir / "devices.json", DEVICES, pid=999_999)
    assert ctl.main(["keyboard", "test", "phone1", "hello"]) == 1
    assert not (app_dir / "requests").exists()
