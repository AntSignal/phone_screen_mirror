#!/usr/bin/env python3
"""Device leases: which agent may drive a shared iPhone or Simulator right now.

Many Claude sessions, their subagents and Testing/run.sh share a few devices.
WebDriverAgent keeps one session per phone, so two drivers trample each other.
A lease records who may drive a device now. It is cooperative: every tool that
drives a device asks here first, and nothing in the relay enforces it.

One file, three faces:
  * a pure core, normalize() and decide(), with no I/O (what the tests cover);
  * a process adapter (ctypes) and a Store: state.json behind one flock;
  * the `imirror-lease` CLI (`python devicelease.py ...`). antsignalctl,
    run.sh and the iMirror app shell out to it, so there is one implementation.

Who holds a lease is a process, not a token: (pid, p_uniqueid). A hold covers
its anchor and every descendant. The anchor is --anchor-pid, else the nearest
`claude` ancestor, else the terminal tab's shell.

Runtime API for imirror_mcp.py
------------------------------
    locker = Locker(client="mcp", via="imirror-mcp 1.4.0")
    locker.enabled, locker.problem      # False/"why" when off or broken at startup
    with locker.hold(key, label=agent, purpose="...", access="drive") as h:
        ...                             # access: "observe" | "inspect" | "drive"
        locker.check(key, agent)        # before EVERY WDA request; may raise
        h.warning                       # inspect after LOST: prefix the result
    locker.enter(...) / locker.exit(h)  # the same, without `with`
    locker.acquire(keys, mode="explicit", hold_s=0, wait=False, purpose, label)
    await locker.acquire_async(keys, wait_s=85, run_sync=anyio.to_thread.run_sync,
                               sleep=anyio.sleep, ...)   # cancel-safe wait loop
    locker.release(keys, label)         # own entries and tickets only
    locker.view(keys, label)            # {key: {state, holder, queue, ...}}
    locker.register_server(version, script); unlocked_servers()
Failures raise LeaseError (.code, .status, .outcome, str() is the message) for
busy / lost / deadlock / freed-by-user, and StateError for a broken lease
system, which callers must treat as "nothing was sent" (fail closed).
Keys: device_key(udid), sim_key(udid), wda_key(host, port).
Liveness for devices.json owners: proc_alive(pid, uniqueid=None).
"""
from __future__ import annotations

__version__ = "1.0.0"
PROTOCOL = 1

import argparse
import contextlib
import ctypes
import dataclasses
import errno
import fcntl
import functools
import json
import math
import os
import pwd
import random
import re
import secrets
import signal
import stat
import struct
import subprocess
import sys
import threading
import time
from collections import namedtuple
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple


# ---- Errors -------------------------------------------------------------------

class StateError(Exception):
    """The lease system itself cannot answer: unreadable or newer state, wrong
    owner, root, a flock timeout. Callers fail closed on it, because guessing
    "free" is how two agents end up on one phone."""
    code = "RESERVATION_STATE_ERROR"


class Unkeyable(StateError):
    """No valid anchor process, so nobody could ever be told who holds it."""
    code = "DEVICE_UNKEYABLE"


class UsageError(Exception):
    code = "USAGE"


class CorruptState(Exception):
    """state.json does not parse. Only an update (under flock) may fix it."""


class LeaseError(Exception):
    """A clean refusal: busy, lost, deadlock or freed by the user. Nothing was
    sent to the device. `.outcome` carries the holder details for messages."""

    def __init__(self, outcome: "Outcome", message: str = ""):
        self.outcome = outcome
        self.status = outcome.status
        self.code = outcome.code or "DEVICE_BUSY"
        self.message = message or outcome.message
        super().__init__(self.message)

    def __str__(self) -> str:
        return self.message


# ---- Keys and clocks ----------------------------------------------------------

_KEY_RE = re.compile(r"^[a-z][a-z0-9-]{0,15}:[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
_UPPER_KINDS = ("device", "sim")


def normalize_key(key: str) -> str:
    """Return the canonical spelling of a lease key, or raise UsageError.
    UDIDs are upper-cased so `device:abc` and `device:ABC` are one lease."""
    k = (key or "").strip()
    kind, sep, ident = k.partition(":")
    if sep and kind in _UPPER_KINDS:
        k = f"{kind}:{ident.upper()}"
    if not _KEY_RE.match(k):
        raise UsageError(f"not a lease key: {key!r} (expected e.g. device:<UDID>, "
                         f"sim:<UDID> or wda:127.0.0.1:8100)")
    return k


def device_key(udid: str) -> str:
    return normalize_key(f"device:{udid}")


def sim_key(udid: str) -> str:
    return normalize_key(f"sim:{udid}")


def wda_key(host: str, port: int) -> str:
    return normalize_key(f"wda:{host}:{int(port)}")


def norm_label(label: Any) -> str:
    """Agent labels are compared trimmed and case-folded: agents pass
    "Explorer" on one call and "explorer" on the next."""
    return str(label or "").strip().casefold()[:32]


def mono() -> float:
    """Deadlines use CLOCK_MONOTONIC. On macOS time.monotonic() is
    mach_absolute_time, which stops while the Mac sleeps."""
    return time.clock_gettime(time.CLOCK_MONOTONIC)


def iso(wall: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(wall))


def _hhmm(wall: float) -> str:
    return time.strftime("%H:%M", time.localtime(wall))


def _r(x: float) -> float:
    return round(float(x), 3)


# ---- Process adapter (ctypes, macOS) ------------------------------------------

Proc = namedtuple("Proc", "pid uniq")          # one process, unique within a boot
ProcInfo = namedtuple("ProcInfo", "pid ppid uid uniq comm")

_PROC_PIDT_SHORTBSDINFO = 13
_PROC_PIDUNIQIDENTIFIERINFO = 17
_PROC_PIDVNODEPATHINFO = 9
_CTL_KERN, _KERN_PROCARGS2 = 1, 49
_SZOMB = 5


class _UniqInfo(ctypes.Structure):          # struct proc_uniqidentifierinfo
    _fields_ = [("p_uuid", ctypes.c_uint8 * 16), ("p_uniqueid", ctypes.c_uint64),
                ("p_puniqueid", ctypes.c_uint64), ("p_idversion", ctypes.c_int32),
                ("p_reserve2", ctypes.c_uint32), ("p_reserve3", ctypes.c_uint64),
                ("p_reserve4", ctypes.c_uint64)]


class _ShortInfo(ctypes.Structure):         # struct proc_bsdshortinfo
    _fields_ = [("pbsi_pid", ctypes.c_uint32), ("pbsi_ppid", ctypes.c_uint32),
                ("pbsi_pgid", ctypes.c_uint32), ("pbsi_status", ctypes.c_uint32),
                ("pbsi_comm", ctypes.c_char * 16), ("pbsi_flags", ctypes.c_uint32),
                ("pbsi_uid", ctypes.c_uint32), ("pbsi_gid", ctypes.c_uint32),
                ("pbsi_ruid", ctypes.c_uint32), ("pbsi_rgid", ctypes.c_uint32),
                ("pbsi_svuid", ctypes.c_uint32), ("pbsi_svgid", ctypes.c_uint32),
                ("pbsi_rfu", ctypes.c_uint32)]


_LIBS: Dict[str, Any] = {}


def _libs() -> Tuple[Any, Any]:
    if not _LIBS:
        try:
            proc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            libc = ctypes.CDLL(None, use_errno=True)
        except OSError as e:
            raise StateError(f"device leases need macOS's libproc ({e})")
        proc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                      ctypes.c_void_p, ctypes.c_int]
        proc.proc_pidinfo.restype = ctypes.c_int
        proc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        proc.proc_pidpath.restype = ctypes.c_int
        libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                                ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p,
                                ctypes.c_size_t]
        libc.sysctlbyname.argtypes = [ctypes.c_char_p, ctypes.c_void_p,
                                      ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p,
                                      ctypes.c_size_t]
        _LIBS["proc"], _LIBS["libc"] = proc, libc
    return _LIBS["proc"], _LIBS["libc"]


def proc_unique(pid: int) -> Optional[Tuple[int, int]]:
    """(p_uniqueid, p_puniqueid), or None. This flavor works for any uid, and
    the kernel refuses it (ESRCH) for a zombie, so a zombie reads as dead."""
    # ctypes cuts big pids to 32 bits; refuse them.
    if not isinstance(pid, int) or isinstance(pid, bool) or not 0 < pid < 2 ** 31:
        return None
    proc, _ = _libs()
    info = _UniqInfo()
    n = proc.proc_pidinfo(pid, _PROC_PIDUNIQIDENTIFIERINFO, 0, ctypes.byref(info),
                          ctypes.sizeof(info))
    if n != ctypes.sizeof(info):
        return None                         # ESRCH, EPERM: not this process
    return int(info.p_uniqueid), int(info.p_puniqueid)


def proc_info(pid: int) -> Optional[ProcInfo]:
    """pid, ppid, uid, uniqueid and short name; None if gone or a zombie."""
    u = proc_unique(pid)
    if u is None:
        return None
    proc, _ = _libs()
    info = _ShortInfo()
    n = proc.proc_pidinfo(pid, _PROC_PIDT_SHORTBSDINFO, 0, ctypes.byref(info),
                          ctypes.sizeof(info))
    if n != ctypes.sizeof(info) or info.pbsi_status == _SZOMB:
        return None
    comm = info.pbsi_comm.decode("utf-8", "replace")
    return ProcInfo(pid, int(info.pbsi_ppid), int(info.pbsi_uid), u[0], comm)


def proc_alive(pid: Any, uniqueid: Optional[int] = None) -> bool:
    """True if `pid` is a live, non-zombie process, and (when given) still the
    same process. kill(pid, 0) is not enough: it succeeds on zombies, and a
    pid can be reused. Also the devices.json owner check (owner_uniqueid)."""
    u = proc_unique(pid) if isinstance(pid, int) else None
    if u is None:
        return False
    return uniqueid is None or u[0] == int(uniqueid)


def proc_path(pid: int) -> str:
    proc, _ = _libs()
    buf = ctypes.create_string_buffer(4096)
    n = proc.proc_pidpath(pid, buf, 4096)
    return buf.value.decode("utf-8", "replace") if n > 0 else ""


def proc_argv(pid: int) -> List[str]:
    """argv via sysctl KERN_PROCARGS2 (same uid only; [] otherwise). ps shows
    claude's p_comm as its version string, so argv[0] is the reliable name."""
    _, libc = _libs()
    mib = (ctypes.c_int * 3)(_CTL_KERN, _KERN_PROCARGS2, pid)
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or size.value < 4:
        return []
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        return []
    raw = buf.raw[:size.value]
    argc = struct.unpack_from("i", raw, 0)[0]
    rest = raw[4:]
    nul = rest.find(b"\0")                  # skip the exec path
    if nul < 0:
        return []
    parts = rest[nul:].lstrip(b"\0").split(b"\0")
    return [p.decode("utf-8", "replace") for p in parts[:max(0, argc)]]


def proc_argv0(pid: int) -> str:
    argv = proc_argv(pid)
    return argv[0] if argv else ""


def proc_cwd(pid: int) -> str:
    """Working directory of a same-uid process (struct proc_vnodepathinfo:
    pvi_cdir's path sits after a 152-byte vnode_info)."""
    proc, _ = _libs()
    buf = ctypes.create_string_buffer(2352)
    if proc.proc_pidinfo(pid, _PROC_PIDVNODEPATHINFO, 0, buf, 2352) <= 0:
        return ""
    return buf.raw[152:152 + 1024].split(b"\0")[0].decode("utf-8", "replace")


def boot_session_id() -> str:
    """kern.bootsessionuuid: holds and tickets from another boot mean nothing."""
    _, libc = _libs()
    buf = ctypes.create_string_buffer(64)
    size = ctypes.c_size_t(64)
    if libc.sysctlbyname(b"kern.bootsessionuuid", buf, ctypes.byref(size), None, 0) != 0:
        return ""
    return buf.value.decode("ascii", "replace")


def ancestry(pid: Optional[int] = None) -> List[ProcInfo]:
    """The process and its live ancestors, nearest first, ending at launchd.
    Stops early at an unreadable process: what we cannot see cannot anchor."""
    out: List[ProcInfo] = []
    cur = os.getpid() if pid is None else pid
    seen = set()
    while cur > 0 and cur not in seen and len(out) < 64:
        seen.add(cur)
        info = proc_info(cur)
        if info is None:
            break
        out.append(info)
        if cur == 1:
            break
        cur = info.ppid
    return out


def _my_uid() -> int:
    return os.getuid()


def _owner_uid() -> int:
    return os.getuid()                      # a seam: tests fake a wrong owner


# ---- Identity -----------------------------------------------------------------

def is_claude(path: str, argv0: str) -> bool:
    """A Claude Code process: its binary lives under */claude/versions/* (or is
    named claude), AND argv[0] is claude. The second test drops the helpers
    Claude re-execs from the same binary, such as ugrep."""
    if not path:
        return False
    in_versions = "/claude/versions/" in path
    if not (in_versions or os.path.basename(path) == "claude"):
        return False
    return os.path.basename(argv0 or "") == "claude"


def is_imirror_app(path: str) -> bool:
    return "/iMirror.app/Contents/" in (path or "")


def _claude_at(pid: int, path_of: Callable[[int], str], argv0_of: Callable[[int], str]) -> bool:
    path = path_of(pid)
    if "/claude/versions/" not in path and os.path.basename(path) != "claude":
        return False                        # skip the argv sysctl for most processes
    return is_claude(path, argv0_of(pid))


def find_anchor(chain: Sequence[ProcInfo], anchor_pid: Optional[int] = None, *,
                my_uid: int, path_of: Callable[[int], str] = proc_path,
                argv0_of: Callable[[int], str] = proc_argv0) -> Tuple[ProcInfo, str]:
    """Pick the process a hold is anchored to, and its kind.

    1. --anchor-pid, which must be in the caller's chain ("run", or "app"
       when it is the iMirror app);
    2. else the nearest Claude ancestor ("session");
    3. else the highest same-uid ancestor below a foreign-uid process or
       launchd, which is the terminal tab's shell ("terminal").
    Never pid 1, never another uid, never the caller itself unless named.
    """
    if not chain:
        raise Unkeyable("cannot read this process's ancestry")
    if anchor_pid is not None:
        for p in chain:
            if p.pid == anchor_pid:
                if p.pid <= 1 or p.uid != my_uid:
                    raise Unkeyable(f"--anchor-pid {anchor_pid} is launchd or another "
                                    f"user's process")
                return p, ("app" if is_imirror_app(path_of(p.pid)) else "run")
        raise Unkeyable(f"--anchor-pid {anchor_pid} is not this process or one of "
                        f"its ancestors")
    for p in chain[1:]:
        if p.pid <= 1 or p.uid != my_uid:
            break
        if _claude_at(p.pid, path_of, argv0_of):
            return p, "session"
    top = None
    for p in chain[1:]:
        if p.pid <= 1 or p.uid != my_uid:
            break
        top = p
    if top is None:
        raise Unkeyable("no ancestor of this process can hold a device lease; pass "
                        "--anchor-pid with a long-lived process of yours")
    return top, "terminal"


def nearest_claude(chain: Sequence[ProcInfo], *, my_uid: int,
                   path_of: Callable[[int], str] = proc_path,
                   argv0_of: Callable[[int], str] = proc_argv0) -> Optional[ProcInfo]:
    for p in chain[1:]:
        if p.pid <= 1:
            break
        if p.uid == my_uid and _claude_at(p.pid, path_of, argv0_of):
            return p
    return None


@dataclasses.dataclass(frozen=True)
class Caller:
    """Who is asking. `chain` is the caller's REAL process chain, nearest
    first; coverage is decided on it, not on the anchor, so run.sh's own
    antsignalctl is covered by run.sh even though its nearest Claude
    ancestor is the session that started run.sh."""
    chain: Tuple[Proc, ...]
    anchor: Proc
    kind: str = "session"                   # session | run | terminal | app
    anchor_name: str = ""
    label: str = ""
    client: str = "cli"                     # cli | mcp (the label rule differs)
    via: str = ""
    cwd: str = ""
    covered_only: bool = False              # IMIRROR_LEASE_CONTEXT=run
    orphaned: bool = False                  # a covering anchor died under us

    @property
    def ancestors(self) -> Tuple[Proc, ...]:
        if self.anchor in self.chain:
            return self.chain[self.chain.index(self.anchor) + 1:]
        return ()


def build_caller(*, anchor_pid: Optional[int] = None, label: str = "", client: str = "cli",
                 via: str = "", covered_only: bool = False,
                 pid: Optional[int] = None) -> Caller:
    infos = ancestry(pid)
    p, kind = find_anchor(infos, anchor_pid, my_uid=_my_uid())
    try:
        cwd = os.getcwd()
    except OSError:
        cwd = ""
    chain = tuple(Proc(i.pid, i.uniq) for i in infos if i.pid > 1)
    return Caller(chain=chain, anchor=Proc(p.pid, p.uniq), kind=kind, anchor_name=p.comm,
                  label=norm_label(label), client=client, via=via, cwd=cwd,
                  covered_only=covered_only)


# ---- Configuration ------------------------------------------------------------

@dataclasses.dataclass(frozen=True)
class Config:
    idle_s: float = 300.0                   # auto holds lapse after this idle
    terminal_idle_s: float = 90.0           # a person at a shell
    app_idle_s: float = 60.0                # a person clicking in the mirror
    agent_ceiling_s: float = 1200.0         # agent holds: used within 20 min
    explicit_min_s: float = 60.0
    explicit_max_s: float = 3600.0
    reserve_max_s: float = 21600.0          # --anchor-pid script reservations
    claim_live_s: float = 90.0              # grant to a waiter seen recently
    claim_absent_s: float = 10.0            # grant to a waiter not seen lately
    claim_seen_s: float = 30.0
    ticket_s: float = 180.0                 # a ticket nobody refreshes dies
    seen_refresh_s: float = 15.0
    autowait_s: float = 20.0                # auto calls wait only this long
    tombstone_s: float = 600.0              # after a break by the user
    push_depth: int = 4
    touch_s: float = 0.0                    # renew last_used at most this often
    ended_keep_s: float = 86400.0
    covered_cap: int = 16
    mcp_wait_cap_s: float = 85.0            # Claude Code backgrounds at 120 s
    boot: Optional[str] = None
    wall_offset: float = 0.0                # wall = mono + wall_offset


def _wall(cfg: Config, m: float) -> float:
    return m + cfg.wall_offset


# ---- Pure core: state helpers -------------------------------------------------

_STAMP_FIELDS = ("updated_at", "writer")
_ANCHOR_GONE = "anchor-gone"


def _clone(x: Any) -> Any:
    return json.loads(json.dumps(x))


def _canon(state: Dict[str, Any]) -> str:
    return json.dumps({k: v for k, v in state.items() if k not in _STAMP_FIELDS},
                      sort_keys=True, ensure_ascii=False)


def _with_defaults(st: Dict[str, Any]) -> Dict[str, Any]:
    proto = st.get("protocol", PROTOCOL)
    if not isinstance(proto, int) or proto > PROTOCOL:
        raise StateError(f"the lease file uses protocol {proto!r}, newer than this "
                         f"server's {PROTOCOL}; restart this session's MCP")
    st["protocol"] = PROTOCOL
    for name, empty in (("keys", {}), ("tickets", []), ("ended", [])):
        if not isinstance(st.get(name), type(empty)):
            st[name] = type(empty)()
    if not isinstance(st.get("seq"), int):
        st["seq"] = 0
    for key, ks in list(st["keys"].items()):
        if not isinstance(ks, dict):
            st["keys"][key] = ks = {}
        if not isinstance(ks.get("holders"), list):
            ks["holders"] = []
        ks["holders"] = [e for e in ks["holders"] if _entry_ok(e)]
        if not isinstance(ks.get("epoch"), int):
            ks["epoch"] = 0
        ks.setdefault("last_release", None)
        ks.setdefault("tombstone", None)
    st["tickets"] = [t for t in st["tickets"] if _entry_ok(t) and isinstance(t.get("keys"), list)]
    return st


def _entry_ok(e: Any) -> bool:
    a = e.get("anchor") if isinstance(e, dict) else None
    return isinstance(a, dict) and isinstance(a.get("pid"), int) and isinstance(a.get("uniqueid"), int)


def _anchor(e: Dict[str, Any]) -> Proc:
    return Proc(e["anchor"]["pid"], e["anchor"]["uniqueid"])


def _ancestors(e: Dict[str, Any]) -> List[Proc]:
    return [Proc(p[0], p[1]) for p in e.get("ancestors") or []
            if isinstance(p, list) and len(p) == 2]


def _key_rec(st: Dict[str, Any], key: str) -> Dict[str, Any]:
    ks = st["keys"].get(key)
    if ks is None:
        ks = st["keys"][key] = {"holders": [], "epoch": 0, "last_release": None,
                                "tombstone": None}
    return ks


def _empty_key() -> Dict[str, Any]:
    return {"holders": [], "epoch": 0, "last_release": None, "tombstone": None}


def _expiry(e: Dict[str, Any], cfg: Config) -> float:
    """When this hold lapses if nobody touches it again. Agent holds also stop
    20 min after their last use, whatever hold_s said: reserving "to be safe"
    must not keep a phone for an hour."""
    if e.get("claim_until_mono") is not None:
        return float(e["claim_until_mono"])
    last = float(e.get("last_used_mono") or 0)
    exp = max(float(e.get("hold_until_mono") or 0), last + float(e.get("idle_s") or cfg.idle_s))
    if e.get("mode") != "reserve":
        exp = min(exp, last + cfg.agent_ceiling_s)
    return exp


def _invalid_reason(e: Dict[str, Any], now: float, alive: Callable[[Proc], bool],
                    cfg: Config) -> Optional[str]:
    a = _anchor(e)
    if a.pid <= 1 or not alive(a):
        return _ANCHOR_GONE
    if e.get("frozen"):
        return None                         # a suspended hold does not age
    if e.get("claim_until_mono") is not None and now >= float(e["claim_until_mono"]):
        return "claim-expired"
    if now >= _expiry(e, cfg):
        return "expired"
    return None


def _summary(e: Dict[str, Any], now: float, cfg: Config) -> Dict[str, Any]:
    """The holder as other agents see it (contract C1's `holder`)."""
    frozen = bool(e.get("frozen"))
    if "seq" in e:                          # a waiting ticket, not a hold
        return {"purpose": e.get("purpose") or "", "via": e.get("via") or "",
                "cwd": e.get("cwd") or "", "pid": _anchor(e).pid, "kind": e.get("kind") or "",
                "since": e.get("since") or "", "idle_s": 0, "until": None, "eta_s": None,
                "waiting": True}
    if frozen:                              # what it gets back when restored
        left = float((e.get("frozen") or {}).get("hold_left_s") or 0)
        exp = now + max(left, float(e.get("idle_s") or cfg.idle_s))
    else:
        exp = _expiry(e, cfg)
    out = {"purpose": e.get("purpose") or "", "via": e.get("via") or "",
           "cwd": e.get("cwd") or "", "pid": _anchor(e).pid, "kind": e.get("kind") or "",
           "since": e.get("since") or "",
           "idle_s": 0 if frozen else int(max(0.0, now - float(e.get("last_used_mono") or now))),
           "until": iso(_wall(cfg, exp)), "eta_s": int(max(0.0, math.ceil(exp - now)))}
    if e.get("label"):
        out["label"] = e["label"]
    if frozen:
        out["suspended"] = True
    return out


def _release_record(e: Dict[str, Any], reason: str, now: float, cfg: Config,
                    note: str = "") -> Dict[str, Any]:
    rec = {"at": iso(_wall(cfg, now)), "at_mono": _r(now), "reason": reason,
           "lease_id": e.get("lease_id"),
           "holder": {"purpose": e.get("purpose") or "", "via": e.get("via") or "",
                      "pid": _anchor(e).pid, "kind": e.get("kind") or "",
                      "cwd": e.get("cwd") or ""}}
    if note:
        rec["note"] = note
    return rec


def _event(name: str, **fields: Any) -> Dict[str, Any]:
    return {"event": name, **{k: v for k, v in fields.items() if v not in (None, "")}}


def _unfreeze(e: Dict[str, Any], now: float) -> None:
    """Restore a suspended hold with a fresh idle window and the hold time it
    had left, under its ORIGINAL lease_id, so its owner sees no LOST."""
    fz = e.get("frozen") or {}
    left = float(fz.get("hold_left_s") or 0)
    e["frozen"] = None
    e["claim_until_mono"] = None
    e["last_used_mono"] = _r(now)
    e["hold_until_mono"] = _r(now + left) if left > 0 else 0.0


def _freeze(e: Dict[str, Any], now: float) -> None:
    left = max(0.0, float(e.get("hold_until_mono") or 0) - now)
    e["frozen"] = {"at_mono": _r(now), "hold_left_s": _r(left)}


def _remember_ended(st: Dict[str, Any], key: str, e: Dict[str, Any], now: float) -> None:
    """A dead anchor's covered children are now orphans. Remember them so a
    later CLI call from one of them is refused, not granted (kill -9 run.sh)."""
    covered = [c for c in e.get("covered") or [] if isinstance(c, list) and len(c) == 2]
    if covered:
        st["ended"].append({"key": key, "lease_id": e.get("lease_id"),
                            "anchor": [_anchor(e).pid, _anchor(e).uniq],
                            "covered": covered, "at_mono": _r(now)})


# ---- Pure core: normalize -----------------------------------------------------

def normalize(state: Dict[str, Any], now: float, alive: Callable[[Proc], bool],
              cfg: Config) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    """Bring the state up to `now`: drop holds whose anchor died or which
    lapsed, restore suspended holds underneath, expire tickets and tombstones,
    and grant waiting tickets in per-key FIFO order. Unknown fields survive,
    because older and newer servers share this file."""
    st = _with_defaults(_clone(state))
    events: List[Dict[str, Any]] = []
    if cfg.boot and st.get("boot") != cfg.boot:
        if st.get("boot") and (st["tickets"] or any(ks["holders"] for ks in st["keys"].values())):
            events.append(_event("boot-reset", note=f"was {st.get('boot')}"))
        for ks in st["keys"].values():
            ks["holders"], ks["tombstone"] = [], None
        st["tickets"], st["ended"] = [], []
        st["boot"] = cfg.boot

    for key, ks in st["keys"].items():
        holders = ks["holders"]
        kept = []
        for e in holders[:-1]:              # suspended entries die with their anchor
            a = _anchor(e)
            if a.pid > 1 and alive(a):
                kept.append(e)
            else:
                _remember_ended(st, key, e, now)
                events.append(_event(_ANCHOR_GONE, key=key, lease_id=e.get("lease_id"), pid=a.pid))
        if holders:
            kept.append(holders[-1])
        ks["holders"] = holders = kept
        while holders:
            top = holders[-1]
            if top.get("frozen"):
                _unfreeze(top, now)
                events.append(_event("restored", key=key, lease_id=top.get("lease_id")))
            reason = _invalid_reason(top, now, alive, cfg)
            if reason is None:
                break
            holders.pop()
            ks["last_release"] = _release_record(top, reason, now, cfg)
            if reason == _ANCHOR_GONE:
                _remember_ended(st, key, top, now)
            events.append(_event(reason, key=key, lease_id=top.get("lease_id"),
                                 pid=_anchor(top).pid, purpose=top.get("purpose")))
        for e in holders:                   # forget covered children that died
            if e.get("covered"):
                e["covered"] = [c for c in e["covered"] if alive(Proc(c[0], c[1]))]
        tb = ks.get("tombstone")
        if tb and now >= float(tb.get("until_mono") or 0):
            ks["tombstone"] = None

    live_tickets = []
    for t in st["tickets"]:
        a = _anchor(t)
        if a.pid <= 1 or not alive(a):
            events.append(_event("ticket-dropped", ticket=t.get("ticket"), reason=_ANCHOR_GONE))
        elif now - float(t.get("seen_mono") or 0) > cfg.ticket_s:
            events.append(_event("ticket-dropped", ticket=t.get("ticket"), reason="not-seen"))
        else:
            live_tickets.append(t)
    st["tickets"] = live_tickets

    ended = []
    for rec in st["ended"]:
        if not isinstance(rec, dict):
            continue
        rec["covered"] = [c for c in rec.get("covered") or []
                          if isinstance(c, list) and len(c) == 2 and alive(Proc(c[0], c[1]))]
        if rec["covered"] and now - float(rec.get("at_mono") or 0) < cfg.ended_keep_s:
            ended.append(rec)
    st["ended"] = ended[-32:]

    _grant_tickets(st, now, cfg, events)

    for key in list(st["keys"]):
        ks = st["keys"][key]
        lr = ks.get("last_release")
        stale = lr is None or now - float(lr.get("at_mono") or 0) > cfg.ended_keep_s
        known = {"holders", "epoch", "last_release", "tombstone"}
        if not ks["holders"] and not ks.get("tombstone") and stale and set(ks) <= known \
                and not any(key in t["keys"] for t in st["tickets"]):
            del st["keys"][key]
    return st, events


def _idle_for(kind: str, cfg: Config) -> float:
    if kind == "terminal":
        return cfg.terminal_idle_s
    if kind == "app":
        return cfg.app_idle_s
    return cfg.idle_s


def _grant_tickets(st: Dict[str, Any], now: float, cfg: Config,
                   events: List[Dict[str, Any]]) -> None:
    """Per-key FIFO: a ticket is granted when all its keys are free and it is
    the oldest live ticket on each. An earlier two-phone ticket keeps its free
    phone, so a stream of one-phone tickets cannot starve it."""
    reserved = set()
    remaining = []
    for t in sorted(st["tickets"], key=lambda t: int(t.get("seq") or 0)):
        keys = list(t["keys"])
        free = all(not (st["keys"].get(k) or {}).get("holders") and k not in reserved
                   for k in keys)
        if not free:
            reserved.update(keys)
            remaining.append(t)
            continue
        window = (cfg.claim_live_s if now - float(t.get("seen_mono") or 0) <= cfg.claim_seen_s
                  else cfg.claim_absent_s)
        for k in keys:
            ks = _key_rec(st, k)
            ks["epoch"] += 1
            e = {k2: v for k2, v in t.items()
                 if k2 not in ("ticket", "seq", "keys", "enqueued_mono", "seen_mono", "hold_s")}
            hold = float(t.get("hold_s") or 0)
            e.update({"lease_id": t.get("grant_id") or t.get("ticket"), "epoch": ks["epoch"],
                      "since": iso(_wall(cfg, now)), "since_mono": _r(now),
                      "last_used_mono": _r(now),
                      "hold_until_mono": _r(now + hold) if hold > 0 else 0.0,
                      "idle_s": _idle_for(t.get("kind") or "", cfg),
                      "claim_until_mono": _r(now + window), "frozen": None, "covered": []})
            e.pop("grant_id", None)
            ks["holders"].append(e)
        events.append(_event("granted", keys=",".join(keys), ticket=t.get("ticket"),
                             pid=_anchor(t).pid, purpose=t.get("purpose")))
    st["tickets"] = remaining


# ---- Pure core: decide --------------------------------------------------------

@dataclasses.dataclass(frozen=True)
class Request:
    """One question for decide(). op: ensure (auto drive), acquire (explicit
    or reserve), inspect (never takes a hold), renew (own hold only), touch
    (heartbeat: renew-only by lease id), release, break."""
    op: str
    keys: Tuple[str, ...]
    mode: str = "auto"                      # auto | explicit | reserve
    hold_s: float = 0.0
    wait: bool = False                      # only explicit waits make tickets
    purpose: str = ""
    believed: Optional[Dict[str, Dict[str, Any]]] = None
    reason: str = ""
    all_keys: bool = False
    tickets_only: bool = False
    keep_ids: Tuple[str, ...] = ()          # release: leave these leases alone
    exact_label: bool = False               # release: "" means unlabelled only


@dataclasses.dataclass
class Outcome:
    status: str                             # held covered queued busy deadlock lost
    keys: Tuple[str, ...]                   # not_held released broken freed_by_user
    code: Optional[str] = None
    lease_id: str = ""
    lease_ids: Dict[str, str] = dataclasses.field(default_factory=dict)
    epochs: Dict[str, int] = dataclasses.field(default_factory=dict)
    covered_by: Dict[str, Dict[str, Any]] = dataclasses.field(default_factory=dict)
    until_mono: Optional[float] = None
    blocked_on: List[Dict[str, Any]] = dataclasses.field(default_factory=list)
    reasons: Dict[str, str] = dataclasses.field(default_factory=dict)
    eta_s: Optional[float] = None
    autowait: bool = False
    retry_after_s: Optional[int] = None
    position: Optional[int] = None
    ticket: Optional[str] = None
    released: List[str] = dataclasses.field(default_factory=list)
    message: str = ""
    changed: bool = False
    wall_offset: float = 0.0

    @property
    def ok(self) -> bool:
        return self.status in ("held", "covered", "released", "broken", "not_held")

    def to_json(self, now: Optional[float] = None) -> Dict[str, Any]:
        """The CLI's one JSON object (contract C1)."""
        out: Dict[str, Any] = {"ok": self.ok, "protocol": PROTOCOL, "status": self.status,
                               "keys": list(self.keys)}
        if self.ok:
            out["lease_id"] = self.lease_id
            if self.until_mono is not None:
                t = mono() if now is None else now
                out["until"] = iso(self.until_mono + self.wall_offset)
                out["expires_in_s"] = int(max(0, math.floor(self.until_mono - t)))
            if self.released:
                out["released"] = list(self.released)
            if self.message:
                out["message"] = self.message
        else:
            out["code"] = self.code or "DEVICE_BUSY"
            out["message"] = self.message
            out["blocked_on"] = [{"key": b["key"], "holder": b.get("holder") or {}}
                                 for b in self.blocked_on]
            out["retry_after_s"] = self.retry_after_s
            if self.position is not None:
                out["position"] = self.position
        return out


_OK = ("grant", "renew", "covered", "push", "free")
_CODES = {"busy": "DEVICE_BUSY", "queued": "DEVICE_BUSY", "deadlock": "DEVICE_DEADLOCK",
          "lost": "DEVICE_RESERVATION_LOST", "freed_by_user": "DEVICE_FREED_BY_USER"}
_MODE_RANK = {"auto": 0, "explicit": 1, "reserve": 2}


def _same_ident(t: Dict[str, Any], me: Caller) -> bool:
    return _anchor(t) == me.anchor and norm_label(t.get("label")) == me.label


def _my_ticket(st: Dict[str, Any], me: Caller, keys: Sequence[str]) -> Optional[Dict[str, Any]]:
    want = sorted(keys)
    for t in st["tickets"]:
        if _same_ident(t, me) and sorted(t["keys"]) == want:
            return t
    return None


def _tickets_ahead(st: Dict[str, Any], key: str, me: Caller,
                   my_seq: Optional[int]) -> List[Dict[str, Any]]:
    """Other waiters' tickets on `key` that come before me. A caller's own
    tickets never block it."""
    return [t for t in sorted(st["tickets"], key=lambda t: int(t.get("seq") or 0))
            if key in t["keys"] and not _same_ident(t, me)
            and (my_seq is None or int(t.get("seq") or 0) < my_seq)]


def _tombstoned(ks: Dict[str, Any], me: Caller, now: float) -> Optional[Dict[str, Any]]:
    tb = ks.get("tombstone")
    if not tb or now >= float(tb.get("until_mono") or 0):
        return None
    chain = set(me.chain) | {me.anchor}
    for a in tb.get("anchors") or []:
        if isinstance(a, list) and len(a) == 2 and Proc(a[0], a[1]) in chain:
            return tb
    return None


def _orphan_by_record(st: Dict[str, Any], me: Caller) -> bool:
    chain = set(me.chain)
    for rec in st["ended"]:
        for c in rec.get("covered") or []:
            if Proc(c[0], c[1]) in chain:
                return True
    return False


def _label_verdict(top: Dict[str, Any], me: Caller) -> Optional[str]:
    """Subagents of one session share an anchor; labels are what tell them
    apart. An unlabelled MCP call may not ride a labelled hold (CLI calls
    such as antsignalctl cannot carry a label, so they may)."""
    hl = norm_label(top.get("label"))
    if hl and me.label and hl != me.label:
        return "subagent"
    if hl and not me.label and me.client == "mcp":
        return "label"
    return None


def _eval_key(st: Dict[str, Any], key: str, req: Request, me: Caller, now: float,
              cfg: Config, my_seq: Optional[int]) -> Tuple[str, str, Optional[Dict[str, Any]]]:
    """(verdict, reason, entry) for one key. Order: coverage on the real chain,
    the user's break, LOST, same-anchor renew and labels, "a run you started",
    then foreign holders and the queue."""
    ks = st["keys"].get(key) or _empty_key()
    holders = ks["holders"]
    top = holders[-1] if holders else None
    chain = set(me.chain)
    bl = (req.believed or {}).get(key)
    ids = [e.get("lease_id") for e in holders]

    if req.op == "renew":
        if _tombstoned(ks, me, now):
            return "freed", "tombstone", None
        if top is not None and _anchor(top) == me.anchor and _label_verdict(top, me) is None:
            return "renew", "", top
        if any(_anchor(e) == me.anchor for e in holders):
            return "busy", "descendant", top
        return "lost", "gone", None

    # 1. Coverage: a hold on my real ancestor covers me.
    if top is not None and _anchor(top) != me.anchor and _anchor(top) in chain:
        if req.op == "acquire" and req.mode == "reserve":
            if len(holders) >= cfg.push_depth:
                return "busy", "depth", top
            return "push", "", top
        return "covered", "", top

    if _tombstoned(ks, me, now):
        return "freed", "tombstone", None

    # 2. LOST: my lease is nowhere in the stack.
    if req.op == "touch":
        if bl is None:
            return "lost", "gone", None
        if top is not None and top.get("lease_id") == bl.get("lease_id"):
            return "renew", "", top
        if bl.get("lease_id") in ids:
            return "busy", "descendant", top
        return "lost", "gone", None
    if bl is not None and bl.get("lease_id") not in ids:
        same_top = top is not None and _anchor(top) == me.anchor
        regrant = (top is None and ks["epoch"] == bl.get("epoch")
                   and not _tickets_ahead(st, key, me, my_seq))
        if not same_top and not regrant:
            return "lost", "gone", top

    # 3. Same anchor: renew, unless the label rule says otherwise.
    if top is not None and _anchor(top) == me.anchor:
        lv = _label_verdict(top, me)
        if lv:
            return "busy", lv, top
        return "renew", "", top

    # 4. My own run holds it; mine may be suspended.
    if top is not None and (any(_anchor(e) == me.anchor for e in holders[:-1])
                            or me.anchor in _ancestors(top)):
        return "busy", "descendant", top

    # Covered-only callers and orphans never take a hold by themselves.
    if req.mode == "auto" and req.op in ("ensure", "inspect"):
        if me.covered_only:
            return "lost", "covered-only", top
        if me.orphaned or _orphan_by_record(st, me):
            return "lost", "orphan", top

    # 5. Foreign holder, a waiter ahead of me, or free.
    if top is not None:
        return "busy", "foreign", top
    ahead = _tickets_ahead(st, key, me, my_seq)
    if ahead:
        return "busy", "ticket-ahead", ahead[0]
    if req.op == "inspect":
        return "free", "", None
    return "grant", "", None


def _clamp_hold(req: Request, cfg: Config) -> float:
    if req.hold_s is None or req.hold_s <= 0:
        return 0.0
    top = cfg.reserve_max_s if req.mode == "reserve" else cfg.explicit_max_s
    return float(min(max(float(req.hold_s), cfg.explicit_min_s), top))


def _new_entry(lease_id: str, epoch: int, me: Caller, req: Request, now: float,
               cfg: Config) -> Dict[str, Any]:
    hold = _clamp_hold(req, cfg)
    return {"lease_id": lease_id, "epoch": epoch,
            "anchor": {"pid": me.anchor.pid, "uniqueid": me.anchor.uniq,
                       "name": me.anchor_name},
            "ancestors": [[p.pid, p.uniq] for p in me.ancestors],
            "kind": me.kind, "label": me.label,
            "mode": "auto" if req.op == "ensure" else req.mode,
            "via": me.via, "purpose": req.purpose, "cwd": me.cwd,
            "since": iso(_wall(cfg, now)), "since_mono": _r(now), "last_used_mono": _r(now),
            "hold_until_mono": _r(now + hold) if hold else 0.0,
            "idle_s": _idle_for(me.kind, cfg), "claim_until_mono": None, "frozen": None,
            "covered": []}


def _touch(e: Dict[str, Any], now: float, cfg: Config) -> None:
    """Refresh last_used, but not on every call: a write per tap would make
    40 servers fight over one flock for no gain."""
    every = min(cfg.touch_s, float(e.get("idle_s") or cfg.idle_s) / 4.0)
    if now - float(e.get("last_used_mono") or 0) >= every:
        e["last_used_mono"] = _r(now)


def _renew(e: Dict[str, Any], req: Request, now: float, cfg: Config) -> None:
    if e.get("claim_until_mono") is not None:
        e["claim_until_mono"] = None        # the waiter claimed its grant
        e["last_used_mono"] = _r(now)
    _touch(e, now, cfg)
    hold = _clamp_hold(req, cfg) if req.op in ("ensure", "acquire", "renew") else 0.0
    if hold:
        until = _r(now + hold)
        if req.op == "renew":
            e["hold_until_mono"] = until    # run.sh re-reserves per scenario
        else:
            e["hold_until_mono"] = max(float(e.get("hold_until_mono") or 0), until)
    if req.op == "acquire" and _MODE_RANK.get(req.mode, 0) > _MODE_RANK.get(e.get("mode"), 0):
        e["mode"] = req.mode
    if req.purpose and req.op != "touch":
        e["purpose"] = req.purpose


def _record_covered(e: Dict[str, Any], me: Caller, cfg: Config) -> None:
    """Note which child of the holder's anchor I descend from. If the anchor
    is later killed, that child is an orphan and must not be granted."""
    a = _anchor(e)
    if a not in me.chain:
        return
    i = me.chain.index(a)
    if i == 0:
        return
    c = [me.chain[i - 1].pid, me.chain[i - 1].uniq]
    cov = e.setdefault("covered", [])
    if c not in cov:
        cov.append(c)
        del cov[:-cfg.covered_cap]


def _deadlock(st: Dict[str, Any], me: Caller, keys: Sequence[str],
              my_seq: Optional[int]) -> bool:
    """Would my waiting for `keys` close a wait-for cycle? An identity and its
    live ancestors count as one node: a session blocked in Bash on its own
    run.sh is waiting for whatever that run waits for."""
    idents: Dict[Tuple[Proc, str], List[Proc]] = {}

    def ident_of(x: Dict[str, Any]) -> Tuple[Proc, str]:
        k = (_anchor(x), norm_label(x.get("label")))
        idents.setdefault(k, _ancestors(x))
        return k

    me_id = (me.anchor, me.label)
    idents[me_id] = list(me.ancestors)
    edges: Dict[Tuple[Proc, str], set] = {}
    tickets = sorted(st["tickets"], key=lambda t: int(t.get("seq") or 0))

    def add_edges(src: Tuple[Proc, str], want: Sequence[str], seq: Optional[int]) -> None:
        for k in want:
            hs = (st["keys"].get(k) or {}).get("holders") or []
            if hs:
                edges.setdefault(src, set()).add(ident_of(hs[-1]))
            for t in tickets:
                if k in t["keys"] and (seq is None or int(t.get("seq") or 0) < seq):
                    tid = ident_of(t)
                    if tid != src:
                        edges.setdefault(src, set()).add(tid)

    for t in tickets:
        if not _same_ident(t, me):
            add_edges(ident_of(t), t["keys"], int(t.get("seq") or 0))
    add_edges(me_id, keys, my_seq)

    parent = {k: k for k in idents}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    names = list(idents)
    for a in names:
        for b in names:
            if a != b and a[0] in idents[b]:
                parent[find(b)] = find(a)
    graph: Dict[Any, set] = {}
    for src, dsts in edges.items():
        for d in dsts:
            if find(src) != find(d):
                graph.setdefault(find(src), set()).add(find(d))
    start = find(me_id)
    stack, seen = list(graph.get(start, ())), set()
    while stack:
        n = stack.pop()
        if n == start:
            return True
        if n in seen:
            continue
        seen.add(n)
        stack.extend(graph.get(n, ()))
    return False


def decide(state: Dict[str, Any], req: Request, me: Caller, now: float,
           alive: Callable[[Proc], bool], cfg: Config,
           new_id: Callable[[], str]) -> Tuple[Dict[str, Any], Outcome, List[Dict[str, Any]]]:
    """Answer one request against a state, with no I/O: (new_state, outcome,
    events). Multi-key requests are all-or-nothing. Pure, so the same call
    serves the lock-free fast path (no write when nothing changed) and the
    flock read-modify-write."""
    before = _canon(_with_defaults(_clone(state)))
    st, events = normalize(state, now, alive, cfg)
    keys = tuple(dict.fromkeys(req.keys))
    if req.op == "break":
        out = _do_break(st, req, me, now, cfg, events)
    elif req.op == "release":
        out = _do_release(st, req, me, now, alive, cfg, events)
    else:
        out = _do_acquire(st, req, keys, me, now, cfg, new_id, events)
    if out.changed or req.op in ("release", "break"):
        st, more = normalize(st, now, alive, cfg)     # grant whoever waits next
        events.extend(more)
    out.code = out.code or _CODES.get(out.status)
    out.changed = _canon(st) != before
    out.wall_offset = cfg.wall_offset
    if not out.message:
        out.message = describe(out, now=now, cfg=cfg, run_context=me.covered_only)
    return st, out, events


def _do_acquire(st: Dict[str, Any], req: Request, keys: Tuple[str, ...], me: Caller,
                now: float, cfg: Config, new_id: Callable[[], str],
                events: List[Dict[str, Any]]) -> Outcome:
    mine = _my_ticket(st, me, keys)
    my_seq = int(mine["seq"]) if mine else None
    verdicts = {k: _eval_key(st, k, req, me, now, cfg, my_seq) for k in keys}
    out = Outcome(status="busy", keys=keys)

    if all(v[0] in _OK for v in verdicts.values()):
        lease_new = ""
        any_held = False
        for k in keys:
            v, _, e = verdicts[k]
            ks = _key_rec(st, k) if v != "free" else None
            if v in ("grant", "push"):
                lease_new = lease_new or new_id()
                if v == "push":
                    _freeze(ks["holders"][-1], now)
                    events.append(_event("pushed", key=k, lease_id=ks["holders"][-1].get("lease_id")))
                ks["epoch"] += 1
                e = _new_entry(lease_new, ks["epoch"], me, req, now, cfg)
                ks["holders"].append(e)
                events.append(_event("granted", key=k, lease_id=lease_new, pid=me.anchor.pid,
                                     purpose=req.purpose, mode=e["mode"]))
            elif v == "renew":
                _renew(e, req, now, cfg)
            elif v == "covered":
                _touch(e, now, cfg)
                _record_covered(e, me, cfg)
                out.covered_by[k] = {"lease_id": e.get("lease_id"), "anchor": _anchor(e)}
            if e is not None:
                any_held = any_held or v != "covered"
                out.lease_ids[k] = e.get("lease_id") or ""
                out.epochs[k] = ks["epoch"] if ks is not None else 0
                exp = _expiry(e, cfg)
                out.until_mono = exp if out.until_mono is None else min(out.until_mono, exp)
        if req.op == "inspect" and all(v[0] == "free" for v in verdicts.values()):
            out.status = "not_held"
        else:
            out.status = "held" if any_held else "covered"
        out.lease_id = out.lease_ids.get(keys[0], "") if keys else ""
        if req.op not in ("inspect", "touch"):
            st["tickets"] = [t for t in st["tickets"]
                             if not (_same_ident(t, me) and set(t["keys"]) & set(keys))]
        out.changed = True
        return out

    fails = {k: v for k, v in verdicts.items() if v[0] not in _OK}
    kinds = {v[0] for v in fails.values()}
    worst = "freed" if "freed" in kinds else ("lost" if "lost" in kinds else "busy")
    for k, (v, reason, e) in sorted(fails.items(), key=lambda kv: kv[1][0] != worst):
        out.reasons[k] = reason
        b = {"key": k, "reason": reason, "holder": _summary(e, now, cfg) if e else None}
        if v == "freed":
            b["at"] = ((st["keys"].get(k) or {}).get("tombstone") or {}).get("at")
        out.blocked_on.append(b)
    if worst == "freed":
        out.status = "freed_by_user"
        return out
    if "lost" in kinds:
        out.status = "lost"
        return out

    etas = []
    for k, (v, reason, e) in fails.items():
        if e is not None and reason != "ticket-ahead":
            etas.append(max(0.0, _expiry(e, cfg) - now))
        else:
            etas.append(None)
    out.eta_s = None if any(x is None for x in etas) or not etas else max(etas)
    out.retry_after_s = (int(min(3600, max(1, math.ceil(out.eta_s))))
                         if out.eta_s is not None else 30)
    out.autowait = (req.op == "ensure" and out.eta_s is not None
                    and out.eta_s <= cfg.autowait_s
                    and all(r == "foreign" for r in out.reasons.values())
                    and not any(_tickets_ahead(st, k, me, None) for k in fails))

    if req.op == "acquire" and req.wait:
        if _deadlock(st, me, keys, my_seq):
            out.status = "deadlock"
            return out
        if mine is None:
            st["seq"] = int(st.get("seq") or 0) + 1
            mine = {"ticket": "t-" + new_id(), "seq": st["seq"], "keys": sorted(keys),
                    "anchor": {"pid": me.anchor.pid, "uniqueid": me.anchor.uniq,
                               "name": me.anchor_name},
                    "ancestors": [[p.pid, p.uniq] for p in me.ancestors],
                    "kind": me.kind, "label": me.label, "mode": req.mode, "via": me.via,
                    "purpose": req.purpose, "cwd": me.cwd, "hold_s": _clamp_hold(req, cfg),
                    "since": iso(_wall(cfg, now)), "enqueued_mono": _r(now),
                    "seen_mono": _r(now)}
            st["tickets"].append(mine)
            events.append(_event("queued", keys=",".join(sorted(keys)), ticket=mine["ticket"],
                                 pid=me.anchor.pid, purpose=req.purpose))
        elif now - float(mine.get("seen_mono") or 0) >= cfg.seen_refresh_s:
            mine["seen_mono"] = _r(now)
        out.status = "queued"
        out.ticket = mine["ticket"]
        seq = int(mine["seq"])
        out.position = 1 + max(len([t for t in st["tickets"] if k in t["keys"]
                                    and int(t.get("seq") or 0) < seq]) for k in keys)
        return out
    out.status = "busy"
    return out


def _do_release(st: Dict[str, Any], req: Request, me: Caller, now: float,
                alive: Callable[[Proc], bool], cfg: Config,
                events: List[Dict[str, Any]]) -> Outcome:
    """Remove only the caller's own entries (wherever they sit in a stack) and
    its own tickets. An unlabelled release frees every label of the anchor."""
    keys = tuple(sorted(st["keys"])) if req.all_keys else tuple(dict.fromkeys(req.keys))
    out = Outcome(status="not_held", keys=tuple(req.keys) if not req.all_keys else keys)

    def mine(x: Dict[str, Any]) -> bool:
        if _anchor(x) != me.anchor:
            return False
        return (not me.label and not req.exact_label) or norm_label(x.get("label")) == me.label

    def drop(e: Dict[str, Any]) -> bool:
        return mine(e) and e.get("lease_id") not in req.keep_ids

    covered = False
    if not req.tickets_only:
        for k in keys:
            ks = st["keys"].get(k)
            if not ks or not ks["holders"]:
                continue
            holders = ks["holders"]
            top = holders[-1]
            if drop(top):
                ks["last_release"] = _release_record(top, "released", now, cfg)
            gone = [e for e in holders if drop(e)]
            if gone:
                ks["holders"] = [e for e in holders if not drop(e)]
                out.released.append(k)
                for e in gone:
                    events.append(_event("released", key=k, lease_id=e.get("lease_id"),
                                         pid=me.anchor.pid))
            elif _anchor(top) in set(me.chain):
                covered = True
    before = len(st["tickets"])
    st["tickets"] = [t for t in st["tickets"]
                     if not (mine(t) and (req.all_keys or set(t["keys"]) & set(keys)))]
    dropped = before - len(st["tickets"])
    if out.released or dropped:
        out.status = "released"
        out.changed = True
    elif covered:
        out.message = ("held by the run that started you; nothing released")
    return out


def _do_break(st: Dict[str, Any], req: Request, me: Caller, now: float, cfg: Config,
              events: List[Dict[str, Any]]) -> Outcome:
    """The user takes a device back. Its holders, and their descendants, get
    FREED_BY_USER for 10 minutes instead of an instant re-grant."""
    keys = tuple(dict.fromkeys(req.keys))
    out = Outcome(status="broken", keys=keys)
    for k in keys:
        ks = st["keys"].get(k)
        if not ks or not ks["holders"]:
            continue
        anchors = [[_anchor(e).pid, _anchor(e).uniq] for e in ks["holders"]]
        top = ks["holders"][-1]
        ks["last_release"] = _release_record(top, "broken", now, cfg, note=req.reason)
        ks["tombstone"] = {"at": iso(_wall(cfg, now)), "at_mono": _r(now),
                           "until_mono": _r(now + cfg.tombstone_s), "anchors": anchors,
                           "reason": req.reason, "by": req.purpose or me.via}
        ks["holders"] = []
        out.released.append(k)
        broken = {Proc(a[0], a[1]) for a in anchors}
        st["tickets"] = [t for t in st["tickets"]
                         if not ({_anchor(t)} | set(_ancestors(t))) & broken]
        events.append(_event("broken", key=k, lease_id=top.get("lease_id"),
                             pid=_anchor(top).pid, note=req.reason))
        out.changed = True
    return out


def view(state: Dict[str, Any], me: Optional[Caller], now: float,
         alive: Callable[[Proc], bool], cfg: Config,
         keys: Iterable[str] = ()) -> Dict[str, Dict[str, Any]]:
    """Per-key display for ios_devices, `imirror-lease status` and the app:
    state is free | yours | covered | busy, plus holder, queue and position."""
    st, _ = normalize(state, now, alive, cfg)
    tickets = sorted(st["tickets"], key=lambda t: int(t.get("seq") or 0))
    out: Dict[str, Dict[str, Any]] = {}
    for k in sorted(set(keys) | set(st["keys"])):
        ks = st["keys"].get(k) or _empty_key()
        holders = ks["holders"]
        top = holders[-1] if holders else None
        waiting = [t for t in tickets if k in t["keys"]]
        if top is None:
            state_name = "free"
        elif me is not None and _anchor(top) == me.anchor and _label_verdict(top, me) is None:
            state_name = "yours"
        elif me is not None and _anchor(top) != me.anchor and _anchor(top) in set(me.chain):
            state_name = "covered"
        else:
            state_name = "busy"
        pos = None
        if me is not None:
            for i, t in enumerate(waiting):
                if _same_ident(t, me):
                    pos = i + 1
        tb = ks.get("tombstone")
        out[k] = {"key": k, "state": state_name,
                  "holder": _summary(top, now, cfg) if top else None,
                  "suspended": [_summary(e, now, cfg) for e in reversed(holders[:-1])],
                  "queue": len(waiting), "your_position": pos,
                  "waiting": [{"purpose": t.get("purpose") or "", "via": t.get("via") or "",
                               "pid": _anchor(t).pid, "kind": t.get("kind") or "",
                               "keys": list(t["keys"]), "since": t.get("since") or ""}
                              for t in waiting],
                  "freed_by_user_at": tb.get("at") if tb else None}
    return out


# ---- Messages -----------------------------------------------------------------

def _name(key: str, names: Optional[Dict[str, str]]) -> str:
    return (names or {}).get(key) or key


def describe(out: Outcome, *, now: float, cfg: Config, names: Optional[Dict[str, str]] = None,
             run_context: bool = False) -> str:
    """One paragraph for a person or an agent. Agent-facing text never tells
    anyone how to force a device free: that is the user's call."""
    st = out.status
    if st in ("held", "covered", "not_held", "released", "broken"):
        return out.message
    first = out.blocked_on[0] if out.blocked_on else {"key": out.keys[0] if out.keys else "?"}
    name = _name(first["key"], names)
    h = first.get("holder") or {}
    tail = (" You are a run.sh scenario: write verdict blocked/device-contended and stop."
            if run_context else "")
    if st == "freed_by_user":
        try:
            when = "at " + _hhmm(_from_iso(first.get("at") or ""))
        except ValueError:
            when = "just now"
        return (f"Nothing was sent. The user took {name} back {when}; ask them before "
                f"using it again.{tail}")
    if st == "lost":
        reason = first.get("reason")
        if reason == "covered-only":
            return (f"Nothing was sent. Nothing covers this process any more: the run that "
                    f"reserved {name} is gone or never reserved it.{tail}")
        if reason == "orphan":
            return (f"Nothing was sent. The run that reserved {name} is gone, so this process "
                    f"will not take it by itself.{tail}")
        return (f"Nothing was sent. Your hold on {name} ended and someone else may have used "
                f"it since your last call. The screen may not be what you left: take a "
                f"screenshot before acting again.{tail}")
    if st == "deadlock":
        return (f"Nothing was sent. Waiting for {name} would deadlock, because its holder "
                f"is waiting for a device you hold. Release what you hold, or carry on "
                f"without {name}.{tail}")
    who = h.get("purpose") or h.get("via") or "another agent"
    where = f" in {_short_path(h.get('cwd') or '')}" if h.get("cwd") else ""
    since = ""
    if h.get("since"):
        try:
            since = " since " + _hhmm(_from_iso(h["since"]))
        except ValueError:
            since = ""
    reason = first.get("reason")
    if reason == "descendant":
        lead = (f"Nothing was sent. {name} is held by a run you started ({who}); it returns "
                f"to you when that run ends.")
    elif reason == "subagent":
        lead = f"Nothing was sent. {name} is held by your subagent \"{h.get('label', '')}\"."
    elif reason == "label":
        lead = (f"Nothing was sent. {name} is held by a named agent in this session "
                f"(\"{h.get('label', '')}\"); pass agent=<your name> on every call.")
    elif reason == "ticket-ahead":
        lead = f"Nothing was sent. {name} is reserved for an agent waiting in line ({who})."
    elif reason == "depth":
        lead = f"Nothing was sent. {name} has too many nested reservations."
    else:
        frees = ""
        if h.get("until"):
            try:
                frees = f"; frees at the earliest by {_hhmm(_from_iso(h['until']))}"
            except ValueError:
                frees = ""
        idle = f"last action {h.get('idle_s', 0)}s ago" if "idle_s" in h else ""
        detail = f" ({idle}{frees})" if idle or frees else ""
        lead = f"Nothing was sent. {name} is held by {who}{where}{since}{detail}."
    if st == "queued":
        lead += f" You are number {out.position or 1} in line."
    return lead + tail


def _from_iso(s: str) -> float:
    import calendar
    return float(calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ")))


def _short_path(p: str) -> str:
    home = _home()
    return "~" + p[len(home):] if home and p.startswith(home + "/") else p


# ---- Environment --------------------------------------------------------------

def _home() -> str:
    try:
        return pwd.getpwuid(os.getuid()).pw_dir
    except KeyError:
        return ""


def _lease_dir_under(home: str) -> str:
    return os.path.join(home, "Library", "Application Support", "iMirror", "leases")


def default_lease_dir() -> str:
    """From the password database, not $HOME: an `env -i` or a sandboxed
    $HOME must not quietly split the lease into two directories."""
    return _lease_dir_under(_home())


def configured_lease_dir(env: Optional[Dict[str, str]] = None) -> str:
    """The directory this process uses: IMIRROR_LEASE_DIR when it is honoured
    (see settings_from_env), else the default. Anything given no directory
    must come through here, or a test lands in the real one."""
    try:
        has_claude = nearest_claude(ancestry(), my_uid=_my_uid()) is not None
    except StateError:
        has_claude = True                   # cannot tell, so trust no override
    return settings_from_env(env, has_claude=has_claude).lease_dir


def launcher_path() -> str:
    return os.path.join(_home(), "Library", "Application Support", "iMirror", "bin",
                        "imirror-lease")


@dataclasses.dataclass(frozen=True)
class Settings:
    enabled: bool
    lease_dir: str
    idle_s: float
    covered_only: bool
    required: bool
    labels: bool
    testing: bool
    overrides: Dict[str, str]
    ignored: Tuple[str, ...]


def settings_from_env(env: Optional[Dict[str, str]] = None, *,
                      has_claude: bool = False) -> Settings:
    """Read the IMIRROR_LEASE_* knobs. The ones that weaken the lease (off, a
    different dir, a longer idle) count only with no Claude ancestor, or
    under IMIRROR_LEASE_TESTING=1: an agent must not be able to opt out."""
    env = os.environ if env is None else env
    testing = env.get("IMIRROR_LEASE_TESTING") == "1"
    trusted = testing or not has_claude
    overrides: Dict[str, str] = {}
    ignored: List[str] = []
    enabled, lease_dir, idle = True, "", Config.idle_s
    for name in ("IMIRROR_LEASE", "IMIRROR_LEASE_DIR", "IMIRROR_LEASE_IDLE_S"):
        if name not in env:
            continue
        if not trusted:
            ignored.append(name)
            continue
        val = env[name]
        overrides[name] = val
        if name == "IMIRROR_LEASE":
            enabled = val.strip().lower() not in ("off", "0", "false", "no")
        elif name == "IMIRROR_LEASE_DIR" and val:
            lease_dir = os.path.abspath(os.path.expanduser(val))
        elif name == "IMIRROR_LEASE_IDLE_S":
            try:
                idle = float(min(900.0, max(60.0, float(val))))
            except ValueError:
                ignored.append(name)
    return Settings(enabled=enabled, lease_dir=lease_dir or default_lease_dir(), idle_s=idle,
                    covered_only=env.get("IMIRROR_LEASE_CONTEXT") == "run",
                    required=env.get("IMIRROR_LEASE_REQUIRED") == "1",
                    labels=env.get("IMIRROR_LEASE_LABELS", "").lower() != "off",
                    testing=testing, overrides=overrides, ignored=tuple(ignored))


# ---- Store --------------------------------------------------------------------

_PROCESS_LOCK = threading.Lock()


def serialize(state: Dict[str, Any]) -> str:
    """The exact bytes of state.json; the Swift app decodes them (golden file
    testdata/leases.sample.json)."""
    return json.dumps(state, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


class Store:
    """state.json in one directory, guarded by state.lock.

    Every read-modify-write takes a process-wide threading.Lock and a flock on
    a FRESH descriptor: flock belongs to the open file description, so threads
    sharing one cached fd would not exclude each other. state.lock is never
    unlinked or replaced, or two processes could lock different inodes."""

    def __init__(self, root: Optional[str] = None, *, lock_timeout_s: float = 5.0,
                 events_max_bytes: int = 1 << 20):
        self.root = root or configured_lease_dir()
        self.state_path = os.path.join(self.root, "state.json")
        self.lock_path = os.path.join(self.root, "state.lock")
        self.events_path = os.path.join(self.root, "events.jsonl")
        self.servers_dir = os.path.join(self.root, "servers")
        self.lock_timeout_s = lock_timeout_s
        self.events_max_bytes = events_max_bytes
        self._ready = False

    def prepare(self) -> None:
        if os.geteuid() == 0:
            raise StateError("refusing to run as root: root-owned lease files would lock "
                             "everyone else out")
        if self._ready:
            return
        try:
            os.makedirs(self.root, mode=0o700, exist_ok=True)
            st = os.stat(self.root)
        except OSError as e:
            raise StateError(f"cannot use the lease directory {self.root} ({e})")
        if st.st_uid != _owner_uid():
            raise StateError(f"{self.root} is not owned by this user")
        if stat.S_IMODE(st.st_mode) & 0o077:
            try:
                os.chmod(self.root, 0o700)
            except OSError as e:
                raise StateError(f"cannot make {self.root} private ({e})")
        self._ready = True

    def _check_owner(self, fd: int, path: str) -> None:
        if os.fstat(fd).st_uid != _owner_uid():
            raise StateError(f"{path} is not owned by this user")

    def read(self) -> Dict[str, Any]:
        """Lock-free read. Safe because writers swap whole files in with
        os.replace. {} when there is no file yet; CorruptState if it does not
        parse (only update() may repair it)."""
        self.prepare()
        try:
            fd = os.open(self.state_path, os.O_RDONLY | os.O_CLOEXEC)
        except FileNotFoundError:
            return {}
        except OSError as e:
            raise StateError(f"cannot read {self.state_path} ({e})")
        try:
            self._check_owner(fd, self.state_path)
            with os.fdopen(fd, "rb", closefd=False) as f:
                data = f.read()
        finally:
            os.close(fd)
        try:
            doc = json.loads(data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as e:
            raise CorruptState(str(e))
        if not isinstance(doc, dict):
            raise CorruptState("not a JSON object")
        return doc

    @contextlib.contextmanager
    def locked(self):
        self.prepare()
        deadline = mono() + self.lock_timeout_s
        if not _PROCESS_LOCK.acquire(timeout=self.lock_timeout_s):
            raise StateError("timed out waiting for the lease lock in this process")
        try:
            fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
            try:
                self._check_owner(fd, self.lock_path)
                while True:
                    try:
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except OSError as e:
                        if e.errno not in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EINTR):
                            raise StateError(f"cannot lock {self.lock_path} ({e})")
                        if mono() >= deadline:
                            raise StateError(f"timed out after {self.lock_timeout_s:g} s "
                                             f"waiting for {self.lock_path}")
                        time.sleep(random.uniform(0.002, 0.02))
                try:
                    yield
                finally:
                    fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)
        finally:
            _PROCESS_LOCK.release()

    def _load_locked(self) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
        try:
            return self.read(), []
        except CorruptState as e:
            dest = f"{self.state_path}.corrupt-{time.strftime('%Y%m%dT%H%M%S')}-{os.getpid()}"
            try:
                os.replace(self.state_path, dest)
            except OSError as err:
                raise StateError(f"{self.state_path} is corrupt and cannot be moved ({err})")
            return {}, [_event("corrupt-recovered", note=f"{e}; kept as {os.path.basename(dest)}")]

    def update(self, fn: Callable[[Dict[str, Any], float], Tuple[Dict[str, Any], Any, List[Dict[str, Any]]]]) -> Any:
        """Read, call fn(state, now), write back if it changed, log events.
        `now` is taken after the flock, so a slow lock never ages a grant."""
        with self.locked():
            state, events = self._load_locked()
            before = _canon(state)          # before fn: it may edit in place
            now = mono()
            new_state, result, more = fn(state, now)
            if events or _canon(new_state) != before:
                self.write_locked(new_state)
            self.append_events_locked(events + list(more))
            return result

    def write_locked(self, state: Dict[str, Any], *, stamp: bool = True) -> None:
        if stamp:
            state = dict(state)
            state["updated_at"] = iso(time.time())
            state["writer"] = {"version": __version__, "pid": os.getpid()}
        tmp = self.state_path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_CLOEXEC, 0o600)
        try:
            os.write(fd, serialize(state).encode("utf-8"))
        finally:
            os.close(fd)
        os.replace(tmp, self.state_path)

    def append_events_locked(self, events: Sequence[Dict[str, Any]]) -> None:
        if not events:
            return
        try:
            if os.path.getsize(self.events_path) > self.events_max_bytes:
                os.replace(self.events_path, self.events_path + ".1")
        except OSError:
            pass
        stamp = iso(time.time())
        lines = "".join(json.dumps({"at": stamp, "writer_pid": os.getpid(), **e},
                                   sort_keys=True, ensure_ascii=False) + "\n" for e in events)
        fd = os.open(self.events_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_CLOEXEC,
                     0o600)
        try:
            os.write(fd, lines.encode("utf-8"))
        finally:
            os.close(fd)


# ---- MCP server registry and the unlocked-server scan ---------------------------

def register_server(lease_dir: Optional[str] = None, version: str = "", script: str = "") -> str:
    """servers/<pid>-<uniqueid>.json says "this MCP server takes leases".
    Checking the script file would say nothing about the code a running
    process loaded. Removed at exit; a stale file is ignored by uniqueid."""
    store = Store(lease_dir)
    store.prepare()
    os.makedirs(store.servers_dir, mode=0o700, exist_ok=True)
    me = proc_unique(os.getpid())
    uniq = me[0] if me else 0
    path = os.path.join(store.servers_dir, f"{os.getpid()}-{uniq}.json")
    doc = {"pid": os.getpid(), "uniqueid": uniq, "version": version, "protocol": PROTOCOL,
           "script": script, "started": iso(time.time())}
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, sort_keys=True)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    import atexit
    atexit.register(unregister_server, path)
    return path


def unregister_server(path: str) -> None:
    with contextlib.suppress(OSError):
        os.unlink(path)


def _registered_pids(lease_dir: str) -> set:
    d = os.path.join(lease_dir, "servers")
    out = set()
    try:
        names = os.listdir(d)
    except OSError:
        return out
    for n in names:
        m = re.match(r"^(\d+)-(\d+)\.json$", n)
        if not m:
            continue
        pid, uniq = int(m.group(1)), int(m.group(2))
        if proc_alive(pid, uniq):
            out.add(pid)
        else:
            unregister_server(os.path.join(d, n))
    return out


_SCAN_CACHE: Dict[str, Tuple[float, List[Dict[str, Any]]]] = {}

# Purpose-iOS's run.sh takes leases through antsignalctl, with no
# Testing/lib/devicelease.sh; without this it was listed as ignoring them.
_RUN_SH_LEASE_MARK = "device lease wait"


def _head_text(path: str, limit: int = 1 << 20) -> str:
    try:
        with open(path, "rb") as f:
            return f.read(limit).decode("utf-8", "replace")
    except OSError:
        return ""


def unlocked_servers(lease_dir: Optional[str] = None, *, ps_text: Optional[str] = None,
                     argv_of: Callable[[int], List[str]] = proc_argv,
                     cwd_of: Callable[[int], str] = proc_cwd,
                     exists: Callable[[str], bool] = os.path.exists,
                     text_of: Optional[Callable[[str], str]] = None,
                     registered: Optional[set] = None, max_age_s: float = 60.0
                     ) -> List[Dict[str, Any]]:
    """Processes that drive devices but ignore leases: imirror_mcp.py servers
    that never registered (the pre-fork v1.2.0 server, or one started before
    leases), and a Testing/run.sh that neither has Testing/lib/devicelease.sh
    nor waits through `antsignalctl device lease`. Cached 60 s; never call it
    under the flock."""
    text_of = text_of or _head_text
    lease_dir = lease_dir or configured_lease_dir()
    if ps_text is None:
        hit = _SCAN_CACHE.get(lease_dir)
        if hit and mono() - hit[0] < max_age_s:
            return [dict(x) for x in hit[1]]
        try:
            ps_text = subprocess.run(["ps", "-axo", "pid=,uid=,command="], capture_output=True,
                                     text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            return []
        use_cache = True
    else:
        use_cache = False
    regs = _registered_pids(lease_dir) if registered is None else registered
    uid, me = _my_uid(), os.getpid()
    out: List[Dict[str, Any]] = []
    for line in ps_text.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        pid, puid, cmd = int(parts[0]), int(parts[1]), parts[2]
        if puid != uid or pid == me:
            continue
        if "imirror_mcp.py" in cmd:
            if pid not in regs:
                out.append({"pid": pid, "kind": "mcp", "command": cmd[:300],
                            "reason": "an iMirror MCP server that does not take device leases"})
            continue
        if "run.sh" not in cmd:
            continue
        for tok in argv_of(pid)[1:3]:
            if os.path.basename(tok) != "run.sh":
                continue
            path = tok if os.path.isabs(tok) else os.path.join(cwd_of(pid) or "/", tok)
            path = os.path.normpath(path)
            if not path.endswith(os.sep + os.path.join("Testing", "run.sh")):
                continue
            repo = os.path.dirname(os.path.dirname(path))
            if not (exists(os.path.join(repo, "Testing", "lib", "devicelease.sh"))
                    or _RUN_SH_LEASE_MARK in text_of(path)):
                out.append({"pid": pid, "kind": "run.sh", "repo": repo, "command": cmd[:300],
                            "reason": "a Testing/run.sh from a worktree without device leases"})
            break
    if use_cache:
        _SCAN_CACHE[lease_dir] = (mono(), [dict(x) for x in out])
    return out


# ---- Locker: the MCP server's and CLI's runtime -------------------------------

def _new_id() -> str:
    return secrets.token_hex(8)


def _default_alive(p: Proc) -> bool:
    return proc_alive(p.pid, p.uniq)


class Hold:
    """What enter() hands back. `active` holds count as in flight for the
    heartbeat; `warning` is set for an inspect call that runs after LOST."""
    __slots__ = ("key", "label", "access", "active", "warning", "outcome")

    def __init__(self, key: str, label: str, access: str, active: bool,
                 warning: str = "", outcome: Optional[Outcome] = None):
        self.key, self.label, self.access = key, label, access
        self.active, self.warning, self.outcome = active, warning, outcome


class Locker:
    """Per-process lease runtime. Keeps, per (key, label), what this process
    believes it holds; a heartbeat renews holds while calls are in flight and
    flags a hold that was broken, pushed or lost, so check() can stop a long
    call between WDA requests. The fast path is a lock-free read: the flock is
    taken only when the state must change."""

    def __init__(self, store: Optional[Store] = None, cfg: Optional[Config] = None, *,
                 client: str = "mcp", via: str = "", caller: Optional[Caller] = None,
                 settings: Optional[Settings] = None, env: Optional[Dict[str, str]] = None,
                 alive: Callable[[Proc], bool] = _default_alive,
                 heartbeat_s: float = 5.0, fail_open: bool = True):
        self.client, self.via = client, via
        self.alive = alive
        self.heartbeat_s = heartbeat_s
        self.problem = ""
        self._caller = caller
        self._anchor_pid = caller.anchor.pid if caller and caller.kind in ("run", "app") else None
        self._mutex = threading.RLock()
        self._belief: Dict[Tuple[str, str], Dict[str, Any]] = {}
        self._revoked: Dict[Tuple[str, str], LeaseError] = {}
        self._inflight: Dict[Tuple[str, str], int] = {}
        self._covering: set = set()
        self._orphaned = False
        self._hb_thread: Optional[threading.Thread] = None
        self._hb_wake = threading.Event()
        self._hb_stop = threading.Event()
        self._boot = ""
        if settings is None:
            has_claude = False
            try:
                has_claude = nearest_claude(ancestry(), my_uid=_my_uid()) is not None
            except StateError as e:
                self.problem = str(e)
            settings = settings_from_env(env, has_claude=has_claude)
        self.settings = settings
        self.enabled = settings.enabled
        base = cfg or Config(idle_s=settings.idle_s)
        touch = min(15.0, base.idle_s / 4.0) if base.touch_s == 0 else base.touch_s
        self.cfg = dataclasses.replace(base, touch_s=touch)
        self.store = store or Store(settings.lease_dir)
        if self.enabled and not self.problem:
            try:
                self.store.prepare()
            except StateError as e:
                self.problem = str(e)
        if self.problem and fail_open and not settings.required:
            self.enabled = False            # fail open only at startup

    # -- identity

    def caller(self, label: str = "") -> Caller:
        """Who this process is, rebuilt when an ancestor died (run.sh killed
        under us). A dead covering anchor makes this process an orphan for
        the rest of its life: it never takes a hold by itself again."""
        with self._mutex:
            c = self._caller
            if c is not None and not self.alive(c.anchor):
                raise Unkeyable("the process this hold was anchored to is gone")
            if c is None or any(not self.alive(p) for p in c.chain[1:]):
                c = build_caller(anchor_pid=self._anchor_pid, client=self.client, via=self.via,
                                 covered_only=self.settings.covered_only)
                self._caller = c
            if self._covering and any(not self.alive(a) for a in self._covering):
                self._orphaned = True
            return dataclasses.replace(c, label=norm_label(label), orphaned=self._orphaned,
                                       covered_only=c.covered_only or self.settings.covered_only)

    def _cfg_now(self) -> Config:
        if not self._boot:
            self._boot = boot_session_id()
        return dataclasses.replace(self.cfg, boot=self._boot or None,
                                   wall_offset=time.time() - mono())

    def _guard(self) -> None:
        if self.problem:
            raise StateError(f"device leases are unavailable ({self.problem}); nothing was sent")

    # -- one attempt

    def attempt(self, req: Request, label: str = "") -> Outcome:
        """decide() on a lock-free read; take the flock only if the state must
        change. Learns beliefs from the answer."""
        self._guard()
        me = self.caller(label)
        cfg = self._cfg_now()
        out = None
        try:
            state = self.store.read()
            _, out, _ = decide(state, req, me, mono(), self.alive, cfg, _new_id)
            if out.changed:
                out = None
        except CorruptState:
            out = None
        if out is None:
            out = self.store.update(lambda s, now: decide(s, req, me, now, self.alive, cfg, _new_id))
        self._learn(req, me.label, out)
        return out

    def _beliefs(self, keys: Sequence[str], label: str) -> Dict[str, Dict[str, Any]]:
        with self._mutex:
            return {k: dict(self._belief[(k, label)]) for k in keys if (k, label) in self._belief}

    def _learn(self, req: Request, label: str, out: Outcome) -> None:
        now = mono()
        with self._mutex:
            for k in out.keys:
                kl = (k, label)
                if out.status in ("held", "covered") and k in out.lease_ids:
                    cov = k in out.covered_by
                    self._belief[kl] = {"lease_id": out.lease_ids[k], "epoch": out.epochs.get(k, 0),
                                        "covered": cov, "verified": now}
                    if cov:
                        self._covering.add(out.covered_by[k]["anchor"])
                elif out.status in ("lost", "freed_by_user"):
                    self._belief.pop(kl, None)
                elif out.status == "released" and k in out.released:
                    self._belief.pop(kl, None)

    def _my_lease_ids(self, keys: Sequence[str], label: str) -> Tuple[str, ...]:
        """Lease ids this identity holds on `keys` right now (lock-free)."""
        try:
            st = _with_defaults(self.store.read())
        except (CorruptState, StateError):
            return ()
        me = self.caller(label)
        ids = []
        for k in keys:
            for e in (st["keys"].get(k) or {}).get("holders") or []:
                if _anchor(e) == me.anchor and norm_label(e.get("label")) == label:
                    ids.append(e.get("lease_id"))
        return tuple(i for i in ids if i)

    # -- the MCP hook

    def ensure(self, keys: Sequence[str], *, label: str = "", purpose: str = "",
               hold_s: float = 0, autowait: bool = True,
               sleep: Callable[[float], None] = time.sleep) -> Outcome:
        """An automatic hold. Waits only when decide() predicts the holder
        frees within ~20 s; otherwise answers BUSY at once."""
        keys = tuple(normalize_key(k) for k in keys)
        label = norm_label(label)
        deadline = None
        while True:
            req = Request(op="ensure", keys=keys, mode="auto", hold_s=hold_s, purpose=purpose,
                          believed=self._beliefs(keys, label))
            out = self.attempt(req, label)
            if out.status != "busy" or not autowait or not out.autowait:
                return out
            if deadline is None:
                deadline = mono() + min((out.eta_s or 0) + 2.0, self.cfg.autowait_s + 2.0)
            if mono() >= deadline:
                return out
            sleep(0.5)

    def enter(self, key: str, label: str = "", purpose: str = "", access: str = "drive") -> Hold:
        """Before a tool call. observe: never checked (a holder's observe call
        renews, best effort). inspect: BUSY if someone else holds; runs free
        on a free device; after LOST it runs with a warning. drive: needs the
        hold, taken automatically if free. Raises LeaseError or StateError."""
        key = normalize_key(key)
        label = norm_label(label)
        if not self.enabled:
            return Hold(key, label, access, active=False)
        if access == "observe":
            b = self._beliefs((key,), label).get(key)
            if b and mono() - b.get("verified", 0) >= self.heartbeat_s:
                with contextlib.suppress(StateError, CorruptState):
                    self._verify(key, label)
            return Hold(key, label, access, active=False)
        self._guard()
        with self._mutex:
            self._revoked.pop((key, label), None)
        if access == "inspect":
            out = self.attempt(Request(op="inspect", keys=(key,), mode="auto",
                                       believed=self._beliefs((key,), label)), label)
            if out.status == "not_held":
                return Hold(key, label, access, active=False, outcome=out)
            if out.status == "lost":
                return Hold(key, label, access, active=False, warning=out.message, outcome=out)
            if out.status not in ("held", "covered"):
                raise LeaseError(out)
        else:
            out = self.ensure((key,), label=label, purpose=purpose)
            if out.status not in ("held", "covered"):
                raise LeaseError(out)
        with self._mutex:
            self._inflight[(key, label)] = self._inflight.get((key, label), 0) + 1
        self._start_heartbeat()
        return Hold(key, label, access, active=True, outcome=out)

    def exit(self, hold: Optional[Hold]) -> None:
        if hold is None or not hold.active:
            return
        with self._mutex:
            kl = (hold.key, hold.label)
            n = self._inflight.get(kl, 0) - 1
            if n > 0:
                self._inflight[kl] = n
            else:
                self._inflight.pop(kl, None)
        hold.active = False

    @contextlib.contextmanager
    def hold(self, key: str, label: str = "", purpose: str = "", access: str = "drive"):
        h = self.enter(key, label=label, purpose=purpose, access=access)
        try:
            yield h
        finally:
            self.exit(h)

    def check(self, key: str, label: str = "") -> None:
        """Cheap: the hook calls it before every WDA request. Raises the
        LeaseError the heartbeat recorded, after re-verifying if the last
        check is stale (a starved heartbeat must not hide a break)."""
        if not self.enabled:
            return
        kl = (normalize_key(key), norm_label(label))
        with self._mutex:
            err = self._revoked.get(kl)
            b = self._belief.get(kl)
        if err is None and b is not None and mono() - b.get("verified", 0) > 2 * self.heartbeat_s:
            with contextlib.suppress(StateError, CorruptState):
                self._verify(*kl)
            with self._mutex:
                err = self._revoked.get(kl)
        if err is not None:
            raise err

    def _verify(self, key: str, label: str) -> None:
        b = self._beliefs((key,), label)
        if not b:
            return
        out = self.attempt(Request(op="touch", keys=(key,), believed=b), label)
        if out.status in ("held", "covered"):
            return
        if out.status == "freed_by_user":
            msg = out.message
        elif out.status == "busy":
            msg = f"Stopped mid-call: {out.message}"
        else:
            msg = (f"Stopped mid-call: your hold on {key} ended while this call was running; "
                   f"the rest of it was not sent.")
            out.code = "DEVICE_RESERVATION_LOST"
        with self._mutex:
            self._revoked[(key, label)] = LeaseError(out, msg)

    def _start_heartbeat(self) -> None:
        with self._mutex:
            if self._hb_thread is None or not self._hb_thread.is_alive():
                self._hb_thread = threading.Thread(target=self._heartbeat, daemon=True,
                                                   name="imirror-lease-heartbeat")
                self._hb_thread.start()
        self._hb_wake.set()

    def close(self) -> None:
        """Stop the heartbeat thread. A server keeps one Locker for life;
        a test suite makes hundreds, and each would leave a thread behind."""
        self._hb_stop.set()
        self._hb_wake.set()

    def _heartbeat(self) -> None:
        """Renew-only: it never grants. Every few seconds while a call is in
        flight it re-checks each hold and records any that were lost."""
        while not self._hb_stop.is_set():
            with self._mutex:
                live = [kl for kl, n in self._inflight.items() if n > 0]
            if not live:
                self._hb_wake.wait()
                self._hb_wake.clear()
                continue
            # An Event, not time.sleep: tests patch time.sleep.
            if self._hb_stop.wait(self.heartbeat_s):
                return
            for key, label in live:
                with contextlib.suppress(StateError, CorruptState):
                    self._verify(key, label)

    # -- explicit reservations

    def acquire(self, keys: Sequence[str], *, mode: str = "explicit", hold_s: float = 0,
                wait: bool = False, wait_s: float = 0, purpose: str = "",
                label: str = "") -> Outcome:
        """One attempt, no sleeping. With wait (or wait_s > 0) a busy device
        gives `queued` and a ticket; a second call joins the same ticket."""
        keys = tuple(normalize_key(k) for k in keys)
        label = norm_label(label)
        req = Request(op="acquire", keys=keys, mode=mode, hold_s=hold_s,
                      wait=bool(wait or wait_s > 0),
                      purpose=purpose, believed=self._beliefs(keys, label))
        return self.attempt(req, label)

    def wait(self, keys: Sequence[str], *, wait_s: float, mode: str = "explicit",
             hold_s: float = 0, purpose: str = "", label: str = "", poll_s: float = 0.5,
             sleep: Callable[[float], None] = time.sleep) -> Outcome:
        """Blocking wait for the CLI. On an interrupt the ticket is withdrawn
        and a grant that arrived meanwhile is released."""
        keys = tuple(normalize_key(k) for k in keys)
        label = norm_label(label)
        prior = self._my_lease_ids(keys, label)
        finished = False
        try:
            out = self.acquire(keys, mode=mode, hold_s=hold_s, wait=wait_s > 0,
                               purpose=purpose, label=label)
            deadline = mono() + max(0.0, wait_s)
            while out.status == "queued" and mono() < deadline:
                sleep(min(poll_s, max(0.0, deadline - mono())))
                out = self.acquire(keys, mode=mode, hold_s=hold_s, wait=True,
                                   purpose=purpose, label=label)
            finished = True
            return out
        finally:
            if not finished:
                self.withdraw(keys, label=label, keep_ids=prior)

    async def acquire_async(self, keys: Sequence[str], *, wait_s: float, mode: str = "explicit",
                            hold_s: float = 0, purpose: str = "", label: str = "",
                            run_sync: Optional[Callable[..., Any]] = None,
                            sleep: Optional[Callable[[float], Any]] = None,
                            poll_s: float = 0.5) -> Outcome:
        """The MCP wait: each attempt runs in a worker thread, with an async
        sleep between, so a cancel lands between attempts. Capped at 85 s for
        MCP clients (Claude Code backgrounds a call at 120 s). If cancelled,
        the ticket is withdrawn and any late grant released."""
        if run_sync is None or sleep is None:
            import asyncio
            run_sync = run_sync or asyncio.to_thread
            sleep = sleep or asyncio.sleep
        keys = tuple(normalize_key(k) for k in keys)
        label = norm_label(label)
        cap = min(wait_s, self.cfg.mcp_wait_cap_s) if self.client == "mcp" else wait_s
        prior = await run_sync(functools.partial(self._my_lease_ids, keys, label))
        finished = False
        try:
            attempt = functools.partial(self.acquire, keys, mode=mode, hold_s=hold_s,
                                        wait=cap > 0, purpose=purpose, label=label)
            out = await run_sync(attempt)
            deadline = mono() + max(0.0, cap)
            while out.status == "queued" and mono() < deadline:
                await sleep(poll_s)
                out = await run_sync(attempt)
            finished = True
            return out
        finally:
            if not finished:                # synchronous: a cancelled task cannot await
                self.withdraw(keys, label=label, keep_ids=prior)

    def withdraw(self, keys: Sequence[str], *, label: str = "",
                 keep_ids: Iterable[str] = ()) -> None:
        """Undo an abandoned wait: drop my tickets on `keys` and release any
        hold on them that is not one of `keep_ids` (what I held before)."""
        keys = tuple(normalize_key(k) for k in keys)
        with contextlib.suppress(StateError, LeaseError, CorruptState):
            self.attempt(Request(op="release", keys=keys, keep_ids=tuple(keep_ids),
                                 exact_label=True), norm_label(label))

    def renew(self, keys: Sequence[str], *, hold_s: float = 0, purpose: str = "",
              label: str = "") -> Outcome:
        keys = tuple(normalize_key(k) for k in keys)
        return self.attempt(Request(op="renew", keys=keys, hold_s=hold_s, purpose=purpose),
                            norm_label(label))

    def release(self, keys: Sequence[str] = (), *, label: str = "",
                all_keys: bool = False) -> Outcome:
        keys = tuple(normalize_key(k) for k in keys)
        return self.attempt(Request(op="release", keys=keys, all_keys=all_keys),
                            norm_label(label))

    def break_keys(self, keys: Sequence[str], *, reason: str, by: str = "") -> Outcome:
        keys = tuple(normalize_key(k) for k in keys)
        return self.attempt(Request(op="break", keys=keys, reason=reason, purpose=by))

    def view(self, keys: Iterable[str] = (), label: str = "") -> Dict[str, Dict[str, Any]]:
        """Lock-free snapshot for ios_devices; {} when leases are off."""
        if not self.enabled:
            return {}
        try:
            state = self.store.read()
        except CorruptState:
            state = {}
        try:
            me: Optional[Caller] = self.caller(label)
        except StateError:
            me = None
        return view(state, me, mono(), self.alive, self._cfg_now(),
                    keys=[normalize_key(k) for k in keys])

    def register_server(self, version: str, script: str) -> str:
        return register_server(self.store.root, version, script)

    def unlocked_servers(self) -> List[Dict[str, Any]]:
        return unlocked_servers(self.store.root)


# ---- CLI ----------------------------------------------------------------------

_EXIT = {"held": 0, "covered": 0, "released": 0, "broken": 0, "not_held": 0, "ok": 0,
         "busy": 3, "queued": 3, "deadlock": 4, "lost": 5, "freed_by_user": 5}


class _Parser(argparse.ArgumentParser):
    def error(self, message: str):          # never exit from inside argparse
        raise UsageError(message)


def _parser() -> argparse.ArgumentParser:
    p = _Parser(prog="imirror-lease", description="Device leases for shared iPhones and "
                "Simulators. Exit: 0 ok, 2 usage, 3 busy, 4 deadlock, 5 lost, 6 error.")
    p.add_argument("--version", action="store_true")
    p.add_argument("--json", action="store_true")
    sub = p.add_subparsers(dest="cmd", parser_class=_Parser)

    def add(name: str, help_: str) -> argparse.ArgumentParser:
        sp = sub.add_parser(name, help=help_)
        sp.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
        return sp

    sp = add("status", "show holders and queues")
    sp.add_argument("keys", nargs="*")
    add("whoami", "show which process a hold would be anchored to")
    sp = add("ensure", "take or renew an automatic hold (antsignalctl)")
    sp.add_argument("keys", nargs="+")
    sp.add_argument("--hold-s", type=float, default=0)
    sp.add_argument("--purpose", default="")
    sp.add_argument("--label", default="")
    sp = add("acquire", "reserve devices, optionally waiting in line")
    sp.add_argument("keys", nargs="+")
    sp.add_argument("--wait-s", type=float, default=0)
    sp.add_argument("--hold-s", type=float, default=0)
    sp.add_argument("--anchor-pid", type=int)
    sp.add_argument("--purpose", default="")
    sp.add_argument("--label", default="")
    sp = add("renew", "extend a reservation this script holds")
    sp.add_argument("keys", nargs="+")
    sp.add_argument("--anchor-pid", type=int, required=True)
    sp.add_argument("--hold-s", type=float, default=0)
    sp.add_argument("--purpose", default="")
    sp = add("release", "release your own holds and tickets")
    sp.add_argument("keys", nargs="*")
    sp.add_argument("--all", action="store_true")
    sp.add_argument("--anchor-pid", type=int)
    sp.add_argument("--label", default="")
    sp = add("break", "for a person: take a device back from whoever holds it")
    sp.add_argument("keys", nargs="+")
    sp.add_argument("--reason", required=True)
    sp.add_argument("--from-app", action="store_true")
    return p


def _emit(obj: Dict[str, Any], json_mode: bool, text: str, err: bool = False) -> None:
    if json_mode:
        sys.stdout.write(json.dumps(obj, sort_keys=True, ensure_ascii=False) + "\n")
    elif text:
        (sys.stderr if err else sys.stdout).write(text.rstrip() + "\n")


def _error_json(code: str, message: str, keys: Sequence[str] = ()) -> Dict[str, Any]:
    return {"ok": False, "protocol": PROTOCOL, "status": "error", "code": code,
            "keys": list(keys), "message": message, "blocked_on": [],
            "retry_after_s": 1 if "timed out" in message else None}


def _break_gate(chain: Sequence[ProcInfo], *, from_app: bool, stdin_tty: bool,
                my_uid: int, path_of: Callable[[int], str] = proc_path,
                argv0_of: Callable[[int], str] = proc_argv0) -> Optional[str]:
    """Why `break` must refuse, or None. It is for a person: never from under
    a Claude session, and only from a terminal or from the iMirror app."""
    if nearest_claude(chain, my_uid=my_uid, path_of=path_of, argv0_of=argv0_of) is not None:
        return "break is for a person; it refuses to run under a Claude session"
    if from_app:
        for p in chain[1:3]:                # the app, or a launcher shell under it
            if is_imirror_app(path_of(p.pid)):
                return None
            if os.path.basename(path_of(p.pid)) not in ("sh", "bash", "zsh", "dash"):
                break
        return "--from-app is only for the iMirror app"
    if not stdin_tty:
        return "break needs a terminal (or iMirror's Free button)"
    return None


def _outcome_text(out: Outcome) -> str:
    if out.status in ("held", "covered"):
        until = (f" until {_hhmm(out.until_mono + out.wall_offset)}"
                 if out.until_mono is not None else "")
        return f"{out.status} {' '.join(out.keys)}{until}"
    if out.status in ("released", "not_held", "broken"):
        return out.message or f"{out.status} {' '.join(out.released or out.keys)}"
    return out.message


def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    json_mode = "--json" in argv
    keys: Sequence[str] = ()
    try:
        args = _parser().parse_args(argv)
        json_mode = bool(getattr(args, "json", False)) or json_mode
        if args.version:
            _emit({"version": __version__, "protocol": PROTOCOL}, json_mode,
                  f"imirror-lease {__version__} (protocol {PROTOCOL})")
            return 0
        if not args.cmd:
            raise UsageError("a subcommand is required (status, whoami, ensure, acquire, "
                             "renew, release, break)")
        keys = [normalize_key(k) for k in getattr(args, "keys", []) or []]
        return _run(args, keys, json_mode)
    except UsageError as e:
        _emit(_error_json("USAGE", str(e), keys), json_mode, f"imirror-lease: {e}", err=True)
        return 2
    except StateError as e:
        _emit(_error_json(e.code, f"{e}. Nothing was changed.", keys), json_mode,
              f"imirror-lease: {e}", err=True)
        return 6
    except OSError as e:
        _emit(_error_json("RESERVATION_STATE_ERROR", f"{e}. Nothing was changed.", keys),
              json_mode, f"imirror-lease: {e}", err=True)
        return 6


class _Interrupted(Exception):
    pass


def _run(args: argparse.Namespace, keys: Sequence[str], json_mode: bool) -> int:
    cmd = args.cmd
    if os.geteuid() == 0:
        raise StateError("refusing to run as root")
    infos = ancestry()
    has_claude = nearest_claude(infos, my_uid=_my_uid()) is not None
    settings = settings_from_env(has_claude=has_claude)
    for name in settings.ignored:
        sys.stderr.write(f"imirror-lease: ignoring {name} under a Claude session\n")
    store = Store(settings.lease_dir)
    anchor_pid = getattr(args, "anchor_pid", None)
    label = getattr(args, "label", "") or ""
    via = f"imirror-lease {cmd}"

    if cmd == "whoami":
        p, kind = find_anchor(infos, anchor_pid, my_uid=_my_uid())
        obj = {"ok": True, "protocol": PROTOCOL, "status": "ok",
               "anchor": {"pid": p.pid, "uniqueid": p.uniq, "name": p.comm,
                          "path": proc_path(p.pid), "kind": kind},
               "chain": [{"pid": i.pid, "uniqueid": i.uniq, "name": i.comm, "uid": i.uid}
                         for i in infos],
               "claude_ancestor": has_claude, "lease_dir": settings.lease_dir,
               "overrides": settings.overrides, "ignored_overrides": list(settings.ignored),
               "context": "run" if settings.covered_only else ""}
        _emit(obj, json_mode, f"anchor {p.comm} (pid {p.pid}, {kind}); lease dir "
              f"{settings.lease_dir}")
        return 0

    if not settings.enabled:
        status = {"ensure": "held", "acquire": "held", "renew": "held", "status": "ok",
                  "break": "broken"}.get(cmd, "not_held")
        obj = {"ok": True, "protocol": PROTOCOL, "status": status, "keys": list(keys),
               "lease_id": "", "disabled": True}
        _emit(obj, json_mode, "device leases are off (IMIRROR_LEASE=off)")
        return 0

    if cmd == "break":
        why = _break_gate(infos, from_app=args.from_app, stdin_tty=sys.stdin.isatty(),
                          my_uid=_my_uid())
        if why:
            raise UsageError(why)

    caller = build_caller(anchor_pid=anchor_pid, label=label, client="cli", via=via,
                          covered_only=settings.covered_only)
    locker = Locker(store=store, client="cli", via=via, caller=caller, settings=settings,
                    fail_open=False)

    if cmd == "status":
        try:
            state = store.read()
        except CorruptState:
            state = {}
        cfg = locker._cfg_now()
        v = view(state, caller, mono(), locker.alive, cfg, keys=keys)
        rows = [v[k] for k in (keys or sorted(v))]
        obj = {"ok": True, "protocol": PROTOCOL, "status": "ok", "keys": rows,
               "lease_dir": settings.lease_dir, "overrides": settings.overrides,
               "ignored_overrides": list(settings.ignored),
               "unlocked_servers": unlocked_servers(settings.lease_dir)}
        lines = [f"lease dir {settings.lease_dir}"]
        for r in rows:
            h = r["holder"]
            who = f" by {h['purpose'] or h['via']} (pid {h['pid']}) until {h['until']}" if h else ""
            lines.append(f"{r['key']}: {r['state']}{who}, {r['queue']} waiting")
        for s in obj["unlocked_servers"]:
            lines.append(f"ignores leases: pid {s['pid']} ({s['reason']})")
        _emit(obj, json_mode, "\n".join(lines))
        return 0

    purpose = getattr(args, "purpose", "") or ""
    if cmd in ("ensure", "acquire") and not purpose:
        parent = infos[1].comm if len(infos) > 1 else ""
        purpose = f"{parent} via imirror-lease {cmd}".strip()

    def on_term(signum, frame):
        raise _Interrupted()

    main_thread = threading.current_thread() is threading.main_thread()
    old = signal.signal(signal.SIGTERM, on_term) if main_thread else None
    try:
        if cmd == "ensure":
            out = locker.ensure(keys, label=label, purpose=purpose, hold_s=args.hold_s)
        elif cmd == "acquire":
            mode = "reserve" if anchor_pid is not None else "explicit"
            if args.wait_s > 0:
                out = locker.wait(keys, wait_s=args.wait_s, mode=mode, hold_s=args.hold_s,
                                  purpose=purpose, label=label)
            else:
                out = locker.acquire(keys, mode=mode, hold_s=args.hold_s, purpose=purpose,
                                     label=label)
        elif cmd == "renew":
            out = locker.renew(keys, hold_s=args.hold_s, purpose=purpose)
        elif cmd == "release":
            if not keys and not args.all:
                raise UsageError("name the keys to release, or pass --all")
            out = locker.release(keys, label=label, all_keys=args.all)
        else:
            out = locker.break_keys(keys, reason=args.reason,
                                    by="iMirror app" if args.from_app else "terminal")
    except (KeyboardInterrupt, _Interrupted):
        _emit(_error_json("RESERVATION_STATE_ERROR", "interrupted before an answer; check "
                          "`imirror-lease status`", keys), json_mode, "imirror-lease: interrupted",
              err=True)
        return 6
    finally:
        if main_thread:
            signal.signal(signal.SIGTERM, old)
    if cmd == "renew" and out.status == "not_held":
        out.status, out.code = "lost", "DEVICE_RESERVATION_LOST"
    _emit(out.to_json(), json_mode, _outcome_text(out), err=not out.ok)
    return _EXIT.get(out.status, 6)


if __name__ == "__main__":
    sys.exit(main())
