"""Tests for devicelease's store, CLI and runtime against real processes.

No device and no WebDriverAgent: every test works in the private lease
directory conftest.py hands it, and the "other agents" are child processes
(sh, sleep, python) whose (pid, uniqueid) are real, so liveness, kill -9 and
flock behave exactly as they do on the rig.
"""
from __future__ import annotations

import asyncio
import contextlib
import fcntl
import io
import json
import os
import signal
import stat
import subprocess
import sys
import threading
import time

import pytest

import devicelease as dl

HERE = os.path.dirname(os.path.abspath(__file__))
DL = os.path.join(HERE, "devicelease.py")
GOLDEN = os.path.join(HERE, "testdata", "leases.sample.json")
SYSTEM_PY = "/usr/bin/python3"
K1 = "device:00008140-0006423002D3401C"
K2 = "device:00008150-001928E01404401C"


def lease_dir() -> str:
    return os.environ["IMIRROR_LEASE_DIR"]


def store(**kw) -> dl.Store:
    return dl.Store(lease_dir(), **kw)


def cli(*args, py=sys.executable, stdin=subprocess.DEVNULL, env=None, timeout=60):
    """Run the real CLI; return (exit code, the one JSON object it printed)."""
    r = subprocess.run([py, "-I", DL, *args, "--json"], capture_output=True, text=True,
                       stdin=stdin, env=env, timeout=timeout)
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
    assert len(lines) == 1, (r.stdout, r.stderr)
    return r.returncode, json.loads(lines[0])


def run_main(*args):
    """The CLI in-process (for monkeypatching); (exit code, JSON)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = dl.main(list(args) + ["--json"])
    return rc, json.loads(buf.getvalue())


def top(key):
    st = store().read()
    hs = ((st.get("keys") or {}).get(key) or {}).get("holders") or []
    return hs[-1] if hs else None


def wait_for(pred, timeout=10.0, what="condition"):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = pred()
        if v:
            return v
        time.sleep(0.02)
    raise AssertionError(f"timed out waiting for {what}")


class Holder:
    """A foreign agent: an sh that reserves `keys` with --anchor-pid $$,
    then waits for a `go` file before releasing (or just sleeps)."""

    def __init__(self, tmp, *keys, release_on_go=False, hold_s=0):
        self.dir = tmp
        self.out = os.path.join(tmp, f"holder-{id(self)}.json")
        self.go = os.path.join(tmp, f"go-{id(self)}")
        ks = " ".join(keys)
        extra = f"--hold-s {hold_s}" if hold_s else ""
        rel = (f'while [ ! -f "{self.go}" ]; do sleep 0.05; done; '
               f'"{sys.executable}" -I "{DL}" release {ks} --anchor-pid $$ --json >/dev/null; '
               if release_on_go else "")
        script = (f'"{sys.executable}" -I "{DL}" acquire {ks} --anchor-pid $$ {extra} --json '
                  f'> "{self.out}.tmp" && mv "{self.out}.tmp" "{self.out}"; {rel}sleep 60')
        self.p = subprocess.Popen(["/bin/sh", "-c", script], start_new_session=True)
        wait_for(lambda: os.path.exists(self.out), what="the holder's reservation")
        with open(self.out) as f:
            self.result = json.load(f)
        assert self.result["status"] == "held", self.result

    def release(self):
        open(self.go, "w").close()

    def kill(self):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(self.p.pid, signal.SIGKILL)
        self.p.wait()


@pytest.fixture
def holders(tmp_path):
    made = []

    def make(*keys, **kw):
        h = Holder(str(tmp_path), *keys, **kw)
        made.append(h)
        return h
    yield make
    for h in made:
        h.kill()


@pytest.fixture
def sleeper():
    """A live process to stand in for some other agent's anchor."""
    procs = []

    def make():
        p = subprocess.Popen(["sleep", "60"])
        procs.append(p)
        u = wait_for(lambda: dl.proc_unique(p.pid), what="sleep to start")
        return dl.Proc(p.pid, u[0])
    yield make
    for p in procs:
        p.kill()
        p.wait()


def write_state(fn):
    """Change the stored state with a pure function, under the real lock."""
    return store().update(lambda st, now: (fn(st, now), None, []))


def decide_as(me, op, keys, **kw):
    cfg = dl.Config(boot=dl.boot_session_id(), wall_offset=time.time() - dl.mono())
    req = dl.Request(op=op, keys=tuple(keys), **kw)
    return store().update(lambda st, now: dl.decide(st, req, me, now, dl._default_alive, cfg,
                                                    dl._new_id))


def as_caller(p: dl.Proc, **kw) -> dl.Caller:
    return dl.Caller(chain=(p,), anchor=p, kind=kw.pop("kind", "session"), via="test", **kw)


# ---- the CLI under the Mac's own Python 3.9 ------------------------------------

@pytest.mark.skipif(not os.path.exists(SYSTEM_PY), reason="no /usr/bin/python3")
def test_cli_smoke_under_system_python():
    rc, v = cli("--version", py=SYSTEM_PY)
    assert rc == 0 and v == {"version": dl.__version__, "protocol": 1}
    rc, me = cli("whoami", py=SYSTEM_PY)
    assert rc == 0 and me["anchor"]["pid"] > 1 and me["lease_dir"] == lease_dir()
    rc, out = cli("ensure", K1.lower(), "--purpose", "smoke", py=SYSTEM_PY)
    assert rc == 0 and out["status"] == "held" and out["keys"] == [K1]
    assert out["lease_id"] and out["expires_in_s"] > 200 and out["until"].endswith("Z")
    rc, st = cli("status", K1, py=SYSTEM_PY)
    assert rc == 0 and st["keys"][0]["state"] == "yours"
    assert st["keys"][0]["holder"]["purpose"] == "smoke"
    rc, out = cli("release", K1, py=SYSTEM_PY)
    assert rc == 0 and out["status"] == "released"
    rc, out = cli("release", K1, py=SYSTEM_PY)
    assert rc == 0 and out["status"] == "not_held"


PY39_SCENARIO = r"""
import sys
sys.path.insert(0, sys.argv[1])
import devicelease as dl
P = dl.Proc
live = {P(10, 10), P(20, 20), P(21, 21), P(30, 30), P(31, 31), P(40, 40)}
alive = lambda p: p in live
cfg = dl.Config(boot="B", wall_offset=1.7e9)
ids = iter("L%d" % i for i in range(100))
st = {}
def do(me, op, keys, t, **kw):
    global st
    st, out, ev = dl.decide(st, dl.Request(op=op, keys=tuple(keys), **kw), me, 100.0 + t,
                            alive, cfg, lambda: next(ids))
    return out
S = dl.Caller(chain=(P(21, 21), P(20, 20), P(10, 10)), anchor=P(20, 20), client="mcp")
R = dl.Caller(chain=(P(31, 31), P(30, 30), P(20, 20), P(10, 10)), anchor=P(30, 30), kind="run")
B = dl.Caller(chain=(P(40, 40),), anchor=P(40, 40))
k1, k2 = "device:A1", "device:B2"
mine = do(S, "ensure", [k1], 0)
assert mine.status == "held"
assert do(R, "acquire", [k1], 1, mode="reserve", hold_s=600).status == "held"
assert do(S, "ensure", [k1], 2).reasons[k1] == "descendant"
assert do(B, "acquire", [k1], 3, wait=True).status == "queued"
assert do(R, "release", [k1], 4).status == "released"
bel = {k1: {"lease_id": mine.lease_id, "epoch": mine.epochs[k1]}}
assert do(S, "ensure", [k1], 5, believed=bel).lease_id == mine.lease_id
assert do(B, "release", [k1], 5).status == "released"     # B stops waiting
assert not st["tickets"]
assert do(B, "ensure", [k2], 6).status == "held"
assert do(S, "acquire", [k2], 7, wait=True).status == "queued"
assert do(B, "acquire", [k1], 8, wait=True).status == "deadlock"
assert do(B, "break", [k1], 9, reason="r").status == "broken"
assert do(S, "ensure", [k1], 10).status == "freed_by_user"
v = dl.view(st, S, 111.0, alive, cfg)
assert v[k2]["state"] == "busy" and v[k2]["queue"] == 0     # the break dropped S's ticket
dl.serialize(st)
print("ok")
"""


@pytest.mark.skipif(not os.path.exists(SYSTEM_PY), reason="no /usr/bin/python3")
def test_pure_core_runs_under_system_python_3_9():
    r = subprocess.run([SYSTEM_PY, "-I", "-c", PY39_SCENARIO, HERE], capture_output=True,
                       text=True, timeout=60)
    assert r.returncode == 0 and r.stdout.strip() == "ok", r.stderr


def test_usage_errors_exit_2_with_one_json_object():
    rc, out = cli("ensure", "not a key")
    assert rc == 2 and out["code"] == "USAGE" and not out["ok"]
    rc, out = cli("release")
    assert rc == 2 and out["code"] == "USAGE"
    rc, out = cli("frobnicate")
    assert rc == 2


def test_break_refuses_without_a_terminal():
    rc, out = cli("break", K1, "--reason", "test")       # stdin is not a TTY
    assert rc == 2 and ("terminal" in out["message"] or "Claude" in out["message"])


def test_busy_exits_3_and_names_the_holder(holders):
    h = holders(K1, hold_s=600)
    rc, out = cli("ensure", K1)
    assert rc == 3 and out["status"] == "busy" and out["code"] == "DEVICE_BUSY"
    assert out["blocked_on"][0]["holder"]["pid"] == h.p.pid
    assert out["message"].startswith("Nothing was sent.")
    assert out["retry_after_s"] >= 500
    rc, out = cli("acquire", K1, "--anchor-pid", str(os.getpid()))
    assert rc == 3, "an explicit attempt without --wait-s does not queue"
    assert not store().read()["tickets"]


def test_renew_of_a_lost_reservation_exits_5():
    rc, out = run_main("acquire", K1, "--anchor-pid", str(os.getpid()), "--hold-s", "60")
    assert rc == 0
    write_state(lambda st, now: {**st, "keys": {}})       # it went away
    rc, out = run_main("renew", K1, "--anchor-pid", str(os.getpid()))
    assert rc == 5 and out["status"] == "lost" and out["code"] == "DEVICE_RESERVATION_LOST"


def test_deadlock_exits_4(sleeper):
    me = str(os.getpid())
    assert run_main("acquire", K2, "--anchor-pid", me)[0] == 0
    x = as_caller(sleeper())
    assert decide_as(x, "acquire", [K1]).status == "held"
    assert decide_as(x, "acquire", [K2], wait=True).status == "queued"
    rc, out = run_main("acquire", K1, "--anchor-pid", me, "--wait-s", "5")
    assert rc == 4 and out["status"] == "deadlock" and out["code"] == "DEVICE_DEADLOCK"


def test_freed_by_user_exits_5():
    me = str(os.getpid())
    assert run_main("acquire", K1, "--anchor-pid", me)[0] == 0
    user = as_caller(dl.Proc(os.getpid(), dl.proc_unique(os.getpid())[0]), kind="terminal")
    assert decide_as(user, "break", [K1], reason="iMirror Settings").status == "broken"
    rc, out = run_main("acquire", K1, "--anchor-pid", me)
    assert rc == 5 and out["status"] == "freed_by_user"
    assert out["code"] == "DEVICE_FREED_BY_USER"


def test_lease_off_is_honoured_under_testing(monkeypatch):
    monkeypatch.setenv("IMIRROR_LEASE", "off")
    rc, out = cli("ensure", K1)
    assert rc == 0 and out["disabled"] is True
    assert not os.path.exists(os.path.join(lease_dir(), "state.json"))


def test_status_reports_the_dir_and_overrides():
    rc, out = cli("status")
    assert rc == 0 and out["lease_dir"] == lease_dir()
    assert out["overrides"] == {"IMIRROR_LEASE_DIR": lease_dir()}
    assert isinstance(out["unlocked_servers"], list)


# ---- concurrency: processes and threads ---------------------------------------

WORKER = r"""
import contextlib, io, json, os, random, sys, time
sys.path.insert(0, sys.argv[1])
import devicelease as dl
marks, keys = sys.argv[2], sys.argv[3:]
sets = [[keys[0]], [keys[1]], keys]
me = str(os.getpid())

def run(*args):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = dl.main(list(args) + ["--json"])
    return rc, json.loads(buf.getvalue())

deadline = time.time() + 90                    # fail, never hang
for i in range(50):
    ks = sets[i % 3]
    while True:
        rc, out = run("acquire", *ks, "--anchor-pid", me, "--purpose", "w" + me)
        if rc == 0:
            break
        assert rc == 3, (rc, out)
        assert time.time() < deadline, "starved: a hold never went away"
        time.sleep(random.uniform(0.0005, 0.003))
    marked = []
    for k in ks:                                   # overlap -> FileExistsError
        p = os.path.join(marks, k.replace(":", "_"))
        os.close(os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY))
        marked.append(p)
    st = dl.Store(os.environ["IMIRROR_LEASE_DIR"]).read()
    for k in ks:
        t = st["keys"][k]["holders"][-1]
        assert t["lease_id"] == out["lease_id"] and t["anchor"]["pid"] == int(me), t
    time.sleep(0.001)
    for p in marked:
        os.unlink(p)
    rc, rel = run("release", *ks, "--anchor-pid", me)
    assert rc == 0 and rel["status"] == "released" and sorted(rel["released"]) == sorted(ks), rel
print(me)
"""


def test_eight_processes_fifty_cycles_never_overlap_or_lose_a_hold(tmp_path):
    script = tmp_path / "worker.py"
    script.write_text(WORKER)
    marks = tmp_path / "marks"
    marks.mkdir()
    procs = [subprocess.Popen([sys.executable, str(script), HERE, str(marks), K1, K2],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
             for _ in range(8)]
    pids = set()
    try:
        for p in procs:
            out, err = p.communicate(timeout=120)
            assert p.returncode == 0, err
            pids.add(int(out.strip()))
    finally:
        for p in procs:
            if p.poll() is None:
                p.kill()
                p.wait()
    assert len(pids) == 8, "every worker had its own anchor"
    granted = set()
    with open(os.path.join(lease_dir(), "events.jsonl")) as f:
        for line in f:
            e = json.loads(line)
            if e["event"] == "granted":
                granted.add(e["pid"])
    assert granted == pids
    st = store().read()
    assert all(not ks["holders"] for ks in st["keys"].values())


def test_sixteen_threads_fifty_cycles_in_one_process():
    """One MCP process, 16 labelled subagents: the threading.Lock plus a fresh
    flock fd per critical section must exclude threads, not only processes."""
    locker = dl.Locker(client="mcp", via="test")
    owner = {K1: None, K2: None}
    guard = threading.Lock()
    errors = []
    sets = [(K1,), (K2,), (K1, K2)]

    def work(i):
        label = f"t{i}"
        deadline = time.time() + 60          # a lost release must fail, not hang
        try:
            for n in range(50):
                ks = sets[(i + n) % 3]
                while True:
                    out = locker.acquire(ks, label=label)
                    if out.status == "held":
                        break
                    assert out.status == "busy", out
                    assert time.time() < deadline, f"{label} starved: a hold never went away"
                    time.sleep(0.0005)
                with guard:
                    for k in ks:
                        assert owner[k] is None, f"{label} overlaps {owner[k]} on {k}"
                        owner[k] = label
                st = locker.store.read()
                for k in ks:
                    t = st["keys"][k]["holders"][-1]
                    assert t["label"] == label and t["lease_id"] == out.lease_id
                with guard:
                    for k in ks:
                        owner[k] = None
                rel = locker.release(ks, label=label)
                assert rel.status == "released" and sorted(rel.released) == sorted(ks), rel
        except BaseException as e:            # surface it on the main thread
            errors.append(e)

    threads = [threading.Thread(target=work, args=(i,), daemon=True) for i in range(16)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=120)
    assert not errors, errors[0]
    assert all(not ks["holders"] for ks in locker.store.read()["keys"].values())


# ---- kill -9 and orphans ----------------------------------------------------------

CHILD = r"""
import json, os, subprocess, sys, time
py, dl, key, d = sys.argv[1:5]
def ensure(name):
    r = subprocess.run([py, "-I", dl, "ensure", key, "--json"], capture_output=True, text=True)
    with open(os.path.join(d, name + ".tmp"), "w") as f:
        json.dump({"rc": r.returncode, "out": json.loads(r.stdout)}, f)
    os.replace(os.path.join(d, name + ".tmp"), os.path.join(d, name))
if len(sys.argv) < 6:
    ensure("first.json")
open(os.path.join(d, "ready"), "w").close()        # alive under run.sh
deadline = time.time() + 30
while os.getppid() != 1 and time.time() < deadline:   # until run.sh is killed
    time.sleep(0.02)
ensure("second.json")
"""


@pytest.mark.parametrize("context_run", [False, True])
def test_kill_9_of_a_reservation_leaves_its_covered_child_refused(tmp_path, context_run,
                                                                  monkeypatch):
    if context_run:                       # run.sh exports this; the child skips ensure #1
        monkeypatch.setenv("IMIRROR_LEASE_CONTEXT", "run")
    child = tmp_path / "child.py"
    child.write_text(CHILD)
    d = str(tmp_path)
    skip = " skip" if context_run else ""
    script = (f'"{sys.executable}" -I "{DL}" acquire {K1} --anchor-pid $$ --hold-s 1800 '
              f'--json > "{d}/acq.json"; "{sys.executable}" "{child}" "{sys.executable}" '
              f'"{DL}" {K1} "{d}"{skip} & wait')
    run_sh = subprocess.Popen(["/bin/sh", "-c", script])
    try:
        wait_for(lambda: (tmp_path / "ready").exists(), what="the child to start")
        if not context_run:
            first = _load(tmp_path / "first.json")
            assert first["rc"] == 0 and first["out"]["status"] == "covered", first
        assert top(K1)["anchor"]["pid"] == run_sh.pid
        os.kill(run_sh.pid, signal.SIGKILL)
        run_sh.wait()
        second = wait_for(lambda: _load(tmp_path / "second.json"), timeout=30,
                          what="the orphan's call")
        assert second["rc"] == 5 and second["out"]["status"] == "lost", second
        assert second["out"]["code"] == "DEVICE_RESERVATION_LOST"
        assert top(K1) is None, "the orphan was not granted the phone"
    finally:
        with contextlib.suppress(ProcessLookupError):
            run_sh.kill()


def _load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


# ---- files: torn, corrupt, owner, protocol, lock -----------------------------------

def test_a_torn_file_is_never_read():
    s = store()
    stop = threading.Event()
    bad = []

    def writer():
        for i in range(300):
            s.update(lambda st, now, i=i: ({**st, "pad": "x" * (i * 97 % 20000)}, None, []))
        stop.set()

    def reader():
        while not stop.is_set():
            try:
                s.read()
            except dl.CorruptState as e:
                bad.append(e)
    t1, t2 = threading.Thread(target=writer), threading.Thread(target=reader)
    t2.start()
    t1.start()
    t1.join()
    t2.join()
    assert not bad
    with open(s.state_path + ".tmp", "w") as f:            # a writer died mid-write
        f.write('{"protocol": 1, "keys": {"device:X": ')
    assert "pad" in s.read()


def test_a_corrupt_file_is_recovered():
    s = store()
    s.prepare()
    with open(s.state_path, "w") as f:
        f.write("{not json")
    os.chmod(s.state_path, 0o600)
    rc, out = cli("ensure", K1)
    assert rc == 0 and out["status"] == "held"
    names = os.listdir(lease_dir())
    assert any(n.startswith("state.json.corrupt-") for n in names)
    assert top(K1)["lease_id"] == out["lease_id"]
    with open(s.events_path) as f:
        assert any(json.loads(ln)["event"] == "corrupt-recovered" for ln in f)


def test_wrong_owner_exits_6(monkeypatch):
    assert run_main("ensure", K1)[0] == 0
    monkeypatch.setattr(dl, "_owner_uid", lambda: os.getuid() + 1)
    rc, out = run_main("ensure", K1)
    assert rc == 6 and out["code"] == "RESERVATION_STATE_ERROR"
    assert "not owned by this user" in out["message"]


def test_refuses_root(monkeypatch):
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    rc, out = run_main("ensure", K1)
    assert rc == 6 and "root" in out["message"]


def test_a_newer_protocol_file_is_never_rewritten():
    s = store()
    s.prepare()
    raw = '{"protocol": 2, "keys": {}, "something": "new"}\n'
    with open(s.state_path, "w") as f:
        f.write(raw)
    rc, out = cli("ensure", K1)
    assert rc == 6 and "restart this session's MCP" in out["message"]
    with open(s.state_path) as f:
        assert f.read() == raw


def test_flock_timeout_fails_closed_and_reads_still_work():
    s = store(lock_timeout_s=0.3)
    s.prepare()
    fd = os.open(s.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        locker = dl.Locker(store=s, client="cli", via="test")
        t0 = time.time()
        with pytest.raises(dl.StateError, match="timed out"):
            locker.acquire([K1])
        assert time.time() - t0 < 3
        assert s.read() == {}
    finally:
        os.close(fd)
    assert locker.acquire([K1]).status == "held"


def test_state_lock_is_never_replaced_and_files_are_private():
    s = store()
    s.prepare()
    os.chmod(s.root, 0o755)
    s._ready = False
    run_main("ensure", K1)
    ino = os.stat(s.lock_path).st_ino
    for _ in range(5):
        run_main("ensure", K1)
    with open(s.state_path, "w") as f:
        f.write("garbage")
    run_main("ensure", K1)
    assert os.stat(s.lock_path).st_ino == ino
    assert stat.S_IMODE(os.stat(s.root).st_mode) == 0o700
    for p in (s.state_path, s.lock_path, s.events_path):
        assert stat.S_IMODE(os.stat(p).st_mode) == 0o600, p


def test_update_writes_a_state_edited_in_place():
    s = store()
    s.update(lambda st, now: (st.update(note="kept") or st, None, []))
    assert s.read()["note"] == "kept"


def test_events_rotate_at_the_size_cap():
    s = store(events_max_bytes=300)
    for i in range(20):
        s.update(lambda st, now: (st, None, [{"event": "probe", "n": "x" * 50}]))
    assert os.path.exists(s.events_path + ".1")
    assert os.path.getsize(s.events_path) < 1000


# ---- the runtime the MCP hook uses ---------------------------------------------------

def test_drive_on_a_foreign_hold_is_refused_and_observe_is_never_checked(holders):
    holders(K1)
    locker = dl.Locker(client="mcp", via="test")
    before = store().read()
    with pytest.raises(dl.LeaseError) as e:
        locker.enter(K1, access="drive")
    assert e.value.code == "DEVICE_BUSY" and str(e.value).startswith("Nothing was sent.")
    h = locker.enter(K1, access="observe")
    assert not h.active
    with pytest.raises(dl.LeaseError):
        locker.enter(K1, access="inspect")
    assert store().read()["keys"] == before["keys"]


def test_inspect_runs_free_on_a_free_device_without_taking_it():
    locker = dl.Locker(client="mcp", via="test")
    with locker.hold(K1, access="inspect") as h:
        assert not h.active and not h.warning
    assert top(K1) is None
    with locker.hold(K1, access="drive") as h:
        assert h.active and top(K1) is not None


def test_heartbeat_stops_a_call_when_the_user_frees_the_device():
    locker = dl.Locker(client="mcp", via="test", heartbeat_s=0.05)
    user = as_caller(dl.Proc(os.getpid(), dl.proc_unique(os.getpid())[0]), kind="terminal")
    with locker.hold(K1, label="a") as h:
        locker.check(K1, "a")
        decide_as(user, "break", [K1], reason="Free")
        wait_for(lambda: (K1, "a") in locker._revoked, what="the heartbeat")
        with pytest.raises(dl.LeaseError) as e:
            locker.check(K1, "a")
        assert e.value.code == "DEVICE_FREED_BY_USER"
    assert not h.active


def test_the_heartbeat_never_calls_time_sleep_and_close_stops_it(monkeypatch):
    """The MCP suite patches time.sleep in dozens of tests; a heartbeat that
    called it spun and polluted their sleep logs. close() ends the thread."""
    real_sleep = time.sleep
    locker = dl.Locker(client="mcp", via="test", heartbeat_s=0.05)
    slept = []
    monkeypatch.setattr(time, "sleep", lambda s: slept.append(s))
    with locker.hold(K1):
        first = locker._belief[(K1, "")]["verified"]
        real_sleep(0.3)
        assert locker._belief[(K1, "")]["verified"] > first, "the heartbeat ran"
    assert slept == []
    locker.close()
    locker._hb_thread.join(timeout=2)
    assert not locker._hb_thread.is_alive()


def test_check_reverifies_when_the_heartbeat_is_starved(monkeypatch, sleeper):
    monkeypatch.setattr(dl.Locker, "_start_heartbeat", lambda self: None)
    locker = dl.Locker(client="mcp", via="test", heartbeat_s=0.05)
    other = sleeper()
    with locker.hold(K1):
        def steal(st, now):
            ks = st["keys"][K1]
            ks["holders"][-1]["anchor"] = {"pid": other.pid, "uniqueid": other.uniq}
            ks["holders"][-1]["lease_id"] = "someone-else"
            return st
        write_state(steal)
        time.sleep(0.15)
        with pytest.raises(dl.LeaseError) as e:
            locker.check(K1)
        assert e.value.code == "DEVICE_RESERVATION_LOST"
        assert "Stopped mid-call" in str(e.value)


def test_a_run_started_mid_call_suspends_the_call_and_gives_it_back(tmp_path):
    locker = dl.Locker(client="mcp", via="test", heartbeat_s=0.05)
    with locker.hold(K1) as h:
        mine = h.outcome.lease_id
        # My child descends from me, so its reservation pushes mine.
        run = subprocess.Popen(["/bin/sh", "-c", f'"{sys.executable}" -I "{DL}" acquire {K1} '
                                f'--anchor-pid $$ --json >/dev/null; sleep 1'])
        wait_for(lambda: (top(K1) or {}).get("anchor", {}).get("pid") == run.pid,
                 what="the run's reservation")
        wait_for(lambda: (K1, "") in locker._revoked, what="the heartbeat")
        with pytest.raises(dl.LeaseError) as e:
            locker.check(K1)
        assert e.value.code == "DEVICE_BUSY" and "a run you started" in str(e.value)
    run.wait()
    with locker.hold(K1) as h:                # the run ended; mine came back
        assert h.outcome.status == "held" and h.outcome.lease_id == mine
    assert len(store().read()["keys"][K1]["holders"]) == 1


def test_a_cancelled_wait_leaves_no_ticket_and_no_hold(holders):
    h = holders(K1)
    locker = dl.Locker(client="mcp", via="test")

    async def go():
        task = asyncio.ensure_future(locker.acquire_async([K1], wait_s=30, poll_s=0.05))
        await asyncio.sleep(0.3)
        assert len(store().read()["tickets"]) == 1
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    asyncio.run(go())
    st = store().read()
    assert not st["tickets"]
    assert top(K1)["anchor"]["pid"] == h.p.pid


def test_a_grant_that_lands_after_cancel_is_released(holders):
    h = holders(K1, release_on_go=True)
    locker = dl.Locker(client="mcp", via="test")

    async def go():
        task = asyncio.ensure_future(locker.acquire_async([K1], wait_s=30, poll_s=10))
        await asyncio.sleep(0.3)                     # queued, now sleeping 10 s
        h.release()
        await asyncio.get_running_loop().run_in_executor(
            None, lambda: wait_for(lambda: (top(K1) or {}).get("claim_until_mono"),
                                   what="the grant to the waiter"))
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    asyncio.run(go())
    assert top(K1) is None and not store().read()["tickets"]


def test_an_async_wait_gets_the_device_when_the_holder_lets_go(holders):
    h = holders(K1, release_on_go=True)
    locker = dl.Locker(client="mcp", via="test")

    async def go():
        threading.Timer(0.4, h.release).start()
        t0 = time.time()
        out = await locker.acquire_async([K1], wait_s=20, poll_s=0.05)
        return out, time.time() - t0
    out, took = asyncio.run(go())
    assert out.status == "held" and took < 5
    assert top(K1)["claim_until_mono"] is None


def test_mcp_waits_are_capped_at_85_s():
    # Claude Code backgrounds a call at 120 s.
    assert dl.Locker(client="mcp").cfg.mcp_wait_cap_s == 85


def test_cli_wait_queues_then_gets_the_device(holders):
    h = holders(K1, release_on_go=True)
    threading.Timer(0.5, h.release).start()
    rc, out = cli("acquire", K1, "--wait-s", "20")
    assert rc == 0 and out["status"] == "held"


def test_cli_wait_that_times_out_exits_3_and_keeps_its_place(holders):
    holders(K1)
    rc, out = cli("acquire", K1, "--wait-s", "0.6")
    assert rc == 3 and out["status"] == "queued" and out["position"] == 1
    assert len(store().read()["tickets"]) == 1
    rc, out = cli("acquire", K1, "--wait-s", "0.3")
    assert len(store().read()["tickets"]) == 1, "a second wait joins the same ticket"


def test_required_with_a_broken_dir_fails_closed(tmp_path, monkeypatch):
    blocker = tmp_path / "file"
    blocker.write_text("")
    monkeypatch.setenv("IMIRROR_LEASE_DIR", str(blocker / "leases"))
    open_locker = dl.Locker(client="mcp", via="test")
    assert not open_locker.enabled and open_locker.problem
    assert not open_locker.enter(K1).active, "fails open at startup without REQUIRED"
    monkeypatch.setenv("IMIRROR_LEASE_REQUIRED", "1")
    closed = dl.Locker(client="mcp", via="test")
    assert closed.enabled and closed.problem
    with pytest.raises(dl.StateError, match="nothing was sent"):
        closed.enter(K1)


def test_lease_off_disables_the_runtime(monkeypatch):
    monkeypatch.setenv("IMIRROR_LEASE", "off")
    locker = dl.Locker(client="mcp", via="test")
    assert not locker.enabled
    assert not locker.enter(K1).active and locker.view() == {}


# ---- the server registry and the unlocked-server scan ----------------------------------

def test_register_server_and_the_scan(tmp_path):
    # The child also refuses the real dir, so regressions fail.
    child = ("import sys, time; sys.path.insert(0, sys.argv[1]); import devicelease as dl\n"
             "def no(): raise SystemExit('reached the real lease dir')\n"
             "dl.default_lease_dir = no\n"
             "print(dl.register_server(None, '1.4.0', 'imirror_mcp.py'), flush=True)\n"
             "time.sleep(60)\n")
    reg = subprocess.Popen([sys.executable, "-c", child, HERE], stdout=subprocess.PIPE, text=True)
    try:
        path = reg.stdout.readline().strip()
        assert path.startswith(lease_dir() + os.sep), path
        assert os.path.basename(path).startswith(f"{reg.pid}-")
        assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
        repo_ok = tmp_path / "ok"
        (repo_ok / "Testing" / "lib").mkdir(parents=True)
        (repo_ok / "Testing" / "lib" / "devicelease.sh").write_text("")
        repo_old = tmp_path / "old"
        (repo_old / "Testing").mkdir(parents=True)
        uid = os.getuid()
        ps = "\n".join([
            f"{reg.pid} {uid} python /x/mcp/current/imirror_mcp.py",
            f"70001 {uid} /Library/.../Python /Users/x/Documents/Github/imirror/mcp-server/imirror_mcp.py",
            f"70002 0 python /root/imirror_mcp.py",
            f"70003 {uid} /bin/bash ./Testing/run.sh 07",
            f"70004 {uid} /bin/bash Testing/run.sh",
            f"70005 {uid} /bin/bash ./run.sh 3",
            f"{os.getpid()} {uid} python imirror_mcp.py",
            "garbage line",
        ])
        argv = {70003: ["/bin/bash", "./Testing/run.sh", "07"],
                70004: ["/bin/bash", "Testing/run.sh"], 70005: ["/bin/bash", "./run.sh", "3"]}
        cwd = {70003: str(repo_old), 70004: str(repo_ok), 70005: str(repo_old / "Testing")}
        found = dl.unlocked_servers(lease_dir(), ps_text=ps, argv_of=lambda p: argv.get(p, []),
                                    cwd_of=lambda p: cwd.get(p, ""))
        by_pid = {f["pid"]: f for f in found}
        assert set(by_pid) == {70001, 70003, 70005}
        assert by_pid[70003]["kind"] == "run.sh" and by_pid[70003]["repo"] == str(repo_old)
        assert by_pid[70001]["kind"] == "mcp"
    finally:
        reg.kill()
        reg.wait()
    found = dl.unlocked_servers(lease_dir(), ps_text=f"{reg.pid} {os.getuid()} imirror_mcp.py",
                                argv_of=lambda p: [], cwd_of=lambda p: "")
    assert [f["pid"] for f in found] == [reg.pid], "a dead registration does not count"
    assert not os.path.exists(path), "and is pruned"


# ---- the golden file the Swift app decodes ------------------------------------------------

def build_golden_state() -> dict:
    """A fixed, realistic state: run.sh pushed the session that started it on
    phone1 and covers its scenario agent; a labelled subagent holds phone2
    with two waiters (one wants both phones); the user freed the Simulator;
    an old run died and left an orphan on the bare WDA key."""
    P = dl.Proc
    term, S, S_mcp, S_bash = P(1100, 1100), P(3376, 4162500), P(3421, 4162545), P(53142, 4201000)
    R, R_cli, R_claude, R_mcp = P(61234, 4210000), P(61240, 4210006), P(61300, 4210066), P(61301, 4210067)
    term2, B, B_mcp = P(1180, 1180), P(5528, 4100000), P(5530, 4100002)
    C, C_mcp, D, D_mcp = P(7001, 4300000), P(7002, 4300001), P(8001, 4400000), P(8002, 4400001)
    U, U_cli = P(9001, 4500000), P(9002, 4500001)
    R0, R0_cli, R0_child = P(60001, 4209000), P(60002, 4209001), P(60003, 4209002)
    live = {term, S, S_mcp, S_bash, R, R_cli, R_claude, R_mcp, term2, B, B_mcp, C, C_mcp, D,
            D_mcp, U, U_cli, R0, R0_cli, R0_child}
    t0 = 81234.5
    cfg = dl.Config(boot="56B0E428-3E94-45AF-BA8C-FD57CC500F00",
                    wall_offset=1792443605.0 - t0)          # t0 = 2026-10-19T21:00:05Z
    ids = iter(["9f2c41aa0e6b7d13", "5d0e9b8c7a6f4e21", "c03b7e5512d9a846", "77a1f0e2b94c5d38",
                "e4d2c1b0a9f8e7d6", "1a2b3c4d5e6f7081", "0badc0ffee123456", "3141592653589793"])
    st: dict = {}

    def who(chain, anchor, kind="session", label="", client="mcp", via="imirror-mcp 1.4.0",
            cwd="/Users/manaf/Documents/Github/Purpose/Purpose-iOS", name="", **kw):
        return dl.Caller(chain=tuple(chain), anchor=anchor, kind=kind, anchor_name=name,
                         label=label, client=client, via=via, cwd=cwd, **kw)

    def do(me, op, keys, t, **kw):
        nonlocal st
        st, out, _ = dl.decide(st, dl.Request(op=op, keys=tuple(keys), **kw), me, t0 + t,
                               lambda p: p in live, cfg, lambda: next(ids))
        return out

    wda = "wda:127.0.0.1:8100"
    r0 = who([R0_cli, R0, term], R0, kind="run", client="cli", via="imirror-lease acquire",
             name="bash")
    assert do(r0, "acquire", [wda], -100, mode="reserve", hold_s=1800,
              purpose="Testing/run.sh 20261019-204000").status == "held"
    child = who([P(60004, 4209003), R0_child, R0, term], R0_child, client="cli",
                via="imirror-lease ensure")
    assert do(child, "ensure", [wda], -90).status == "covered"
    live.discard(R0)                                          # kill -9 run.sh
    s_mcp = who([S_mcp, S, term], S, name="2.1.304")
    assert do(s_mcp, "ensure", [dl.normalize_key("device:00008140-0006423002d3401c")], 0,
              purpose="ios_tap").status == "held"
    p1 = "device:00008140-0006423002D3401C"
    p2 = "device:00008150-001928E01404401C"
    sim = "sim:5B3C1F2A-0000-4000-8000-00000000A1B2"
    run = who([R_cli, R, S_bash, S, term], R, kind="run", client="cli",
              via="imirror-lease acquire", name="bash")
    assert do(run, "acquire", [p1], 5, mode="reserve", hold_s=1800,
              purpose="Testing/run.sh 20261019-210000 · 07-extension-lock (7/14)").status == "held"
    agent = who([R_mcp, R_claude, R, S_bash, S, term], R_claude, name="2.1.304",
                covered_only=True)
    assert do(agent, "ensure", [p1], 12, purpose="ios_tap").status == "covered"
    b = who([B_mcp, B, term2], B, label="explorer", name="2.1.302",
            cwd="/Users/manaf/Documents/Github/imirror-wt/f3")
    assert do(b, "ensure", [p2], 20, purpose="ios_find_and_tap").status == "held"
    c = who([C_mcp, C, term2], C, name="2.1.303", cwd="/Users/manaf/Documents/Github/x")
    assert do(c, "acquire", [p2], 30, mode="explicit", wait=True, hold_s=900,
              purpose="check the buddy screen").status == "queued"
    d = who([D_mcp, D, term2], D, name="2.1.290", cwd="/Users/manaf/Documents/Github/y")
    assert do(d, "acquire", [p1, p2], 40, mode="explicit", wait=True,
              purpose="two-phone buddy flow").status == "queued"
    assert do(b, "ensure", [sim], 50, purpose="ios_screenshot").status == "held"
    user = who([U_cli, U], U, kind="terminal", client="cli", via="imirror-lease break",
               name="iMirror")
    assert do(user, "break", [sim], 60, reason="iMirror Settings: Free",
              purpose="iMirror app").status == "broken"
    st["updated_at"] = "2026-10-19T21:01:05Z"
    st["writer"] = {"pid": 812, "version": dl.__version__}
    return st


def test_golden_leases_sample_is_reproduced_byte_for_byte():
    text = dl.serialize(build_golden_state())
    if os.environ.get("IMIRROR_REGEN_GOLDEN") == "1":
        with open(GOLDEN, "w", encoding="utf-8") as f:
            f.write(text)
    with open(GOLDEN, encoding="utf-8") as f:
        assert f.read() == text


def test_golden_has_every_shape_the_app_must_decode():
    with open(GOLDEN, encoding="utf-8") as f:
        doc = json.load(f)
    assert doc["protocol"] == 1 and doc["boot"]
    p1 = doc["keys"]["device:00008140-0006423002D3401C"]
    assert [h["kind"] for h in p1["holders"]] == ["session", "run"]
    assert p1["holders"][0]["frozen"] and p1["holders"][1]["covered"]
    assert doc["keys"]["sim:5B3C1F2A-0000-4000-8000-00000000A1B2"]["tombstone"]
    assert [sorted(t["keys"]) for t in doc["tickets"]] == [
        ["device:00008150-001928E01404401C"],
        ["device:00008140-0006423002D3401C", "device:00008150-001928E01404401C"]]
    assert doc["ended"] and doc["ended"][0]["covered"]
    assert doc["keys"]["wda:127.0.0.1:8100"]["last_release"]["reason"] == "anchor-gone"


# ---- Agreement with the MCP server's devices.json owner check ------------------

def test_proc_alive_agrees_with_the_servers_device_file_check(monkeypatch, tmp_path):
    """The app will stamp devices.json with owner_uniqueid, and both the MCP
    server and the lease CLI judge that owner. Two answers for one process
    would let one trust a crashed app's ports while the other refuses them."""
    import importlib
    monkeypatch.setenv("IMIRROR_WDA", "http://127.0.0.1:8100")
    monkeypatch.setenv("IMIRROR_DEVICES_FILE", str(tmp_path / "devices.json"))
    monkeypatch.delenv("IMIRROR_TARGET", raising=False)
    sys.modules.pop("imirror_mcp", None)
    m = importlib.import_module("imirror_mcp")

    me = os.getpid()
    uniq = dl.proc_unique(me)[0]
    zombie = subprocess.Popen(["/usr/bin/true"])
    deadline = time.time() + 10
    while dl.proc_info(zombie.pid) is not None and time.time() < deadline:
        time.sleep(0.02)                    # exited, not yet reaped
    dead = subprocess.Popen(["/usr/bin/true"])
    dead.wait()
    cases = [(me, None), (me, uniq), (me, uniq + 1), (zombie.pid, None), (dead.pid, None),
             (0, None), (-1, None), (True, None), ("5", None),
             (2 ** 31, None), (2 ** 32 + me, None), (2 ** 64, None)]
    try:
        for pid, u in cases:
            assert dl.proc_alive(pid, u) == m._pid_alive(pid, u), (pid, u)
        assert dl.proc_alive(me, uniq) and not dl.proc_alive(zombie.pid)
        assert not dl.proc_alive(2 ** 32 + me), "a cut pid must not alias this one"
    finally:
        zombie.wait()
