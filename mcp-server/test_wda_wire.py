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


def test_a_socket_wda_closed_while_idle_is_replaced_quietly(m, fake):
    """CocoaHTTPServer drops a kept-alive socket after 30 s idle without
    saying so; the next request on it must reconnect, not fail."""
    m._http("GET", "/status", None, 2.0)
    fake.close_after = 1                        # the next reply, then hang up
    assert m._req("GET", "/status")[0] == 200
    assert m._req("GET", "/status")[0] == 200
    assert fake.connections == 2


def test_a_read_cut_off_mid_reply_is_retried(m, fake):
    fake.drops["/source"] = 1
    code, j = m._req("GET", "/source")
    assert code == 200 and "XCUIElementTypeApplication" in j["value"]
    assert fake.paths("GET") == ["/source", "/source"]


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


# ---- mcp-core-4: adopt the phone's session; never steal one to read ----------

def test_a_fresh_server_adopts_the_session_already_on_the_phone(m, fake):
    """WDA keeps one session per phone and POST /session kills it. A new
    server joins the session another client (the iMirror app's mirror,
    another agent) already has, and re-applies its settings there."""
    theirs = fake.new_session()
    fake.find_ids["OK"] = ["e1"]
    m.ios_wait_for("OK", timeout_s=1)
    assert fake.count("POST", "/session") == 0
    assert fake.count("POST", f"/session/{theirs}/element") == 1
    assert fake.settings["waitForIdleTimeout"] == 0
    assert fake.settings["screenshotQuality"] == 1


def test_screenshot_and_window_size_never_create_a_session(m, fake):
    m.ios_screenshot()
    assert json.loads(m.ios_window_size()) == fake.window
    m._win_size()
    assert fake.count("POST", "/session") == 0
    assert fake.paths("GET").count("/window/size") == 2       # sessionless route


def test_a_screenshot_applies_its_quality_through_an_active_session(m, fake):
    fake.new_session()
    m.ios_screenshot()
    assert fake.count("POST", "/session") == 0
    assert fake.settings["screenshotQuality"] == 1


def test_a_session_taken_once_by_another_client_is_adopted(m, fake):
    m.ios_tap(1, 1)
    theirs = fake.new_session()
    m.ios_tap(2, 2)
    assert fake.count("POST", f"/session/{theirs}/actions") == 1
    assert fake.count("POST", "/session") == 1                # only the first
    session = json.loads(m.ios_devices())["devices"][0]["session"]
    assert session == {"cached": True, "created": 1, "adopted": 1, "lost": 1}


def test_two_lost_sessions_within_a_minute_raise_session_contested(m, fake):
    m.ios_tap(1, 1)
    fake.new_session()
    m.ios_tap(2, 2)
    last = fake.new_session()
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(3, 3)
    assert e.value.error_code == "SESSION_CONTESTED"
    assert "another client on this phone" in str(e.value)
    assert fake.count("POST", f"/session/{last}/actions") == 0   # tap not sent
    assert fake.count("POST", "/session") == 1                   # and no fight


def test_wda_restarting_twice_in_a_minute_is_not_a_contest(m, fake):
    """A restart leaves no session on the phone, so nobody took ours.
    iMirror's recovery can restart WDA twice in a minute; the second
    restart used to fail the call as SESSION_CONTESTED."""
    m.ios_tap(1, 1)
    fake.restart()
    m.ios_tap(2, 2)
    fake.restart()
    m.ios_tap(3, 3)
    assert fake.count("POST", "/session") == 3
    assert fake.count("POST", f"/session/{fake.active}/actions") == 1


def test_a_takeover_after_a_restart_is_still_adopted(m, fake):
    m.ios_tap(1, 1)
    fake.restart()
    m.ios_tap(2, 2)
    theirs = fake.new_session()
    m.ios_tap(3, 3)
    assert fake.count("POST", f"/session/{theirs}/actions") == 1


def test_lost_sessions_a_minute_apart_are_just_adopted(m, fake, monkeypatch):
    import time
    monkeypatch.setattr(m, "_SESSION_CONTEST_WINDOW_S", 0.2)
    m.ios_tap(1, 1)
    fake.new_session()
    m.ios_tap(2, 2)
    time.sleep(0.3)
    last = fake.new_session()
    m.ios_tap(3, 3)
    assert fake.count("POST", f"/session/{last}/actions") == 1


def test_a_session_lost_twice_in_one_call_raises_session_contested(m, fake):
    m.ios_tap(1, 1)
    for _ in range(2):
        fake.fail_next("POST", "/actions", 404, "invalid session id",
                       "Session does not exist")
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(2, 2)
    assert e.value.error_code == "SESSION_CONTESTED"
    assert fake.count("POST", "/session") == 1


def test_without_leave_to_adopt_a_taken_session_raises_session_stolen(m, fake, monkeypatch):
    """The hook the device lease will use: an agent that does not hold the
    phone must not quietly drive inside another client's session."""
    m.ios_tap(1, 1)
    theirs = fake.new_session()
    asked = []
    monkeypatch.setattr(m, "_may_adopt_foreign", lambda t, why: asked.append(why))
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(2, 2)
    assert e.value.error_code == "SESSION_STOLEN"
    assert fake.count("POST", f"/session/{theirs}/actions") == 0
    assert fake.count("POST", "/session") == 1
    m.ios_screenshot()                          # observing still works
    assert fake.active == theirs
    assert asked == ["lost", "status"]


def test_without_leave_to_adopt_a_fresh_server_refuses_too(m, fake, monkeypatch):
    theirs = fake.new_session()
    monkeypatch.setattr(m, "_may_adopt_foreign", lambda t, why: why != "status")
    with pytest.raises(m.MCPToolError) as e:
        m.ios_tap(1, 1)
    assert e.value.error_code == "SESSION_STOLEN"
    assert fake.count("POST", "/session") == 0 and fake.active == theirs


# ---- mcp-tools-6: the JSON source probe must not hide a stalled WDA -----------

def test_a_stalled_json_source_raises_instead_of_reading_xml_too(m, fake, monkeypatch):
    """Swallowing the JSON probe's timeout and then reading XML doubled the
    wait on a stalled WDA (up to ~245 s at the real tiers) before failing."""
    monkeypatch.setattr(m, "_TIMEOUT_TREE", 0.3)
    monkeypatch.setattr(m, "_TIMEOUT_PROBE", 0.2)
    fake.delays["/source"] = [0.6, 0.6]
    with pytest.raises(m.MCPToolError) as e:
        m.ios_source()
    assert e.value.error_kind == m.ErrorKind.WEDGED
    assert "/source" not in fake.paths("GET")        # no XML read after it


def test_json_source_unsupported_is_remembered(m, fake):
    fake.json_source = False                          # this build: a 400
    m.ios_source()
    m.ios_source()
    assert fake.paths("GET").count("/source?format=json") == 1
    assert fake.paths("GET").count("/source") == 2


def test_a_non_json_reply_to_the_json_probe_falls_back_to_xml(m, fake, monkeypatch):
    real = m._req_tree

    def not_json(path):
        if path == "/source?format=json":
            raise json.JSONDecodeError("Expecting value", "<html>", 0)
        return real(path)
    monkeypatch.setattr(m, "_req_tree", not_json)
    assert 'label="OK"' in m.ios_source()
    assert m._LEGACY.json_source is False


# ---- which server answered -----------------------------------------------------

def test_status_and_devices_name_the_server_and_its_file(m, fake):
    """A session can then spot a server running from a stale or dev tree."""
    import os
    want = {"server_version": m.__version__, "script_path": os.path.realpath(m.__file__)}
    status = json.loads(m.ios_status())
    devices = json.loads(m.ios_devices())
    assert {k: status.get(k) for k in want} == want
    assert {k: devices.get(k) for k in want} == want
    assert want["script_path"].endswith("/imirror_mcp.py")
