"""Wire-level tests: the MCP server talking real HTTP to a fake WDA.

The other suites replace `_req`, so they cannot see socket timeouts on a
reused keep-alive connection or how WDA's real error bodies are read. Here
the server's own `_http` and `_req` run against testsupport/fake_wda_server,
which answers with the bodies the vendored WDA builds. No device needed.
"""
from __future__ import annotations

import importlib
import json
import sys

import pytest

from testsupport.fake_wda_server import FakeWDAServer


@pytest.fixture()
def fake():
    server = FakeWDAServer().start()
    yield server
    server.stop()


@pytest.fixture()
def m(fake, monkeypatch, tmp_path):
    """A fresh module pinned to the fake WDA."""
    monkeypatch.setenv("IMIRROR_WDA", fake.url)
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path / "runs"))
    for var in ("IMIRROR_TARGET", "IMIRROR_DEFAULT_DEVICE", "IMIRROR_UDID"):
        monkeypatch.delenv(var, raising=False)
    sys.modules.pop("imirror_mcp", None)
    mod = importlib.import_module("imirror_mcp")
    yield mod
    mod._drop_conn(fake.url)


def test_a_tap_goes_over_one_kept_alive_connection(m, fake):
    m.ios_tap(10, 20)
    m.ios_tap(30, 40)
    assert fake.count("POST", f"/session/{fake.active}/actions") == 2
    assert fake.connections == 1
