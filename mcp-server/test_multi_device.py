"""Unit tests for driving several devices from one imirror MCP server.

No device or WebDriverAgent needed: the iMirror app's device file is written to
a temp dir, and every WDA call is stubbed by RoutedWDA, which records which
device each request was meant for. The UDIDs are the two real test phones',
which both end in 401C — exactly the collision the resolver must refuse to
guess about.
"""
from __future__ import annotations

import base64
import importlib
import itertools
import json
import os
import subprocess
import sys
import threading
import time

import anyio
import pytest

PHONE_16E = "00008140-0006423002D3401C"
PHONE_17 = "00008150-001928E01404401C"
SIM = "5B3C1F2A-0000-4000-8000-00000000A1B2"
PNG = b"\x89PNG\r\n\x1a\nfake"
SAMPLE = os.path.join(os.path.dirname(__file__), "testdata", "devices.sample.json")

# Tools that are about the run or the server, not a device, take no `device`.
NO_DEVICE_TOOLS = {"ios_run_note", "ios_run_section", "ios_finish_run", "ios_devices"}


def entry(udid: str, alias: str, kind: str = "device", port: int = 8100, **extra) -> dict:
    return {"udid": udid, "alias": alias, "kind": kind,
            "wda_url": f"http://127.0.0.1:{port}", "state": "ready", **extra}


TWO_PHONES = [entry(PHONE_16E, "phone1", port=8100, product_type="iPhone17,5"),
              entry(PHONE_17, "phone2", port=8110, product_type="iPhone18,3")]
PHONE_AND_SIM = [entry(PHONE_16E, "phone1", port=8100),
                 entry(SIM, "sim", kind="simulator", port=8201)]


def write_devices(path, devices, owner_pid=None, schema=1, raw: str | None = None) -> None:
    """Write the device file the way the app does: a whole new file swapped in
    atomically, so the server sees a new inode/mtime on every rewrite."""
    doc = {"schema": schema, "owner_pid": os.getpid() if owner_pid is None else owner_pid,
           "app_version": "test", "updated_at": "2026-09-28T00:00:00Z",
           "goios": "", "devices": devices}
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(raw if raw is not None else json.dumps(doc))
    os.replace(tmp, path)


class Reg:
    def __init__(self, m, path):
        self.m, self.path = m, path

    def write(self, devices, **kw):
        write_devices(self.path, devices, **kw)


@pytest.fixture()
def reg(monkeypatch, tmp_path):
    """A fresh module in list mode (no IMIRROR_WDA) reading a temp device file
    that lists the two real phones."""
    for var in ("IMIRROR_WDA", "IMIRROR_TARGET", "IMIRROR_DEFAULT_DEVICE", "IMIRROR_UDID",
                "IMIRROR_IOS_BIN"):
        monkeypatch.delenv(var, raising=False)
    path = str(tmp_path / "devices.json")
    monkeypatch.setenv("IMIRROR_DEVICES_FILE", path)
    monkeypatch.setenv("IMIRROR_RUNS_DIR", str(tmp_path / "runs"))
    sys.modules.pop("imirror_mcp", None)
    m = importlib.import_module("imirror_mcp")
    r = Reg(m, path)
    r.write(TWO_PHONES)
    return r


class RoutedWDA:
    """Stands in for _req. Answers like WDA would and records, for every
    request, the alias of the device the server was driving when it sent it."""

    def __init__(self, m):
        self.m = m
        self.calls: list[tuple[str, str, str]] = []
        self.lock = threading.Lock()
        self.ids = itertools.count(1)
        self.sleep: dict[str, float] = {}          # path suffix -> seconds
        self.fail_once: dict[tuple[str, str], int] = {}  # (alias, suffix) -> status

    def __call__(self, method, path, body=None, timeout=None):
        alias = self.m._cur().alias
        with self.lock:
            self.calls.append((alias, method, path))
        for suffix, secs in self.sleep.items():
            if path.endswith(suffix):
                time.sleep(secs)
        for (a, suffix), status in list(self.fail_once.items()):
            if a == alias and path.endswith(suffix):
                del self.fail_once[(a, suffix)]
                return status, {"value": "no such session"}
        if path == "/session":
            return 200, {"value": {"sessionId": f"{alias}-s{next(self.ids)}"}}
        if path == "/status":
            return 200, {"value": {"ready": True, "os": {"version": "26.6"},
                                   "device": "iphone"}}
        if path.endswith("/window/size"):
            return 200, {"value": {"width": 400, "height": 800}}
        if path == "/screenshot":
            return 200, {"value": base64.b64encode(PNG).decode()}
        return 200, {"value": {}}

    def aliases_for(self, suffix: str) -> list[str]:
        return [a for a, _, p in self.calls if p.endswith(suffix)]


@pytest.fixture()
def wda(reg, monkeypatch):
    fake = RoutedWDA(reg.m)
    monkeypatch.setattr(reg.m, "_req", fake)
    return fake


def tool_schemas(m) -> dict[str, dict]:
    return {t.name: t.inputSchema for t in anyio.run(m.mcp.list_tools)}


def dead_pid() -> int:
    p = subprocess.Popen(["true"])
    p.wait()
    return p.pid


# ---- the `device` argument in the tool schema -------------------------------------

def test_every_device_tool_takes_an_optional_device(reg):
    schemas = tool_schemas(reg.m)
    for name, schema in schemas.items():
        props, required = schema.get("properties", {}), schema.get("required", [])
        if name in NO_DEVICE_TOOLS:
            assert "device" not in props, name
        else:
            assert props["device"]["type"] == "string", name
            assert props["device"].get("default") == "", name
            assert "device" not in required, name
            assert "ios_devices" in props["device"]["description"], name


def test_tool_names_and_required_params_are_unchanged(reg):
    """Guards against the decorator swap quietly renaming a tool or making an
    argument required. `device` is the only new argument anywhere."""
    expected = {
        "ios_status": [], "ios_devices": [], "ios_window_size": [], "ios_screenshot": [],
        "ios_source": [], "ios_await_idle": [], "ios_tap": ["x", "y"],
        "ios_swipe": ["from_x", "from_y", "to_x", "to_y"], "ios_scroll": ["direction"],
        "ios_scroll_to": ["text"], "ios_type": ["text"], "ios_press_button": [],
        "ios_find_and_tap": ["text"], "ios_wait_for": ["text"], "ios_orientation": [],
        "ios_launch_app": ["bundle_id"], "ios_terminate_app": ["bundle_id"],
        "ios_activate_app": ["bundle_id"], "ios_app_state": ["bundle_id"],
        "ios_open_url": ["url"], "ios_clipboard_set": ["text"], "ios_clipboard_get": [],
        "ios_install_app": ["path"], "sim_push": ["bundle_id", "payload_json"],
        "sim_privacy": ["action", "service"], "sim_status_bar": [],
        "ios_start_run": [], "ios_run_note": ["text"], "ios_run_section": ["title"],
        "ios_finish_run": [], "ios_assert_visible": ["text"],
        "ios_assert_not_visible": ["text"], "ios_run_sequence": ["steps"],
    }
    got = {n: sorted(s.get("required", [])) for n, s in tool_schemas(reg.m).items()}
    assert got == {n: sorted(r) for n, r in expected.items()}


# ---- resolving `device` -----------------------------------------------------------

@pytest.mark.parametrize("query,alias", [
    ("phone2", "phone2"), ("PHONE1", "phone1"),      # alias, any case
    (PHONE_17, "phone2"), (PHONE_16E.lower(), "phone1"),  # full UDID
    ("00008140", "phone1"), ("000081500019", "phone2"),  # unique prefix, dashes ignored
    ("3401C", "phone1"), ("E01404401c", "phone2"),       # unique suffix
])
def test_device_resolves_by_alias_udid_prefix_or_suffix(reg, query, alias):
    assert reg.m._resolve(query).alias == alias


def test_suffix_shared_by_both_phones_is_refused(reg):
    with pytest.raises(reg.m.MCPToolError) as e:
        reg.m._resolve("401C")
    assert e.value.error_code == "DEVICE_AMBIGUOUS"
    assert "phone1" in str(e.value) and "phone2" in str(e.value)


def test_unknown_device_lists_the_choices(reg):
    with pytest.raises(reg.m.MCPToolError) as e:
        reg.m._resolve("ipad")
    assert e.value.error_code == "DEVICE_UNKNOWN"
    assert "phone1 (iPhone17,5" in str(e.value) and "phone2 (iPhone18,3" in str(e.value)


def test_short_fragments_do_not_match(reg):
    with pytest.raises(reg.m.MCPToolError, match="matches no device"):
        reg.m._resolve("401")


def test_omitting_device_with_two_phones_fails_closed(reg, wda):
    with pytest.raises(reg.m.MCPToolError) as e:
        reg.m.ios_tap(1, 2)
    assert e.value.error_code == "DEVICE_REQUIRED"
    assert "phone1" in str(e.value) and "phone2" in str(e.value)
    assert wda.calls == []                      # nothing was sent to either phone


def test_default_device_env_pins_the_omitted_device(reg, wda, monkeypatch):
    monkeypatch.setenv("IMIRROR_DEFAULT_DEVICE", PHONE_17)
    reg.m.ios_tap(1, 2)
    assert wda.aliases_for("/actions") == ["phone2"]


def test_unknown_default_device_env_never_falls_back(reg, wda, monkeypatch):
    monkeypatch.setenv("IMIRROR_DEFAULT_DEVICE", "phone9")
    with pytest.raises(reg.m.MCPToolError, match="IMIRROR_DEFAULT_DEVICE='phone9'"):
        reg.m.ios_tap(1, 2)
    assert wda.calls == []


def test_simulator_beside_one_phone_does_not_make_calls_ambiguous(reg, wda):
    reg.write(PHONE_AND_SIM)
    reg.m.ios_tap(1, 2)
    assert wda.aliases_for("/actions") == ["phone1"]


def test_sim_tools_default_to_the_simulator(reg, monkeypatch):
    reg.write(PHONE_AND_SIM)
    seen = {}

    class R:
        stdout = ""
    monkeypatch.setattr(reg.m.subprocess, "run",
                        lambda args, **kw: seen.setdefault("args", args) and R())
    reg.m.sim_status_bar(clear=True)
    assert seen["args"] == ["xcrun", "simctl", "status_bar", SIM, "clear"]


def test_sim_tools_refuse_a_physical_phone(reg):
    reg.write(PHONE_AND_SIM)
    with pytest.raises(RuntimeError, match="phone1 is a physical device"):
        reg.m.sim_status_bar(clear=True, device="phone1")


def test_no_devices_listed_says_so(reg, wda):
    reg.write([])
    with pytest.raises(reg.m.MCPToolError) as e:
        reg.m.ios_tap(1, 2)
    assert e.value.error_code == "NO_DEVICES"


# ---- trusting the device file -----------------------------------------------------

def test_valid_file_means_list_mode(reg):
    mode, targets = reg.m._targets()
    assert mode == "list" and [t.alias for t in targets] == ["phone1", "phone2"]


@pytest.mark.parametrize("bad", ["dead-owner", "bad-json", "wrong-schema", "missing"])
def test_untrustworthy_file_falls_back_to_8100(reg, bad):
    if bad == "dead-owner":
        reg.write(TWO_PHONES, owner_pid=dead_pid())
    elif bad == "bad-json":
        reg.write(TWO_PHONES, raw="{not json")
    elif bad == "wrong-schema":
        reg.write(TWO_PHONES, schema=2)
    else:
        os.remove(reg.path)
    mode, targets = reg.m._targets()
    assert mode == "fallback"
    assert targets == [reg.m._LEGACY] and reg.m._LEGACY.wda == "http://127.0.0.1:8100"


def test_owner_dying_after_the_file_was_read_is_noticed(reg, monkeypatch):
    assert reg.m._targets()[0] == "list"
    monkeypatch.setattr(reg.m, "_pid_alive", lambda pid: False)
    assert reg.m._targets()[0] == "fallback"


def test_non_loopback_entry_is_dropped(reg):
    evil = entry(PHONE_17, "phone2")
    evil["wda_url"] = "http://10.0.0.5:8110"
    reg.write([TWO_PHONES[0], evil])
    assert [t.alias for t in reg.m._targets()[1]] == ["phone1"]


def test_malformed_entries_are_dropped(reg):
    reg.write([TWO_PHONES[0], {"udid": PHONE_17}, "junk",
               entry(SIM, "sim", kind="watch", port=8201)])
    assert [t.alias for t in reg.m._targets()[1]] == ["phone1"]


def test_rewrite_keeps_sessions_and_a_port_change_drops_them(reg):
    t = reg.m._resolve("phone1")
    t.session["id"] = "live"
    moved = [dict(TWO_PHONES[0], state="down"), TWO_PHONES[1]]
    reg.write(moved)
    again = reg.m._resolve("phone1")
    assert again is t and t.session["id"] == "live" and t.state == "down"
    reg.write([dict(TWO_PHONES[0], wda_url="http://127.0.0.1:8120"), TWO_PHONES[1]])
    assert reg.m._resolve("phone1").session["id"] is None
    assert reg.m._resolve("phone1").wda == "http://127.0.0.1:8120"


def test_pinned_mode_ignores_the_file_and_rejects_other_devices(monkeypatch, tmp_path):
    path = str(tmp_path / "devices.json")
    write_devices(path, TWO_PHONES)
    monkeypatch.setenv("IMIRROR_DEVICES_FILE", path)
    monkeypatch.setenv("IMIRROR_WDA", "http://127.0.0.1:8201")
    sys.modules.pop("imirror_mcp", None)
    m = importlib.import_module("imirror_mcp")
    assert m._targets() == ("pinned", [m._LEGACY])
    with pytest.raises(m.MCPToolError, match="pinned to one target by IMIRROR_WDA"):
        m.ios_tap(1, 2, device="phone2")


def test_golden_sample_decodes(reg):
    """The same file the Swift encoder test produces byte-for-byte."""
    with open(SAMPLE, encoding="utf-8") as f:
        doc = json.load(f)
    doc["owner_pid"] = os.getpid()
    reg.write([], raw=json.dumps(doc))
    mode, targets = reg.m._targets()
    assert mode == "list"
    got = [(t.alias, t.udid, t.kind, t.wda, t.product_type, t.ios_version, t.state)
           for t in targets]
    assert got == [
        ("phone1", PHONE_16E, "device", "http://127.0.0.1:8100", "iPhone17,5", "26.6", "ready"),
        ("phone2", PHONE_17, "device", "http://127.0.0.1:8110", "iPhone18,3", "26.6", "starting"),
        ("sim", SIM, "simulator", "http://127.0.0.1:8201", "iPhone 17 Pro", "26.0", "ready"),
    ]
    assert targets[1].detail == "waiting for WebDriverAgent"


# ---- per-phone state --------------------------------------------------------------

def test_each_phone_gets_its_own_session(reg, wda):
    reg.m.ios_tap(1, 2, device="phone1")
    reg.m.ios_tap(1, 2, device="phone2")
    reg.m.ios_tap(3, 4, device="phone1")
    assert wda.aliases_for("/session") == ["phone1", "phone2"]
    assert reg.m._resolve("phone1").session["id"].startswith("phone1-")
    assert reg.m._resolve("phone2").session["id"].startswith("phone2-")


def test_stale_session_on_one_phone_leaves_the_other_alone(reg, wda):
    reg.m.ios_tap(1, 2, device="phone1")
    reg.m.ios_tap(1, 2, device="phone2")
    phone2_session = reg.m._resolve("phone2").session["id"]
    wda.fail_once[("phone1", "/actions")] = 404
    reg.m.ios_tap(1, 2, device="phone1")
    assert wda.aliases_for("/session") == ["phone1", "phone2", "phone1"]
    assert reg.m._resolve("phone2").session["id"] == phone2_session


def test_window_size_is_cached_per_phone(reg, wda):
    reg.m.ios_scroll("down", device="phone1")
    reg.m.ios_scroll("down", device="phone2")
    reg.m.ios_scroll("down", device="phone1")
    assert wda.aliases_for("/window/size") == ["phone1", "phone2"]


def test_connections_are_kept_per_phone(reg, monkeypatch):
    opened = []

    class FakeConn:
        def __init__(self, host, port, timeout=None):
            opened.append(port)
            self.timeout = timeout

        def request(self, *a, **k):
            pass

        def getresponse(self):
            class R:
                status = 200
                def read(self_inner): return b"{}"
            return R()

        def close(self):
            pass

    monkeypatch.setattr(reg.m.http.client, "HTTPConnection", FakeConn)
    for alias in ("phone1", "phone2", "phone1", "phone2"):
        token = reg.m._current.set(reg.m._resolve(alias))
        try:
            reg.m._http("GET", "/status", None, 5)
        finally:
            reg.m._current.reset(token)
    assert opened == [8100, 8110]               # one connection each, then reused


def test_install_targets_the_phone_by_udid(reg, monkeypatch, tmp_path):
    ipa = tmp_path / "App.ipa"
    ipa.write_bytes(b"ipa")
    seen = {}
    monkeypatch.setenv("IMIRROR_IOS_BIN", "/x/ios")
    monkeypatch.setattr(reg.m.subprocess, "run",
                        lambda args, **kw: seen.setdefault("args", args))
    reg.m.ios_install_app(str(ipa), device="phone2")
    assert seen["args"] == ["/x/ios", "install", f"--path={ipa}", f"--udid={PHONE_17}"]


def test_ios_bin_comes_from_the_device_file(reg, monkeypatch, tmp_path):
    goios = tmp_path / "ios"
    goios.write_text("")
    with open(SAMPLE, encoding="utf-8") as f:
        doc = json.load(f)
    doc.update(owner_pid=os.getpid(), goios=str(goios))
    reg.write([], raw=json.dumps(doc))
    assert reg.m._ios_bin() == str(goios)


def test_status_names_the_phone_in_list_mode(reg, wda):
    out = json.loads(reg.m.ios_status(device="phone2"))
    assert out["alias"] == "phone2" and out["udid"] == PHONE_17 and out["ready"] is True


# ---- parallel across phones, in order on one phone --------------------------------

def _timed_pair(m, first: dict, second: dict) -> float:
    async def both():
        async with anyio.create_task_group() as tg:
            tg.start_soon(m.mcp.call_tool, "ios_tap", first)
            tg.start_soon(m.mcp.call_tool, "ios_tap", second)
    start = time.monotonic()
    anyio.run(both)
    return time.monotonic() - start


def test_two_phones_run_in_parallel_through_mcp(reg, wda):
    wda.sleep["/actions"] = 0.4
    elapsed = _timed_pair(reg.m, {"x": 1, "y": 1, "device": "phone1"},
                          {"x": 1, "y": 1, "device": "phone2"})
    assert elapsed < 0.7, elapsed
    assert sorted(wda.aliases_for("/actions")) == ["phone1", "phone2"]


def test_one_phone_runs_its_calls_in_order_through_mcp(reg, wda):
    wda.sleep["/actions"] = 0.4
    elapsed = _timed_pair(reg.m, {"x": 1, "y": 1, "device": "phone1"},
                          {"x": 2, "y": 2, "device": "phone1"})
    assert elapsed >= 0.75, elapsed


def test_sequence_steps_run_on_the_sequence_device(reg, wda):
    out = json.loads(reg.m.ios_run_sequence(
        [{"action": "tap", "x": 1, "y": 1}, {"action": "type", "text": "hi"}],
        device="phone2"))
    assert out["ok"] is True
    assert {a for a, _, p in wda.calls if "/session/" in p} == {"phone2"}


def test_sequence_steps_cannot_carry_their_own_device(reg, wda):
    with pytest.raises(reg.m.MCPToolError, match="unexpected param"):
        reg.m.ios_run_sequence([{"action": "tap", "x": 1, "y": 1, "device": "phone1"}],
                               device="phone2")


def test_nested_call_cannot_switch_phones(reg, wda):
    token = reg.m._current.set(reg.m._resolve("phone1"))
    try:
        with pytest.raises(reg.m.MCPToolError, match="cannot switch"):
            reg.m.ios_tap(1, 1, device="phone2")
        reg.m.ios_tap(1, 1, device="phone1")    # naming the same phone is fine
    finally:
        reg.m._current.reset(token)


# ---- one run, several phones ------------------------------------------------------

def test_run_records_both_phones_with_distinct_screenshot_names(reg, wda):
    reg.m.ios_start_run("two phones")              # no device needed
    threads = [threading.Thread(target=reg.m.ios_screenshot, kwargs={"device": a})
               for a in ("phone1", "phone2", "phone1", "phone2")]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    shots = [s["screenshot"] for s in reg.m._run["steps"] if s["screenshot"]]
    assert len(shots) == 4 and len(set(shots)) == 4
    for s in reg.m._run["steps"]:
        assert s["screenshot"].endswith(f"-{s['device']}.png")
        assert os.path.exists(os.path.join(reg.m._run["dir"], s["screenshot"]))


def test_run_notes_need_no_device_and_steps_carry_the_alias(reg, wda):
    reg.m.ios_start_run("mixed")
    reg.m.ios_tap(1, 1, device="phone1")
    reg.m.ios_run_note("phone1 done", status="pass")
    reg.m.ios_tap(1, 1, device="phone2")
    devices = [(s["action"], s["device"]) for s in reg.m._run["steps"]]
    assert devices == [("tap", "phone1"), ("note", None), ("tap", "phone2")]


def test_report_shows_device_chips_and_every_device(reg, wda):
    reg.m.ios_start_run("report")
    reg.m.ios_tap(1, 1, device="phone1")
    reg.m.ios_tap(1, 1, device="phone2")
    path = reg.m.ios_finish_run(video="none")
    html = open(path, encoding="utf-8").read()
    assert '<span class="dev">phone1</span>' in html
    assert '<span class="dev">phone2</span>' in html
    assert "devices: phone1 (iPhone17,5" in html and "phone2 (iPhone18,3" in html


def test_steps_after_finish_are_not_recorded(reg, wda):
    reg.m.ios_start_run("done")
    reg.m.ios_finish_run(video="none")
    reg.m.ios_tap(1, 1, device="phone1")
    assert all(s["action"] != "tap" for s in reg.m._run["steps"])


def test_start_run_on_a_simulator_records_that_simulator(reg, monkeypatch):
    reg.write(PHONE_AND_SIM)
    monkeypatch.setattr(reg.m, "_req", RoutedWDA(reg.m))
    seen = []

    class P:
        def __init__(self, args, **kw):
            seen.append(args)
    monkeypatch.setattr(reg.m.subprocess, "Popen", P)
    reg.m.ios_start_run("sim run", device="sim")
    assert seen and seen[0][:4] == ["xcrun", "simctl", "io", SIM]
    reg.m.ios_start_run("phone run", device="phone1")
    assert len(seen) == 1                       # a phone run records no simulator


# ---- ios_devices ------------------------------------------------------------------

def test_ios_devices_lists_and_probes_every_device(reg, monkeypatch):
    monkeypatch.setattr(reg.m, "_probe_status",
                        lambda t: {"wda_ready": t.alias == "phone1", "ios": "26.6"})
    out = json.loads(reg.m.ios_devices())
    assert out["mode"] == "list" and out["default"] is None
    rows = {d["alias"]: d for d in out["devices"]}
    assert rows["phone1"]["wda_ready"] is True and rows["phone2"]["wda_ready"] is False
    assert rows["phone2"]["udid"] == PHONE_17 and rows["phone2"]["wda"].endswith(":8110")


def test_ios_devices_marks_the_default(reg, monkeypatch):
    monkeypatch.setenv("IMIRROR_DEFAULT_DEVICE", "phone2")
    monkeypatch.setattr(reg.m, "_probe_status", lambda t: {"wda_ready": True})
    out = json.loads(reg.m.ios_devices())
    assert out["default"] == "phone2"
    assert [d["is_default"] for d in out["devices"]] == [False, True]


def test_ios_devices_in_fallback_mode_explains_why(reg, monkeypatch):
    os.remove(reg.path)
    monkeypatch.setattr(reg.m, "_probe_status", lambda t: {"wda_ready": False})
    out = json.loads(reg.m.ios_devices())
    assert out["mode"] == "fallback" and out["default"] == "default"
    assert "no device file" in out["note"]
    assert out["devices"][0]["wda"] == "http://127.0.0.1:8100"


def test_only_tools_that_never_change_the_device_are_marked_read_only(reg):
    """Claude Code sends several calls from one message at once only when the
    tools are read-only (measured: two ios_wait_for calls went out 0.3s apart
    with the hint, one after the other without). A tap must never carry it."""
    tools = {t.name: t for t in anyio.run(reg.m.mcp.list_tools)}
    read_only = {n for n, t in tools.items()
                 if t.annotations is not None and t.annotations.readOnlyHint}
    assert read_only == {
        "ios_status", "ios_devices", "ios_window_size", "ios_screenshot", "ios_source",
        "ios_await_idle", "ios_wait_for", "ios_assert_visible", "ios_assert_not_visible",
        "ios_app_state", "ios_clipboard_get",
    }
