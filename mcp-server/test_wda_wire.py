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


# ---- mcp-core-2: a reused socket must take each request's timeout -------------

def test_a_reused_socket_gets_the_longer_timeout_it_was_asked_for(m, fake):
    m._http("GET", "/status", None, 0.2)
    fake.delays["/source"] = [0.6]
    status, _ = m._http("GET", "/source", None, 2.0)
    assert status == 200
    assert fake.connections == 1               # same socket, new timeout


def test_a_reused_socket_gets_the_shorter_timeout_too(m, fake):
    m._http("GET", "/status", None, 2.0)
    fake.delays["/source"] = [0.6]
    with pytest.raises(TimeoutError):
        m._http("GET", "/source", None, 0.2)


def test_req_tree_ride_out_survives_the_probes_short_socket(m, fake, monkeypatch):
    """The first /source times out and drops its socket; the /status probe
    opens a new one at the PROBE tier; the retry reuses that socket and must
    wait the TREE tier, not the probe's."""
    monkeypatch.setattr(m, "_TIMEOUT_TREE", 0.5)
    monkeypatch.setattr(m, "_TIMEOUT_PROBE", 0.2)
    fake.delays["/source"] = [0.9, 0.3]
    code, j = m._req_tree("/source")
    assert code == 200 and "XCUIElementTypeApplication" in j["value"]
    assert fake.paths("GET") == ["/source", "/status", "/source"]
