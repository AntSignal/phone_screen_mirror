"""ios_install_app on a phone takes the Mac-wide devicectl.lock and leaves an
expected-reset note for iMirror, the same files antsignalctl uses.

Everything runs in a temp support folder (IMIRROR_DEVICES_FILE moves it), so
no test touches the real lock or the real app.
"""
from __future__ import annotations

import fcntl
import importlib
import json
import os
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone

import pytest

UDID = "00008140-001A2B3C4D5E801C"


def _load(monkeypatch, tmp_path, target=None, udid=UDID):
    monkeypatch.setenv("IMIRROR_WDA", "http://127.0.0.1:8100")
    monkeypatch.setenv("IMIRROR_DEVICES_FILE", str(tmp_path / "devices.json"))
    monkeypatch.setenv("IMIRROR_IOS_BIN", "/x/ios")
    if udid is None:
        monkeypatch.delenv("IMIRROR_UDID", raising=False)
    else:
        monkeypatch.setenv("IMIRROR_UDID", udid)
    if target:
        monkeypatch.setenv("IMIRROR_TARGET", target)
    else:
        monkeypatch.delenv("IMIRROR_TARGET", raising=False)
    sys.modules.pop("imirror_mcp", None)
    return importlib.import_module("imirror_mcp")


@pytest.fixture()
def m(monkeypatch, tmp_path):
    return _load(monkeypatch, tmp_path)


@pytest.fixture()
def ipa(tmp_path):
    p = tmp_path / "App.ipa"
    p.write_bytes(b"PK\x03\x04")
    return str(p)


def _lock_is_held(path) -> bool:
    """True when someone else holds the flock (a new fd conflicts)."""
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(fd)


def _note_path(tmp_path, udid=UDID):
    return tmp_path / "expected-resets" / f"{udid}.json"


def test_install_holds_the_mac_wide_lock_while_go_ios_runs(m, ipa, tmp_path, monkeypatch):
    lock = tmp_path / "devicectl.lock"
    seen = {}

    def fake_run(args, **kw):
        seen["held"] = _lock_is_held(lock)
        return subprocess.CompletedProcess(args, 0, "", "")

    monkeypatch.setattr(m.subprocess, "run", fake_run)
    m.ios_install_app(ipa)
    assert seen["held"] is True
    assert _lock_is_held(lock) is False           # released afterwards


def test_install_writes_the_expected_reset_note_first(m, ipa, tmp_path, monkeypatch):
    seen = {}

    def fake_run(args, **kw):
        with open(_note_path(tmp_path), encoding="utf-8") as f:
            seen["note"] = json.load(f)
        seen["at"] = datetime.now(timezone.utc)
        return subprocess.CompletedProcess(args, 0, "", "")

    monkeypatch.setattr(m.subprocess, "run", fake_run)
    m.ios_install_app(ipa)
    note = seen["note"]
    assert set(note) == {"until", "by"}
    assert note["by"] == "go-ios install"
    until = datetime.fromisoformat(note["until"].replace("Z", "+00:00"))
    ahead = until - seen["at"]
    assert timedelta(seconds=85) <= ahead <= timedelta(seconds=90)
    # Renamed into place: no temp file is left behind.
    assert os.listdir(tmp_path / "expected-resets") == [f"{UDID}.json"]


def test_note_is_renewed_after_a_failed_install(m, ipa, tmp_path, monkeypatch):
    """The reset can come after go-ios returns, even when it fails."""
    def boom(args, **kw):
        os.remove(_note_path(tmp_path))
        raise subprocess.CalledProcessError(1, args, stderr="device locked")

    monkeypatch.setattr(m.subprocess, "run", boom)
    with pytest.raises(RuntimeError, match="install failed: device locked"):
        m.ios_install_app(ipa)
    assert _note_path(tmp_path).exists()
    assert _lock_is_held(tmp_path / "devicectl.lock") is False


def test_install_waits_for_another_sessions_lock(m, ipa, tmp_path, monkeypatch):
    monkeypatch.setattr(m, "_INSTALL_LOCK_POLL_S", 0.01)
    ran = threading.Event()
    monkeypatch.setattr(m.subprocess, "run",
                        lambda args, **kw: ran.set() or subprocess.CompletedProcess(args, 0))
    fd = os.open(tmp_path / "devicectl.lock", os.O_CREAT | os.O_RDWR, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)                # another session installing
    worker = threading.Thread(target=m.ios_install_app, args=(ipa,))
    worker.start()
    try:
        assert not ran.wait(0.3)                  # held back by the lock
    finally:
        os.close(fd)
    worker.join(5)
    assert ran.is_set()


def test_install_goes_ahead_when_the_lock_never_frees(m, ipa, tmp_path, monkeypatch):
    monkeypatch.setattr(m, "_INSTALL_LOCK_PATIENCE_S", 0.05)
    monkeypatch.setattr(m, "_INSTALL_LOCK_POLL_S", 0.01)
    calls = []
    monkeypatch.setattr(m.subprocess, "run",
                        lambda args, **kw: calls.append(args) or subprocess.CompletedProcess(args, 0))
    fd = os.open(tmp_path / "devicectl.lock", os.O_CREAT | os.O_RDWR, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        start = time.monotonic()
        m.ios_install_app(ipa)
        assert time.monotonic() - start < 2
    finally:
        os.close(fd)
    assert len(calls) == 1


def test_unknown_phone_is_refused_before_the_lock_or_a_note(monkeypatch, tmp_path, ipa):
    """Without --udid go-ios installs on whichever phone it lists first."""
    m = _load(monkeypatch, tmp_path, udid=None)
    ran = []
    monkeypatch.setattr(m.subprocess, "run", lambda args, **kw: ran.append(args))
    with pytest.raises(m.MCPToolError) as e:
        m.ios_install_app(ipa)
    assert e.value.error_code == "DEVICE_UDID_UNKNOWN" and "IMIRROR_UDID" in str(e.value)
    assert ran == []
    assert not (tmp_path / "devicectl.lock").exists()
    assert not (tmp_path / "expected-resets").exists()


def test_a_udid_that_could_escape_the_folder_gets_no_note(m, tmp_path):
    m._write_expected_reset("../../evil")
    m._write_expected_reset("")
    assert not (tmp_path / "expected-resets").exists()


def test_simulator_install_takes_no_lock_and_writes_no_note(monkeypatch, tmp_path):
    m = _load(monkeypatch, tmp_path, target="simulator")
    app = tmp_path / "App.app"
    app.mkdir()
    monkeypatch.setattr(m, "_sim_udid", lambda: "SIM-UDID")
    seen = {}

    def fake_run(args, **kw):
        lock = tmp_path / "devicectl.lock"
        seen["held"] = lock.exists() and _lock_is_held(lock)
        return subprocess.CompletedProcess(args, 0, "", "")

    monkeypatch.setattr(m.subprocess, "run", fake_run)
    m.ios_install_app(str(app))
    assert seen["held"] is False
    assert not (tmp_path / "expected-resets").exists()


def test_note_body_is_pure_and_ninety_seconds_ahead(m):
    now = datetime(2026, 11, 14, 12, 0, 0, tzinfo=timezone.utc)
    assert m._expected_reset_note(now) == {"until": "2026-11-14T12:01:30.000Z",
                                           "by": "go-ios install"}
