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


# ---- mcp-core-1: read WDA's W3C 404s instead of resetting on every one --------

def test_a_miss_is_a_clean_miss_with_no_new_session(m, fake):
    """WDA answers a find that matches nothing with 404 "no such element".
    That is a miss, not a dead session: recreating there killed every other
    client's session on each poll."""
    assert "PASS" in m.ios_assert_not_visible("Nope", timeout_s=0)
    with pytest.raises(m.MCPToolError) as e:
        m.ios_wait_for("Nope", timeout_s=0.6)
    assert e.value.error_kind == m.ErrorKind.NOT_FOUND
    assert fake.count("POST", "/session") == 1


def test_a_stale_click_re_finds_once_and_clicks_the_new_element(m, fake):
    fake.find_ids["OK"] = ["e1", "e2"]
    fake.stale.add("e1")
    assert m.ios_find_and_tap("OK") == "tapped element 'OK'"
    sid = fake.active
    clicks = [p for p in fake.paths("POST") if p.endswith("/click")]
    assert clicks == [f"/session/{sid}/element/e1/click", f"/session/{sid}/element/e2/click"]
    assert fake.count("POST", "/session") == 1


def test_an_element_stale_twice_is_reported_not_retried(m, fake):
    fake.find_ids["OK"] = ["e1", "e2"]
    fake.stale.update({"e1", "e2"})
    with pytest.raises(m.MCPToolError) as e:
        m.ios_find_and_tap("OK")
    assert e.value.error_kind == m.ErrorKind.NOT_FOUND
    assert "stale" in str(e.value)
    assert len([p for p in fake.paths("POST") if p.endswith("/click")]) == 2


def test_wda_restarting_still_recreates_the_session(m, fake):
    m.ios_tap(1, 1)
    fake.restart()                              # its next reply: invalid session id
    m.ios_tap(2, 2)
    assert fake.count("POST", "/session") == 2
    assert fake.count("POST", f"/session/{fake.active}/actions") == 1


def test_an_unknown_command_raises_without_touching_the_session(m, fake):
    m.ios_tap(1, 1)
    with pytest.raises(m.MCPToolError) as e:
        m._session_post("/wda/foo", {})
    assert e.value.error_code == "WDA_HTTP_404"
    assert "unknown command" in str(e.value)
    assert "WebDriverAgentLib" not in str(e.value)   # no stack dump
    assert fake.count("POST", "/session") == 1


def test_a_bad_selector_fails_the_wait_at_once(m, fake):
    """Any other 4xx is a real error. It used to read as "not found" and
    burn the whole wait."""
    fake.fail_next("POST", "/element", 400, "invalid selector", "bad predicate")
    with pytest.raises(m.MCPToolError) as e:
        m.ios_wait_for("OK", timeout_s=5)
    assert e.value.error_code == "WDA_HTTP_400"
    assert "invalid selector: bad predicate" in str(e.value)


def test_a_wda_timeout_on_a_find_keeps_the_poll_going(m, fake):
    """WDA's own 408 "timeout" is slowness: poll loops ride it out like a
    socket timeout instead of failing the wait."""
    fake.find_ids["OK"] = ["e1"]
    fake.fail_next("POST", "/element", 408, "timeout", "snapshot timed out")
    assert "found 'OK' after 2 check(s)" == m.ios_wait_for("OK", timeout_s=5)
