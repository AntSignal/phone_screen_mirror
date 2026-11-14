"""A server whose client is gone exits instead of serving nobody.

These tests check the two ways a server now notices its client is
gone: stdin closing, and its parent pid changing.
"""
from __future__ import annotations

import importlib
import os
import subprocess
import sys
import threading
import time

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "imirror_mcp.py")


@pytest.fixture()
def m(monkeypatch):
    monkeypatch.setenv("IMIRROR_WDA", "http://127.0.0.1:8100")
    monkeypatch.delenv("IMIRROR_TARGET", raising=False)
    sys.modules.pop("imirror_mcp", None)
    return importlib.import_module("imirror_mcp")


def test_the_same_parent_and_an_open_stdin_keep_serving(m):
    assert m._exit_reason(100, 100, False) is None


def test_a_closed_stdin_exits(m):
    assert m._exit_reason(100, 100, True) == "stdin closed"


def test_a_new_parent_exits(m):
    assert m._exit_reason(100, 1, False) == "parent 100 is gone"


def test_launchd_as_the_parent_means_orphaned_already(m):
    # The parent died before the server noted its pid.
    assert m._exit_reason(1, 1, False) == "parent 1 is gone"


def _watch(m, fd, start_ppid):
    """Run the watcher on a thread; return the list it reports into."""
    reasons: list[str] = []
    t = threading.Thread(target=m._watch_client, daemon=True,
                         args=(fd, start_ppid, reasons.append, 0.05))
    t.start()
    return reasons, t


def test_unread_input_is_not_eof_and_is_not_consumed(m):
    r, w = os.pipe()
    try:
        reasons, t = _watch(m, r, os.getppid())
        os.write(w, b'{"jsonrpc":"2.0"}\n')
        time.sleep(0.3)
        assert reasons == []
        os.close(w)
        t.join(2)
        assert reasons == ["stdin closed"]
        # The watcher never read: FastMCP still gets the whole message.
        assert os.read(r, 100) == b'{"jsonrpc":"2.0"}\n'
    finally:
        os.close(r)


def test_a_changed_parent_is_noticed_with_stdin_still_open(m):
    r, w = os.pipe()
    try:
        reasons, t = _watch(m, r, os.getppid() + 1)
        t.join(2)
        assert reasons == [f"parent {os.getppid() + 1} is gone"]
    finally:
        os.close(r)
        os.close(w)


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def test_an_orphaned_server_exits_even_though_its_stdin_stays_open(tmp_path):
    """The real server, orphaned while this test holds its stdin open.

    That is the pile-up case: the client died but its pipe did not
    close, so the server never saw EOF and served nobody forever.
    """
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1",
               IMIRROR_WDA="http://127.0.0.1:8100",
               IMIRROR_DEVICES_FILE=str(tmp_path / "no-devices.json"),
               IMIRROR_RUNS_DIR=str(tmp_path / "runs"))
    env.pop("IMIRROR_AUTOWDA", None)
    log = tmp_path / "server.err"
    # The middle process starts the server, prints its pid, dies.
    middle = ("import subprocess, sys\n"
              "p = subprocess.Popen([sys.executable, sys.argv[1]],\n"
              "                     stdout=subprocess.DEVNULL,\n"
              "                     stderr=open(sys.argv[2], 'w'))\n"
              "print(p.pid)\n")
    r, w = os.pipe()
    try:
        out = subprocess.run([sys.executable, "-c", middle, SERVER, str(log)],
                             stdin=r, capture_output=True, text=True,
                             env=env, cwd=HERE, timeout=30, check=True)
        pid = int(out.stdout.strip())
        try:
            deadline = time.monotonic() + 15
            while _alive(pid) and time.monotonic() < deadline:
                time.sleep(0.1)
            assert not _alive(pid), "orphaned server is still running"
            assert "exiting, parent" in log.read_text()
        finally:
            if _alive(pid):
                os.kill(pid, 9)
    finally:
        os.close(r)
        os.close(w)
