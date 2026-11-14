"""Switch the iMirror app's Simulators on and off without its GUI.

The app runs WebDriverAgent on every Simulator whose UDID is in the
UserDefaults array `imirror.enabledSimulators` (bundle com.local.imirror). It
reads that list on launch and polls it every 2 s, so writing it is the whole
interface: this module reads and writes it with `defaults`, and reads the
app's device file to report each sim's alias, port and state.

Used three ways: as a CLI (scripts/imirror-sim.sh is a wrapper around
`python3 sim_control.py`), by imirror_mcp.py's sim_list / sim_enable /
sim_disable tools, and by its tests. Standard library only.
"""
from __future__ import annotations

import json
import os
import plistlib
import re
import subprocess
import sys
import time
from typing import Any

DOMAIN = "com.local.imirror"
ENABLED_KEY = "imirror.enabledSimulators"
# The app's sticky {udid: {index, alias}} table, JSON in a data value.
SLOTS_KEY = "imirror.simulatorSlots"

_UDID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")


class SimControlError(RuntimeError):
    """A request this module can't carry out; the message says why."""


def _run(args: list[str]) -> tuple[int, str]:
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=60)
    except FileNotFoundError as e:
        raise SimControlError(f"`{args[0]}` not found") from e
    except subprocess.TimeoutExpired as e:
        raise SimControlError(f"`{' '.join(args[:3])}` timed out") from e
    return r.returncode, r.stdout or ""


def is_udid(s: str) -> bool:
    return bool(_UDID_RE.match(s.strip()))


def normalize(raw: Any) -> list[str]:
    """Same rule as the app (iMirrorCore normalizeEnabledSimulators):
    upper-cased simulator UDIDs, first occurrence wins, junk dropped."""
    items = raw if isinstance(raw, list) else [raw] if isinstance(raw, str) else []
    out: list[str] = []
    for s in items:
        if isinstance(s, str) and is_udid(s) and s.strip().upper() not in out:
            out.append(s.strip().upper())
    return out


# ---- the app's preferences -------------------------------------------------------

def read_prefs() -> dict[str, Any]:
    """The app's whole defaults domain, or {} if it has none yet."""
    code, out = _run(["defaults", "export", DOMAIN, "-"])
    if code != 0 or not out.strip():
        return {}
    try:
        doc = plistlib.loads(out.encode("utf-8"))
    except Exception:
        return {}
    return doc if isinstance(doc, dict) else {}


def enabled(prefs: dict[str, Any] | None = None) -> list[str]:
    return normalize((read_prefs() if prefs is None else prefs).get(ENABLED_KEY))


def write_enabled(udids: list[str]) -> None:
    code, out = _run(["defaults", "write", DOMAIN, ENABLED_KEY, "-array", *udids])
    if code != 0:
        raise SimControlError(f"defaults write failed: {out.strip()}")


def aliases(prefs: dict[str, Any] | None = None) -> dict[str, dict[str, Any]]:
    """{UDID: {"alias", "index"}} for every sim the app has ever enabled."""
    blob = (read_prefs() if prefs is None else prefs).get(SLOTS_KEY)
    if isinstance(blob, (bytes, bytearray)):
        try:
            table = json.loads(blob.decode("utf-8"))
        except ValueError:
            return {}
        entries = table.get("entries") if isinstance(table, dict) else None
        if isinstance(entries, dict):
            return {u.upper(): e for u, e in entries.items() if isinstance(e, dict)}
    return {}


# ---- simulators and the device file ----------------------------------------------

def list_simulators() -> list[dict[str, Any]]:
    """Available simulators: [{"udid", "name", "runtime", "booted"}]."""
    code, out = _run(["xcrun", "simctl", "list", "devices", "available", "-j"])
    if code != 0:
        raise SimControlError("`xcrun simctl list` failed — is Xcode installed?")
    try:
        doc = json.loads(out)
    except ValueError as e:
        raise SimControlError("could not parse `xcrun simctl list` output") from e
    sims = []
    for runtime, devs in (doc.get("devices") or {}).items():
        tail = runtime.rsplit(".", 1)[-1].split("-")
        rt = f"{tail[0]} {'.'.join(tail[1:])}".strip()
        for d in devs or []:
            if isinstance(d, dict) and d.get("udid") and d.get("name"):
                sims.append({"udid": d["udid"].upper(), "name": d["name"], "runtime": rt,
                             "booted": d.get("state") == "Booted"})
    sims.sort(key=lambda s: (not s["booted"], s["name"], s["runtime"]))
    return sims


def devices_file() -> str:
    return os.environ.get("IMIRROR_DEVICES_FILE") or os.path.expanduser(
        "~/Library/Application Support/iMirror/devices.json")


def _pid_alive(pid: Any) -> bool:
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def published() -> tuple[bool, dict[str, dict[str, Any]]]:
    """(app_running, {UDID: device-file entry}) for the simulators the app
    lists. app_running is False when there's no live device file."""
    try:
        with open(devices_file(), encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return False, {}
    if not isinstance(doc, dict) or not _pid_alive(doc.get("owner_pid")):
        return False, {}
    out = {}
    for e in doc.get("devices") or []:
        if isinstance(e, dict) and e.get("kind") == "simulator" and isinstance(e.get("udid"), str):
            out[e["udid"].upper()] = e
    return True, out


# ---- resolving what the caller typed ---------------------------------------------

def resolve(query: str, sims: list[dict[str, Any]], known_aliases: dict[str, dict[str, Any]],
            also: list[str] = ()) -> str:
    """A UDID for `query`: a full UDID, an alias the app gave a sim, an exact
    simulator name (any case; with several of that name, the one booted), or
    a unique UDID prefix (4+ chars). `also` are extra UDIDs to accept (the
    enabled list, so a deleted sim can still be disabled)."""
    q = query.strip()
    if not q:
        raise SimControlError("name a simulator: its UDID, alias or name")
    pool = {s["udid"] for s in sims} | {u.upper() for u in also}
    if is_udid(q):
        u = q.upper()
        if u in pool:
            return u
        raise SimControlError(f"no available simulator has UDID {u} (xcrun simctl list devices available)")
    ql = q.lower()
    for u, e in known_aliases.items():
        if str(e.get("alias", "")).lower() == ql and u in pool:
            return u
    named = [s for s in sims if s["name"].lower() == ql]
    if len(named) == 1:
        return named[0]["udid"]
    if len(named) > 1:
        booted = [s for s in named if s["booted"]]
        if len(booted) == 1:
            return booted[0]["udid"]
        choices = ", ".join(f"{s['udid']} ({s['runtime']})" for s in named)
        raise SimControlError(f"several simulators are named {q!r}; pass a UDID: {choices}")
    qn = q.replace("-", "").upper()
    if len(qn) >= 4:
        hits = sorted(u for u in pool if u.replace("-", "").startswith(qn))
        if len(hits) == 1:
            return hits[0]
        if len(hits) > 1:
            raise SimControlError(f"{q!r} is the start of several simulator UDIDs; give more of it")
    raise SimControlError(f"no simulator matches {q!r} (try: imirror-sim.sh list)")


# ---- the operations --------------------------------------------------------------

def status() -> dict[str, Any]:
    """Every available simulator plus any enabled UDID simctl no longer lists,
    with whether it's enabled and what the app publishes for it."""
    prefs = read_prefs()
    on = enabled(prefs)
    names = aliases(prefs)
    running, pub = published()
    sims = list_simulators()
    rows = []
    for s in sims + [{"udid": u, "name": None, "runtime": None, "booted": False}
                     for u in on if u not in {x["udid"] for x in sims}]:
        u = s["udid"]
        e = pub.get(u, {})
        rows.append({"udid": u, "name": s["name"], "runtime": s["runtime"], "booted": s["booted"],
                     "enabled": u in on,
                     "alias": e.get("alias") or names.get(u, {}).get("alias"),
                     "wda": e.get("wda_url"), "state": e.get("state"), "detail": e.get("detail")})
    return {"app_running": running, "simulators": rows}


def enable(queries: list[str]) -> list[str]:
    prefs = read_prefs()
    on = enabled(prefs)
    sims = list_simulators()
    udids = [resolve(q, sims, aliases(prefs)) for q in queries]
    write_enabled(on + [u for u in udids if u not in on])
    return udids


def disable(queries: list[str]) -> list[str]:
    prefs = read_prefs()
    on = enabled(prefs)
    if [q.strip().lower() for q in queries] == ["all"]:
        write_enabled([])
        return on
    try:
        sims = list_simulators()
    except SimControlError:
        sims = []        # no Xcode: UDIDs and aliases still resolve
    udids = [resolve(q, sims, aliases(prefs), also=on) for q in queries]
    write_enabled([u for u in on if u not in udids])
    return udids


def wait_ready(udid: str, timeout: float, poll: float = 2.0) -> dict[str, Any]:
    """Wait for the app to list `udid` as ready; return its entry. Raises on
    timeout, or at once if the app isn't running."""
    deadline = time.monotonic() + timeout
    entry: dict[str, Any] = {}
    while True:
        running, pub = published()
        entry = pub.get(udid.upper(), {})
        if entry.get("state") == "ready":
            return entry
        if not running:
            raise SimControlError("the iMirror app isn't running (no live device file); "
                                  "the sim starts when it launches")
        if time.monotonic() >= deadline:
            what = entry.get("state") or "not listed yet"
            raise SimControlError(f"{udid} is not ready after {int(timeout)}s ({what}"
                                  + (f": {entry['detail']}" if entry.get("detail") else "") + ")")
        time.sleep(poll)


# ---- CLI -------------------------------------------------------------------------

USAGE = """usage: imirror-sim.sh <command> [args]

  list                         every simulator: enabled?, alias, WDA port, state
  enable <sim>… [--wait[=S]]   run WebDriverAgent on these sims (UDID, alias or name);
                               --wait blocks until each is ready (default 600 s)
  disable <sim>… | all         stop them (the sims stay booted)
  wait <sim> [seconds]         block until the app lists <sim> as ready

The iMirror app must be running for anything to start; the list it reads is
`defaults read com.local.imirror imirror.enabledSimulators`."""


def _print_list() -> None:
    st = status()
    if not st["app_running"]:
        print("(the iMirror app is not running — enabled sims start when it launches)")
    for r in st["simulators"]:
        mark = "on " if r["enabled"] else "off"
        name = f"{r['name']} — {r['runtime']}" if r["name"] else "(not in simctl)"
        port = f":{r['wda'].rsplit(':', 1)[-1]}" if r["wda"] else None
        bits = [b for b in (r["alias"], port, r["state"], r["detail"]) if b]
        extra = f"  [{' · '.join(bits)}]" if r["enabled"] and bits else ""
        print(f"{mark}  {r['udid']}  {name}{' (booted)' if r['booted'] else ''}{extra}")


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(USAGE)
        return 0 if argv else 2
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "list":
            _print_list()
        elif cmd == "enable":
            wait = None
            names = []
            for a in args:
                if a == "--wait":
                    wait = 600.0
                elif a.startswith("--wait="):
                    wait = float(a.split("=", 1)[1])
                else:
                    names.append(a)
            if not names:
                raise SimControlError("enable: name at least one simulator")
            udids = enable(names)
            print("enabled: " + " ".join(udids))
            for u in udids if wait is not None else []:
                e = wait_ready(u, wait)
                print(f"ready: {e.get('alias')} {u} {e.get('wda_url')}")
        elif cmd == "disable":
            if not args:
                raise SimControlError("disable: name a simulator, or `all`")
            print("disabled: " + " ".join(disable(args)))
        elif cmd == "wait":
            if not args:
                raise SimControlError("wait: name a simulator")
            prefs = read_prefs()
            u = resolve(args[0], list_simulators(), aliases(prefs), also=enabled(prefs))
            e = wait_ready(u, float(args[1]) if len(args) > 1 else 600.0)
            print(f"ready: {e.get('alias')} {u} {e.get('wda_url')}")
        else:
            print(USAGE, file=sys.stderr)
            return 2
    except SimControlError as e:
        print(f"imirror-sim: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
