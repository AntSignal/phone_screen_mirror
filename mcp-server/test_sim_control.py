"""Unit tests for sim_control: the headless switch for iMirror's Simulators.

No Xcode, no app and no real defaults: `defaults` and `xcrun simctl` are
stubbed by FakeShell, which keeps the enabled list in memory the way cfprefsd
would, and the device file is a temp file.
"""
from __future__ import annotations

import json
import os
import plistlib

import pytest

import sim_control as sc

SIM_A = "5B3C1F2A-0000-4000-8000-00000000A1B2"
SIM_B = "0F1E2D3C-1111-4222-8333-444455556666"
SIM_C = "ABCDEF01-2345-4678-9ABC-DEF012345678"

SIMCTL = {"devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-1": [
        {"udid": SIM_A, "name": "iPhone 17 Pro", "state": "Shutdown"},
        {"udid": SIM_C, "name": "iPhone 16e", "state": "Shutdown"},
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
        {"udid": SIM_B, "name": "iPhone 17 Pro", "state": "Booted"},
    ],
}}


class FakeShell:
    def __init__(self):
        self.prefs: dict = {}
        self.simctl = SIMCTL
        self.calls: list[list[str]] = []

    def __call__(self, args):
        self.calls.append(args)
        if args[:2] == ["defaults", "export"]:
            if not self.prefs:
                return 1, ""
            return 0, plistlib.dumps(self.prefs).decode()
        if args[:2] == ["defaults", "write"]:
            assert args[2] == sc.DOMAIN and args[4] == "-array"
            self.prefs[args[3]] = list(args[5:])
            return 0, ""
        if args[:3] == ["xcrun", "simctl", "list"]:
            return 0, json.dumps(self.simctl)
        raise AssertionError(f"unexpected command {args}")


@pytest.fixture()
def sh(monkeypatch, tmp_path):
    fake = FakeShell()
    monkeypatch.setattr(sc, "_run", fake)
    monkeypatch.setenv("IMIRROR_DEVICES_FILE", str(tmp_path / "devices.json"))
    return fake


def write_devices(devices, owner=None):
    doc = {"schema": 1, "owner_pid": os.getpid() if owner is None else owner,
           "devices": devices}
    with open(os.environ["IMIRROR_DEVICES_FILE"], "w") as f:
        json.dump(doc, f)


def sim_entry(udid, alias, port, state="ready", detail=None):
    return {"udid": udid, "alias": alias, "kind": "simulator", "state": state,
            "wda_url": f"http://127.0.0.1:{port}", **({"detail": detail} if detail else {})}


# ---- the list ---------------------------------------------------------------------

def test_normalize_matches_the_apps_rule():
    assert sc.normalize([SIM_A.lower(), f" {SIM_B} ", SIM_A, "junk", 3]) == [SIM_A, SIM_B]
    assert sc.normalize(SIM_A) == [SIM_A]
    assert sc.normalize(None) == []


def test_enable_appends_and_keeps_order(sh):
    sh.prefs[sc.ENABLED_KEY] = [SIM_C]
    assert sc.enable([SIM_A.lower()]) == [SIM_A]
    assert sh.prefs[sc.ENABLED_KEY] == [SIM_C, SIM_A]
    sc.enable([SIM_C])                                   # already on: no duplicate
    assert sh.prefs[sc.ENABLED_KEY] == [SIM_C, SIM_A]


def test_enable_with_no_prefs_yet(sh):
    sc.enable(["iPhone 16e"])
    assert sh.prefs[sc.ENABLED_KEY] == [SIM_C]
    assert ["defaults", "write", sc.DOMAIN, sc.ENABLED_KEY, "-array", SIM_C] in sh.calls


def test_disable_removes_and_all_clears(sh):
    sh.prefs[sc.ENABLED_KEY] = [SIM_A, SIM_B, SIM_C]
    assert sc.disable([SIM_B]) == [SIM_B]
    assert sh.prefs[sc.ENABLED_KEY] == [SIM_A, SIM_C]
    assert sc.disable(["ALL"]) == [SIM_A, SIM_C]
    assert sh.prefs[sc.ENABLED_KEY] == []


def test_a_deleted_simulator_can_still_be_disabled(sh):
    gone = "11111111-2222-4333-8444-555555555555"
    sh.prefs[sc.ENABLED_KEY] = [gone, SIM_A]
    assert sc.disable([gone]) == [gone]
    assert sh.prefs[sc.ENABLED_KEY] == [SIM_A]


def test_an_unknown_udid_is_not_enabled(sh):
    with pytest.raises(sc.SimControlError, match="no available simulator"):
        sc.enable(["11111111-2222-4333-8444-555555555555"])
    assert sc.ENABLED_KEY not in sh.prefs


# ---- resolving names --------------------------------------------------------------

def test_resolve_by_name_alias_and_prefix(sh):
    sims = sc.list_simulators()
    assert sc.resolve("iphone 16E", sims, {}) == SIM_C
    assert sc.resolve("pro-max", sims, {SIM_A: {"alias": "pro-max", "index": 1}}) == SIM_A
    assert sc.resolve("abcdef01", sims, {}) == SIM_C
    assert sc.resolve("0f1e2d3c1111", sims, {}) == SIM_B          # dashes ignored


def test_a_shared_name_picks_the_booted_one(sh):
    assert sc.resolve("iPhone 17 Pro", sc.list_simulators(), {}) == SIM_B


def test_a_shared_name_with_none_booted_is_refused(sh):
    sh.simctl = json.loads(json.dumps(SIMCTL))
    for devs in sh.simctl["devices"].values():
        for d in devs:
            d["state"] = "Shutdown"
    with pytest.raises(sc.SimControlError, match="several simulators are named"):
        sc.resolve("iPhone 17 Pro", sc.list_simulators(), {})


def test_aliases_come_from_the_apps_slot_table(sh):
    table = {"entries": {SIM_A.lower(): {"index": 1, "alias": "iphone-17-pro"}}}
    sh.prefs[sc.SLOTS_KEY] = json.dumps(table).encode()
    assert sc.aliases() == {SIM_A: {"index": 1, "alias": "iphone-17-pro"}}
    assert sc.enable(["iphone-17-pro"]) == [SIM_A]


def test_short_or_unmatched_queries_are_refused(sh):
    sims = sc.list_simulators()
    with pytest.raises(sc.SimControlError, match="no simulator matches"):
        sc.resolve("abc", sims, {})
    with pytest.raises(sc.SimControlError, match="name a simulator"):
        sc.resolve("  ", sims, {})


def test_list_simulators_humanizes_runtimes_and_puts_booted_first(sh):
    sims = sc.list_simulators()
    assert sims[0] == {"udid": SIM_B, "name": "iPhone 17 Pro", "runtime": "iOS 27.0", "booted": True}
    assert {s["runtime"] for s in sims} == {"iOS 26.1", "iOS 27.0"}


# ---- what the app publishes -------------------------------------------------------

def test_status_joins_simctl_the_list_and_the_device_file(sh):
    sh.prefs[sc.ENABLED_KEY] = [SIM_A, "11111111-2222-4333-8444-555555555555"]
    write_devices([sim_entry(SIM_A, "iphone-17-pro", 8201, state="starting",
                             detail="building WebDriverAgent")])
    st = sc.status()
    assert st["app_running"] is True
    rows = {r["udid"]: r for r in st["simulators"]}
    assert rows[SIM_A]["enabled"] and rows[SIM_A]["alias"] == "iphone-17-pro"
    assert rows[SIM_A]["wda"] == "http://127.0.0.1:8201" and rows[SIM_A]["state"] == "starting"
    assert not rows[SIM_C]["enabled"] and rows[SIM_C]["state"] is None
    assert rows["11111111-2222-4333-8444-555555555555"]["name"] is None   # enabled, gone


def test_a_dead_apps_device_file_is_ignored(sh):
    write_devices([sim_entry(SIM_A, "iphone-17-pro", 8201)], owner=2 ** 22 + 12345)
    assert sc.published() == (False, {})


def test_wait_ready_returns_the_entry(sh):
    write_devices([sim_entry(SIM_A, "iphone-17-pro", 8201)])
    assert sc.wait_ready(SIM_A.lower(), timeout=0)["alias"] == "iphone-17-pro"


def test_wait_ready_times_out_with_the_apps_detail(sh):
    write_devices([sim_entry(SIM_A, "iphone-17-pro", 8201, state="starting",
                             detail="building WebDriverAgent")])
    with pytest.raises(sc.SimControlError, match="starting: building WebDriverAgent"):
        sc.wait_ready(SIM_A, timeout=0)


def test_wait_ready_fails_fast_without_the_app(sh):
    with pytest.raises(sc.SimControlError, match="isn't running"):
        sc.wait_ready(SIM_A, timeout=60)


# ---- CLI --------------------------------------------------------------------------

def test_cli_enable_disable_and_errors(sh, capsys):
    assert sc.main(["enable", "iPhone 16e"]) == 0
    assert sh.prefs[sc.ENABLED_KEY] == [SIM_C]
    assert sc.main(["disable", "iPhone 16e"]) == 0
    assert sh.prefs[sc.ENABLED_KEY] == []
    assert sc.main(["enable", "nope"]) == 1
    assert "no simulator matches 'nope'" in capsys.readouterr().err
    assert sc.main(["bogus"]) == 2
    assert sc.main([]) == 2


def test_cli_list_shows_alias_port_and_state(sh, capsys):
    sh.prefs[sc.ENABLED_KEY] = [SIM_A]
    write_devices([sim_entry(SIM_A, "iphone-17-pro", 8201)])
    assert sc.main(["list"]) == 0
    out = capsys.readouterr().out
    line = next(l for l in out.splitlines() if SIM_A in l)
    assert line.startswith("on ") and "[iphone-17-pro · :8201 · ready]" in line
    assert any(l.startswith("off") and SIM_C in l for l in out.splitlines())
