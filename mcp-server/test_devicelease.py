"""Unit tests for devicelease's pure core: normalize(), decide() and view().

No device, no lease directory and no real processes (except the few adapter
tests at the end): a fake process table decides who is alive, and a manual
clock moves time. Each test names the rule it pins down.
"""
from __future__ import annotations

import dataclasses
import itertools
import os
import subprocess
import sys
import time

import pytest

import devicelease as dl

P1 = "device:00008140-0006423002D3401C"
P2 = "device:00008150-001928E01404401C"
SIM = "sim:5B3C1F2A-0000-4000-8000-00000000A1B2"


class World:
    """A fake process table. A Proc is alive while it is in the set."""

    def __init__(self):
        self.live = set()
        self._uniq = itertools.count(5000)

    def proc(self, pid: int) -> dl.Proc:
        p = dl.Proc(pid, next(self._uniq))
        self.live.add(p)
        return p

    def kill(self, p: dl.Proc) -> None:
        self.live.discard(p)

    def alive(self, p: dl.Proc) -> bool:
        return p in self.live


CFG = dl.Config(boot="BOOT-1", wall_offset=1_760_000_000.0)


def who(chain, anchor=None, kind="session", label="", client="mcp", **kw) -> dl.Caller:
    chain = tuple(chain)
    return dl.Caller(chain=chain, anchor=anchor or chain[1], kind=kind,
                     label=dl.norm_label(label), client=client, via="test",
                     cwd="/Users/x/wt", **kw)


class Sim:
    """decide() over one shared state with a hand-moved clock."""

    def __init__(self, world: World, cfg: dl.Config = CFG):
        self.w, self.cfg = world, cfg
        self.state: dict = {}
        self.now = 1000.0
        self._ids = itertools.count(1)
        self.events: list = []

    def new_id(self) -> str:
        return f"L{next(self._ids)}"

    def do(self, me, op, keys, **kw) -> dl.Outcome:
        req = dl.Request(op=op, keys=tuple(keys), **kw)
        self.state, out, ev = dl.decide(self.state, req, me, self.now, self.w.alive,
                                        self.cfg, self.new_id)
        self.events.extend(ev)
        return out

    def ensure(self, me, *keys, **kw):
        return self.do(me, "ensure", keys, **kw)

    def norm(self):
        self.state, ev = dl.normalize(self.state, self.now, self.w.alive, self.cfg)
        return ev

    def holders(self, key):
        return (self.state["keys"].get(key) or {}).get("holders") or []

    def top(self, key):
        hs = self.holders(key)
        return hs[-1] if hs else None

    def belief(self, out, key):
        return {key: {"lease_id": out.lease_ids[key], "epoch": out.epochs[key]}}


@pytest.fixture
def w():
    return World()


@pytest.fixture
def s(w):
    return Sim(w)


@pytest.fixture
def procs(w):
    """terminal tab → session S (claude) → its MCP server and Bash; run.sh R
    started from S's Bash; a second session B in another tab."""
    class P:
        pass
    p = P()
    p.term = w.proc(100)
    p.S = w.proc(200)
    p.S_mcp = w.proc(201)
    p.S_bash = w.proc(202)
    p.R = w.proc(300)
    p.R_cli = w.proc(301)
    p.R_claude = w.proc(302)       # run.sh's `claude -p`
    p.R_mcp = w.proc(303)
    p.term2 = w.proc(400)
    p.B = w.proc(401)
    p.B_mcp = w.proc(402)
    p.C = w.proc(500)
    p.C_mcp = w.proc(501)
    p.s_mcp = who([p.S_mcp, p.S, p.term])
    p.b_mcp = who([p.B_mcp, p.B, p.term2])
    p.c_mcp = who([p.C_mcp, p.C, p.term2])
    # run.sh reserving: the CLI's anchor is run.sh itself (--anchor-pid $$)
    p.r_res = who([p.R_cli, p.R, p.S_bash, p.S, p.term], anchor=p.R, kind="run", client="cli")
    return p


# ---- grant, busy, renew --------------------------------------------------------

def test_free_key_is_granted(s, procs):
    out = s.ensure(procs.s_mcp, P1)
    assert out.status == "held" and out.changed
    top = s.top(P1)
    assert top["lease_id"] == out.lease_id == out.lease_ids[P1]
    assert dl.Proc(top["anchor"]["pid"], top["anchor"]["uniqueid"]) == procs.S
    assert top["mode"] == "auto" and top["idle_s"] == 300


def test_foreign_holder_gets_busy_and_nothing_changes(s, procs):
    s.ensure(procs.s_mcp, P1)
    before = dict(s.state)
    out = s.ensure(procs.b_mcp, P1)
    assert out.status == "busy" and out.code == "DEVICE_BUSY"
    assert out.reasons == {P1: "foreign"}
    assert out.blocked_on[0]["holder"]["pid"] == procs.S.pid
    assert not out.changed and s.state["keys"] == before["keys"]
    assert not s.state["tickets"], "an auto call never queues"


def test_respawned_server_with_the_same_anchor_renews_without_lost(s, w, procs):
    first = s.ensure(procs.s_mcp, P1)
    respawned = who([w.proc(210), procs.S, procs.term])
    s.now += 100
    out = s.ensure(respawned, P1)
    assert out.status == "held" and out.lease_id == first.lease_id
    assert s.top(P1)["last_used_mono"] == s.now


def test_multi_key_request_is_all_or_nothing(s, procs):
    s.ensure(procs.b_mcp, P2)
    out = s.ensure(procs.s_mcp, P1, P2)
    assert out.status == "busy"
    assert s.top(P1) is None, "the free phone was not taken alone"
    s.do(procs.b_mcp, "release", [P2])
    out = s.ensure(procs.s_mcp, P1, P2)
    assert out.status == "held" and s.top(P1)["lease_id"] == s.top(P2)["lease_id"]


# ---- normalize: anchors, liveness, lifetime -----------------------------------

def test_dead_anchor_frees_the_device(s, w, procs):
    s.ensure(procs.s_mcp, P1)
    w.kill(procs.S)
    s.norm()
    assert s.top(P1) is None
    assert s.state["keys"][P1]["last_release"]["reason"] == "anchor-gone"


def test_pid_reused_with_a_different_uniqueid_is_not_the_holder(s, w, procs):
    s.ensure(procs.s_mcp, P1)
    w.kill(procs.S)
    w.live.add(dl.Proc(procs.S.pid, 999_999))         # same pid, new process
    s.norm()
    assert s.top(P1) is None


def test_pid_1_anchor_is_never_valid_even_if_alive(s, w):
    launchd = dl.Proc(1, 1)
    w.live.add(launchd)
    me = who([w.proc(700), launchd], anchor=launchd)
    s.ensure(me, P1)
    s.norm()
    assert s.top(P1) is None, "a pid-1 hold would cover every process"


def test_auto_hold_lapses_after_idle(s, procs):
    s.ensure(procs.s_mcp, P1)
    s.now += 299
    s.norm()
    assert s.top(P1) is not None
    s.now += 2
    s.norm()
    assert s.top(P1) is None
    assert s.state["keys"][P1]["last_release"]["reason"] == "expired"


def test_explicit_hold_until_outlives_idle(s, procs):
    s.do(procs.s_mcp, "acquire", [P1], mode="explicit", hold_s=900)
    s.now += 600                                     # idle for 10 min
    s.norm()
    assert s.top(P1) is not None
    s.now += 301
    s.norm()
    assert s.top(P1) is None


def test_agent_holds_lapse_after_20_minutes_unused_whatever_hold_s_says(s, procs):
    s.do(procs.s_mcp, "acquire", [P1], mode="explicit", hold_s=3600)
    s.now += 1199
    s.norm()
    assert s.top(P1) is not None
    s.now += 2
    s.norm()
    assert s.top(P1) is None


def test_script_reservations_are_not_held_to_the_agent_ceiling(s, procs):
    s.do(procs.r_res, "acquire", [P1], mode="reserve", hold_s=7200)
    s.now += 3600
    s.norm()
    assert s.top(P1) is not None
    assert s.top(P1)["hold_until_mono"] == 1000.0 + 7200


def test_hold_s_is_clamped(s, procs):
    s.do(procs.s_mcp, "acquire", [P1], mode="explicit", hold_s=99_999)
    assert s.top(P1)["hold_until_mono"] == 1000.0 + 3600
    s.do(procs.r_res, "acquire", [P2], mode="reserve", hold_s=99_999)
    assert s.top(P2)["hold_until_mono"] == 1000.0 + 21600
    s.do(procs.b_mcp, "acquire", [SIM], mode="explicit", hold_s=5)
    assert s.top(SIM)["hold_until_mono"] == 1000.0 + 60


def test_terminal_holds_idle_out_after_90_seconds(s, w):
    shell = w.proc(800)
    me = who([w.proc(801), shell], kind="terminal", client="cli")
    s.ensure(me, P1)
    assert s.top(P1)["idle_s"] == 90
    s.now += 91
    s.norm()
    assert s.top(P1) is None


def test_boot_id_change_drops_holds_and_tickets(s, procs):
    s.ensure(procs.s_mcp, P1)
    s.do(procs.b_mcp, "acquire", [P1], wait=True)
    assert s.state["tickets"]
    s.cfg = dl.Config(boot="BOOT-2", wall_offset=CFG.wall_offset)
    s.norm()
    assert s.top(P1) is None and not s.state["tickets"]
    assert s.state["boot"] == "BOOT-2"


def test_a_future_hold_until_is_not_mistaken_for_a_reboot(s, procs):
    s.do(procs.r_res, "acquire", [P1], mode="reserve", hold_s=21600)
    s.norm()
    assert s.top(P1) is not None


def test_newer_protocol_is_refused(s, procs):
    with pytest.raises(dl.StateError, match="restart this session's MCP"):
        dl.decide({"protocol": 2}, dl.Request("ensure", (P1,)), procs.s_mcp, 1.0,
                  s.w.alive, CFG, s.new_id)


def test_unknown_fields_survive_a_rewrite(s, procs):
    s.ensure(procs.s_mcp, P1)
    s.do(procs.b_mcp, "acquire", [P1], wait=True)
    s.state["from_the_future"] = {"x": 1}
    s.state["keys"][P1]["key_extra"] = [1, 2]
    s.state["keys"][P1]["holders"][-1]["entry_extra"] = "kept"
    s.state["tickets"][0]["ticket_extra"] = True
    s.now += 10
    s.ensure(procs.s_mcp, P1)
    s.ensure(procs.c_mcp, P2)
    assert s.state["from_the_future"] == {"x": 1}
    assert s.state["keys"][P1]["key_extra"] == [1, 2]
    assert s.top(P1)["entry_extra"] == "kept"
    assert s.state["tickets"][0]["ticket_extra"] is True


# ---- coverage on the real chain ------------------------------------------------

def test_run_sh_child_is_covered_while_its_nearest_claude_ancestor_differs(s, w, procs):
    """The critics' blocker: antsignalctl under run.sh has S as its nearest
    Claude ancestor, yet run.sh's hold must cover it."""
    s.do(procs.r_res, "acquire", [P1], mode="reserve", hold_s=1800)
    child = who([w.proc(310), procs.R, procs.S_bash, procs.S, procs.term],
                anchor=procs.S, client="cli")
    out = s.ensure(child, P1)
    assert out.status == "covered"
    assert out.covered_by[P1]["anchor"] == procs.R
    out = s.ensure(procs.s_mcp, P1)                  # S itself: a run it started
    assert out.status == "busy" and out.reasons[P1] == "descendant"
    assert "a run you started" in out.message


def test_run_sh_child_is_covered_with_no_claude_ancestor_at_all(s, w):
    tab = w.proc(900)
    run = w.proc(901)
    res = who([w.proc(902), run, tab], anchor=run, kind="run", client="cli")
    s.do(res, "acquire", [P1], mode="reserve")
    child = who([w.proc(903), run, tab], anchor=tab, kind="terminal", client="cli")
    assert s.ensure(child, P1).status == "covered"


def test_covered_calls_keep_the_covering_hold_alive(s, w, procs):
    s.ensure(procs.s_mcp, P1)                        # S: auto hold, idle 300
    sub = who([w.proc(220), w.proc(221), procs.S_bash, procs.S, procs.term])
    for _ in range(4):
        s.now += 200
        assert s.ensure(sub, P1).status == "covered"
    assert s.top(P1) is not None, "800 s later the covered calls kept it"


def test_reserve_by_a_descendant_pushes_and_pop_restores_the_original_lease(s, procs):
    mine = s.ensure(procs.s_mcp, P1)
    s.now += 10
    out = s.do(procs.r_res, "acquire", [P1], mode="reserve", hold_s=21600)
    assert out.status == "held" and out.lease_id != mine.lease_id
    assert s.holders(P1)[0]["frozen"] is not None
    s.now += 2 * 3600                                # far past S's idle window
    out = s.ensure(procs.s_mcp, P1, believed=s.belief(mine, P1))
    assert out.status == "busy" and out.reasons[P1] == "descendant"
    s.norm()
    assert len(s.holders(P1)) == 2, "a suspended hold does not age"
    s.do(procs.r_res, "release", [P1])
    top = s.top(P1)
    assert top["lease_id"] == mine.lease_id and top["frozen"] is None
    assert top["last_used_mono"] == s.now
    out = s.ensure(procs.s_mcp, P1, believed=s.belief(mine, P1))
    assert out.status == "held" and out.lease_id == mine.lease_id, "no LOST after the pop"


def test_suspended_hold_dies_with_its_anchor(s, w, procs):
    s.ensure(procs.s_mcp, P1)
    s.do(procs.r_res, "acquire", [P1], mode="reserve")
    w.kill(procs.S)
    s.norm()
    assert [h["anchor"]["pid"] for h in s.holders(P1)] == [procs.R.pid]


def test_push_depth_is_capped(s, w, procs):
    s.ensure(procs.s_mcp, P1)
    chain = [procs.S, procs.term]
    for i in range(3):
        a = w.proc(1000 + i)
        chain = [a] + chain
        s.do(who([w.proc(1100 + i)] + chain, anchor=a, kind="run", client="cli"),
             "acquire", [P1], mode="reserve")
    a = w.proc(1200)
    out = s.do(who([w.proc(1201), a] + chain, anchor=a, kind="run", client="cli"),
               "acquire", [P1], mode="reserve")
    assert out.status == "busy" and out.reasons[P1] == "depth"


# ---- LOST ------------------------------------------------------------------------

def test_lost_once_when_someone_else_used_it_then_busy(s, procs):
    mine = s.ensure(procs.s_mcp, P1)
    s.now += 301
    assert s.ensure(procs.b_mcp, P1).status == "held"
    out = s.ensure(procs.s_mcp, P1, believed=s.belief(mine, P1))
    assert out.status == "lost" and out.code == "DEVICE_RESERVATION_LOST"
    out = s.ensure(procs.s_mcp, P1)                  # the belief was dropped
    assert out.status == "busy"


def test_lost_even_when_the_device_is_free_again_if_it_was_used_meanwhile(s, procs):
    mine = s.ensure(procs.s_mcp, P1)
    s.now += 301
    s.ensure(procs.b_mcp, P1)
    s.do(procs.b_mcp, "release", [P1])
    out = s.ensure(procs.s_mcp, P1, believed=s.belief(mine, P1))
    assert out.status == "lost"


def test_silent_regrant_when_nobody_used_it_since(s, procs):
    mine = s.ensure(procs.s_mcp, P1)
    s.now += 400
    out = s.ensure(procs.s_mcp, P1, believed=s.belief(mine, P1))
    assert out.status == "held" and out.lease_id != mine.lease_id


def test_renew_needs_my_own_top_entry(s, procs):
    s.do(procs.r_res, "acquire", [P1], mode="reserve", hold_s=60)
    assert s.do(procs.r_res, "renew", [P1], hold_s=900).status == "held"
    assert s.top(P1)["hold_until_mono"] == s.now + 900
    s.now += 2000
    out = s.do(procs.r_res, "renew", [P1], hold_s=900)
    assert out.status == "lost" and out.code == "DEVICE_RESERVATION_LOST"
    assert s.top(P1) is None, "renew never grants"


def test_touch_is_renew_only(s, procs):
    mine = s.ensure(procs.s_mcp, P1)
    s.now += 100
    assert s.do(procs.s_mcp, "touch", [P1], believed=s.belief(mine, P1)).status == "held"
    s.now += 400
    out = s.do(procs.s_mcp, "touch", [P1], believed=s.belief(mine, P1))
    assert out.status == "lost"
    assert s.top(P1) is None, "the heartbeat never grants"


def test_touch_sees_a_push_as_busy(s, procs):
    mine = s.ensure(procs.s_mcp, P1)
    s.do(procs.r_res, "acquire", [P1], mode="reserve")
    out = s.do(procs.s_mcp, "touch", [P1], believed=s.belief(mine, P1))
    assert out.status == "busy" and out.reasons[P1] == "descendant"


# ---- orphans and covered-only ---------------------------------------------------

def test_orphan_of_a_killed_reservation_is_refused_not_granted(s, w, procs):
    s.do(procs.r_res, "acquire", [P1], mode="reserve", hold_s=1800)
    claude_p = who([procs.R_mcp, procs.R_claude, procs.R, procs.S_bash, procs.S, procs.term],
                   anchor=procs.R_claude)
    assert s.ensure(claude_p, P1).status == "covered"
    w.kill(procs.R)                                  # kill -9 run.sh
    orphan = who([procs.R_mcp, procs.R_claude], anchor=procs.R_claude)
    out = s.ensure(orphan, P1)
    assert out.status == "lost" and out.reasons[P1] == "orphan"
    assert s.top(P1) is None
    assert s.ensure(procs.b_mcp, P1).status == "held", "anyone else may take it at once"


def test_covered_only_caller_never_takes_a_hold_by_itself(s, w, procs):
    run_agent = who([procs.R_mcp, procs.R_claude, procs.R, procs.S_bash, procs.S, procs.term],
                    anchor=procs.R_claude, covered_only=True)
    out = s.ensure(run_agent, P1)
    assert out.status == "lost" and out.reasons[P1] == "covered-only"
    assert "run.sh scenario" in out.message
    assert s.top(P1) is None
    s.do(procs.r_res, "acquire", [P1], mode="reserve")
    assert s.ensure(run_agent, P1).status == "covered"
    reserving = dl.Caller(**{**procs.r_res.__dict__, "covered_only": True})
    assert s.do(reserving, "acquire", [P2], mode="reserve").status == "held", \
        "run.sh's own reservation is explicit, so still allowed"


def test_in_process_orphan_flag_blocks_auto_but_not_explicit(s, w, procs):
    me = who([procs.B_mcp, procs.B, procs.term2], orphaned=True)
    assert s.ensure(me, P1).status == "lost"
    assert s.do(me, "acquire", [P1], mode="explicit").status == "held"


# ---- labels ----------------------------------------------------------------------

def test_label_rules(s, w, procs):
    x = who([procs.S_mcp, procs.S, procs.term], label=" Explorer ")
    assert s.ensure(x, P1).status == "held"
    assert s.top(P1)["label"] == "explorer"
    out = s.ensure(procs.s_mcp, P1)                  # unlabelled MCP call
    assert out.status == "busy" and out.reasons[P1] == "label"
    assert "agent=" in out.message
    y = who([procs.S_mcp, procs.S, procs.term], label="writer")
    out = s.ensure(y, P1)
    assert out.status == "busy" and out.reasons[P1] == "subagent"
    cli = who([w.proc(230), procs.S_bash, procs.S, procs.term], anchor=procs.S, client="cli")
    assert s.ensure(cli, P1).status == "held", "antsignalctl cannot carry a label"
    assert s.ensure(who([procs.S_mcp, procs.S, procs.term], label="EXPLORER"), P1).status == "held"


def test_named_agents_never_share_an_unnamed_hold(s, procs):
    """Riding the parent's unnamed hold let two named subagents drive one
    phone at once. A named agent waits until that hold is idle, then it
    passes to that one agent only."""
    s.ensure(procs.s_mcp, P1)
    first = s.top(P1)["lease_id"]
    x = who([procs.S_mcp, procs.S, procs.term], label="x")
    y = who([procs.S_mcp, procs.S, procs.term], label="y")
    out = s.ensure(x, P1)
    assert out.status == "busy" and out.reasons[P1] == "unnamed"
    assert "agent name" in out.message and out.retry_after_s == 30
    assert s.do(x, "inspect", [P1], mode="auto").status == "busy"
    s.now += 29
    assert s.ensure(x, P1).status == "busy"
    s.now += 1
    assert s.do(x, "inspect", [P1], mode="auto").status == "not_held", "reads run free"
    out = s.ensure(x, P1)
    assert out.status == "held" and s.top(P1)["label"] == "x"
    assert out.lease_id != first and len(s.holders(P1)) == 1
    assert s.state["keys"][P1]["last_release"]["reason"] == "handoff"
    assert s.ensure(y, P1).reasons[P1] == "subagent"
    assert s.ensure(procs.s_mcp, P1).reasons[P1] == "label"
    view = dl.view(s.state, x, s.now, s.w.alive, s.cfg)[P1]
    assert view["state"] == "yours"


def test_a_named_agent_still_rides_an_antsignalctl_hold(s, w, procs):
    cli = dataclasses.replace(who([w.proc(230), procs.S_bash, procs.S, procs.term],
                                  anchor=procs.S, client="cli"), via="imirror-lease ensure")
    assert s.ensure(cli, P1).status == "held"
    x = who([procs.S_mcp, procs.S, procs.term], label="x")
    assert s.ensure(x, P1).status == "held", "antsignalctl cannot carry a name"
    assert s.top(P1)["label"] == ""


def test_a_named_queued_agent_gets_the_idle_unnamed_hold(s, procs):
    s.ensure(procs.s_mcp, P1)
    x = who([procs.S_mcp, procs.S, procs.term], label="x")
    out = s.do(x, "acquire", [P1], mode="explicit", wait=True)
    assert out.status == "queued"
    s.now += 31
    out = s.do(x, "acquire", [P1], mode="explicit", wait=True)
    assert out.status == "held" and s.top(P1)["label"] == "x"
    assert not s.state["tickets"], "its ticket is spent"


# ---- tickets, claim windows and FIFO --------------------------------------------

def test_only_explicit_waits_create_tickets(s, procs):
    s.ensure(procs.s_mcp, P1)
    s.ensure(procs.b_mcp, P1)
    s.do(procs.b_mcp, "acquire", [P1], mode="explicit")
    assert not s.state["tickets"]
    out = s.do(procs.b_mcp, "acquire", [P1], mode="explicit", wait=True)
    assert out.status == "queued" and out.position == 1 and len(s.state["tickets"]) == 1


def test_a_second_wait_joins_the_same_ticket(s, procs):
    s.ensure(procs.s_mcp, P1)
    a = s.do(procs.b_mcp, "acquire", [P1], wait=True)
    s.now += 20
    b = s.do(procs.b_mcp, "acquire", [P1], wait=True)
    assert a.ticket == b.ticket and len(s.state["tickets"]) == 1
    assert s.state["tickets"][0]["seen_mono"] == s.now, "refreshed after 5 s"


def test_seen_is_refreshed_at_most_every_5_s(s, procs):
    s.ensure(procs.s_mcp, P1)
    s.do(procs.b_mcp, "acquire", [P1], wait=True)
    s.now += 4
    out = s.do(procs.b_mcp, "acquire", [P1], wait=True)
    assert not out.changed, "a waiter's poll costs no write"


def test_grant_to_a_live_waiter_has_a_90_s_claim_window(s, procs):
    s.ensure(procs.s_mcp, P1)
    s.do(procs.b_mcp, "acquire", [P1], wait=True, hold_s=600)
    s.now += 10
    s.do(procs.s_mcp, "release", [P1])
    top = s.top(P1)
    assert top["anchor"]["pid"] == procs.B.pid
    assert top["claim_until_mono"] == s.now + 90
    out = s.ensure(procs.b_mcp, P1)                  # any request claims it
    assert out.status == "held" and s.top(P1)["claim_until_mono"] is None
    assert s.top(P1)["hold_until_mono"] == s.now + 600


def test_grant_to_an_absent_waiter_has_10_s_and_then_the_next_ticket_goes(s, procs):
    s.ensure(procs.s_mcp, P1)
    s.do(procs.b_mcp, "acquire", [P1], wait=True)
    s.now += 1
    s.do(procs.c_mcp, "acquire", [P1], wait=True)
    s.now += 31                                      # nobody refreshes for 31 s
    s.do(procs.s_mcp, "release", [P1])
    assert s.top(P1)["anchor"]["pid"] == procs.B.pid
    assert s.top(P1)["claim_until_mono"] == s.now + 10
    s.do(procs.c_mcp, "acquire", [P1], wait=True)   # C is still in line
    s.now += 11
    s.norm()
    assert s.top(P1)["anchor"]["pid"] == procs.C.pid, "B's grant lapsed; C is next"
    assert not s.state["tickets"]


def test_tickets_expire_when_not_seen(s, procs):
    s.ensure(procs.s_mcp, P1)
    s.do(procs.b_mcp, "acquire", [P1], wait=True)
    s.now += 35
    s.ensure(procs.s_mcp, P1)
    assert s.state["tickets"], "a re-call within 30 s, plus 5 s of slack, keeps it"
    s.now += 1
    s.ensure(procs.s_mcp, P1)
    assert not s.state["tickets"]


def test_a_ticket_dies_with_its_anchor(s, w, procs):
    s.ensure(procs.s_mcp, P1)
    s.do(procs.b_mcp, "acquire", [P1], wait=True)
    w.kill(procs.B)
    s.norm()
    assert not s.state["tickets"]


def test_my_own_ticket_never_blocks_me(s, procs):
    s.ensure(procs.c_mcp, P2)
    s.do(procs.b_mcp, "acquire", [P1, P2], wait=True)    # reserves free P1
    assert s.ensure(procs.s_mcp, P1).reasons[P1] == "ticket-ahead"
    out = s.ensure(procs.b_mcp, P1)
    assert out.status == "held", "B's own two-phone ticket does not block B"
    assert not s.state["tickets"], "taking a key drops my ticket on it"


def test_per_key_fifo_never_starves_a_two_phone_ticket(s, w, procs):
    s.ensure(procs.s_mcp, P1)
    s.ensure(procs.b_mcp, P2)
    s.do(procs.c_mcp, "acquire", [P1, P2], wait=True)
    singles = []
    for i in range(5):
        a = w.proc(2000 + i)
        me = who([w.proc(2100 + i), a, procs.term2])
        singles.append(me)
        s.now += 1
        s.do(me, "acquire", [P1], wait=True)
    s.now += 1
    s.do(procs.s_mcp, "release", [P1])
    assert s.top(P1) is None, "P1 waits for the earlier two-phone ticket"
    out = s.ensure(singles[0], P1)
    assert out.status == "busy" and out.reasons[P1] == "ticket-ahead"
    s.now += 1
    s.do(procs.b_mcp, "release", [P2])
    assert s.top(P1)["anchor"]["pid"] == procs.C.pid
    assert s.top(P2)["anchor"]["pid"] == procs.C.pid
    s.ensure(procs.c_mcp, P1, P2)
    s.do(procs.c_mcp, "release", [P1, P2])
    assert s.top(P1)["anchor"]["pid"] == singles[0].anchor.pid


# ---- deadlock ------------------------------------------------------------------

def test_two_party_deadlock(s, procs):
    s.ensure(procs.s_mcp, P1)
    s.ensure(procs.b_mcp, P2)
    assert s.do(procs.s_mcp, "acquire", [P2], wait=True).status == "queued"
    out = s.do(procs.b_mcp, "acquire", [P1], wait=True)
    assert out.status == "deadlock" and out.code == "DEVICE_DEADLOCK"
    assert len(s.state["tickets"]) == 1, "a deadlock enqueues nothing"


def test_three_party_deadlock(s, procs):
    s.ensure(procs.s_mcp, P1)
    s.ensure(procs.b_mcp, P2)
    s.ensure(procs.c_mcp, SIM)
    assert s.do(procs.s_mcp, "acquire", [P2], wait=True).status == "queued"
    assert s.do(procs.b_mcp, "acquire", [SIM], wait=True).status == "queued"
    assert s.do(procs.c_mcp, "acquire", [P1], wait=True).status == "deadlock"


def test_deadlock_through_ancestry(s, procs):
    """S holds P1; S's run.sh waits for P2; B holds P2 and waits for P1. No
    ticket edge joins S to its run, but S is blocked in Bash on it."""
    s.ensure(procs.s_mcp, P1)
    s.ensure(procs.b_mcp, P2)
    assert s.do(procs.r_res, "acquire", [P2], mode="reserve", wait=True).status == "queued"
    assert s.do(procs.b_mcp, "acquire", [P1], wait=True).status == "deadlock"


def test_a_plain_queue_is_not_a_deadlock(s, procs):
    s.ensure(procs.s_mcp, P1)
    assert s.do(procs.b_mcp, "acquire", [P1], wait=True).status == "queued"
    assert s.do(procs.c_mcp, "acquire", [P1], wait=True).status == "queued"


# ---- release and break -----------------------------------------------------------

def test_release_removes_only_my_own_entries(s, procs):
    s.ensure(procs.s_mcp, P1)
    s.do(procs.r_res, "acquire", [P1], mode="reserve")
    out = s.do(procs.s_mcp, "release", [P1])         # S's suspended entry
    assert out.status == "released"
    assert [h["anchor"]["pid"] for h in s.holders(P1)] == [procs.R.pid]
    assert s.do(procs.b_mcp, "release", [P1]).status == "not_held"
    assert s.top(P1) is not None


def test_a_covered_caller_releases_nothing(s, w, procs):
    s.do(procs.r_res, "acquire", [P1], mode="reserve")
    agent = who([procs.R_mcp, procs.R_claude, procs.R, procs.S_bash, procs.S, procs.term],
                anchor=procs.R_claude)
    out = s.do(agent, "release", [P1])
    assert out.status == "not_held" and "the run that started you" in out.message
    assert s.top(P1)["anchor"]["pid"] == procs.R.pid


def test_an_abandoned_unlabelled_wait_never_releases_a_sibling_subagent(s, procs):
    x = who([procs.S_mcp, procs.S, procs.term], label="x")
    s.ensure(x, P1)
    out = s.do(procs.s_mcp, "release", [P1], exact_label=True)
    assert out.status == "not_held" and s.top(P1)["label"] == "x"
    assert s.do(procs.s_mcp, "release", [P1]).status == "released", \
        "a plain unlabelled release still frees every label of the session"


def test_release_all_takes_holds_and_tickets(s, procs):
    s.ensure(procs.b_mcp, P1)
    s.do(procs.r_res, "acquire", [P2], mode="reserve")
    s.do(procs.r_res, "acquire", [P1], mode="reserve", wait=True)
    out = s.do(procs.r_res, "release", [], all_keys=True)
    assert out.status == "released" and s.top(P2) is None and not s.state["tickets"]


def test_break_tombstones_the_holder_and_its_descendants(s, w, procs):
    s.ensure(procs.s_mcp, P1)
    user = who([w.proc(3000), w.proc(3001)], kind="terminal", client="cli")
    out = s.do(user, "break", [P1], reason="iMirror Settings")
    assert out.status == "broken" and s.top(P1) is None
    out = s.ensure(procs.s_mcp, P1)
    assert out.status == "freed_by_user" and out.code == "DEVICE_FREED_BY_USER"
    assert "ask them before using it again" in out.message
    assert s.do(procs.r_res, "acquire", [P1], mode="reserve").status == "freed_by_user"
    assert s.ensure(procs.b_mcp, P1).status == "held", "others are not tombstoned"
    s.do(procs.b_mcp, "release", [P1])
    s.now += 601
    assert s.ensure(procs.s_mcp, P1).status == "held"


# ---- inspect, autowait, fast path ------------------------------------------------

def test_inspect_never_takes_a_hold(s, procs):
    out = s.do(procs.s_mcp, "inspect", [P1])
    assert out.status == "not_held" and s.top(P1) is None
    s.ensure(procs.b_mcp, P1)
    assert s.do(procs.s_mcp, "inspect", [P1]).status == "busy"
    assert s.do(procs.b_mcp, "inspect", [P1]).status == "held"


def test_auto_call_waits_only_if_the_holder_frees_within_20_s(s, procs):
    s.ensure(procs.s_mcp, P1)
    s.now += 290
    out = s.ensure(procs.b_mcp, P1)
    assert out.autowait and 9 <= out.eta_s <= 10
    s.ensure(procs.s_mcp, P1)                        # the holder taps again
    out = s.ensure(procs.b_mcp, P1)
    assert not out.autowait and out.retry_after_s == 300


def test_unchanged_renew_needs_no_write(s, procs):
    s.cfg = dl.Config(boot="BOOT-1", wall_offset=CFG.wall_offset, touch_s=15)
    s.ensure(procs.s_mcp, P1)
    s.now += 5
    assert not s.ensure(procs.s_mcp, P1).changed
    s.now += 15
    assert s.ensure(procs.s_mcp, P1).changed


# ---- view and messages -------------------------------------------------------------

def test_view_states(s, w, procs):
    s.ensure(procs.s_mcp, P1)
    s.do(procs.b_mcp, "acquire", [P1], wait=True)
    v = dl.view(s.state, procs.s_mcp, s.now, w.alive, CFG, keys=[P2])
    assert v[P1]["state"] == "yours" and v[P1]["queue"] == 1
    assert v[P2]["state"] == "free"
    v = dl.view(s.state, procs.b_mcp, s.now, w.alive, CFG)
    assert v[P1]["state"] == "busy" and v[P1]["your_position"] == 1
    sub = who([w.proc(240), w.proc(241), procs.S_bash, procs.S, procs.term])
    assert dl.view(s.state, sub, s.now, w.alive, CFG)[P1]["state"] == "covered"


def test_agent_facing_text_never_offers_a_way_to_force_a_device_free(s, w, procs):
    texts = []
    s.ensure(procs.s_mcp, P1)
    s.do(who([w.proc(3100), w.proc(3101)], client="cli"), "break", [P1], reason="r")
    texts.append(s.ensure(procs.s_mcp, P1).message)
    s.ensure(procs.b_mcp, P1)
    texts.append(s.ensure(procs.c_mcp, P1).message)
    texts.append(s.do(procs.c_mcp, "acquire", [P1], wait=True).message)
    mine = s.ensure(procs.c_mcp, P2)
    s.now += 301
    s.ensure(procs.b_mcp, P2)
    texts.append(s.ensure(procs.c_mcp, P2, believed=s.belief(mine, P2)).message)
    wda = "wda:127.0.0.1:8201"
    s.ensure(procs.c_mcp, SIM)
    s.ensure(procs.b_mcp, wda)
    assert s.do(procs.c_mcp, "acquire", [wda], wait=True).status == "queued"
    out = s.do(procs.b_mcp, "acquire", [SIM], wait=True)
    assert out.status == "deadlock"
    texts.append(out.message)
    assert len(texts) == 5
    for t in texts:
        assert t.startswith("Nothing was sent.")
        assert "break" not in t and "IMIRROR_LEASE" not in t and "off" not in t.split()


# ---- identity: Claude detection and anchors ---------------------------------------

@pytest.mark.parametrize("path,argv0,expected", [
    ("/Users/x/.local/share/claude/versions/2.1.304", "claude", True),
    ("/Users/x/.local/share/claude/versions/2.1.304", "/Users/x/.local/bin/claude", True),
    ("/Users/x/.local/share/claude/versions/2.1.278", "ugrep", False),   # a helper
    ("/opt/homebrew/bin/claude", "claude", True),
    ("/usr/local/bin/node", "claude", False),
    ("/Applications/Claude.app/Contents/MacOS/Claude", "/Applications/Claude.app/Contents/MacOS/Claude", False),
    ("/bin/zsh", "-zsh", False),
    ("", "claude", False),
])
def test_claude_detection(path, argv0, expected):
    assert dl.is_claude(path, argv0) is expected


def _pi(pid, ppid, uid=501, name="x"):
    return dl.ProcInfo(pid, ppid, uid, pid * 10, name)


PATHS = {
    20: "/Users/x/.local/share/claude/versions/2.1.304",   # claude
    21: "/Users/x/.local/share/claude/versions/2.1.304",   # its ugrep helper
    90: "/Applications/iMirror.app/Contents/MacOS/iMirror",
}
ARGV0 = {20: "claude", 21: "ugrep"}


def anchor(chain, anchor_pid=None):
    return dl.find_anchor(chain, anchor_pid, my_uid=501, path_of=lambda p: PATHS.get(p, "/bin/zsh"),
                          argv0_of=lambda p: ARGV0.get(p, "zsh"))


def test_anchor_is_the_nearest_claude_skipping_its_helpers():
    chain = [_pi(30, 21), _pi(21, 20), _pi(20, 10), _pi(10, 5, uid=0, name="login"), _pi(1, 0, 0)]
    p, kind = anchor(chain)
    assert (p.pid, kind) == (20, "session")


def test_anchor_falls_back_to_the_terminal_tab_shell():
    chain = [_pi(40, 31), _pi(31, 30), _pi(30, 10), _pi(10, 1, uid=0, name="login"), _pi(1, 0, 0)]
    p, kind = anchor(chain)
    assert (p.pid, kind) == (30, "terminal")


def test_anchor_below_launchd_is_the_highest_same_uid_process():
    chain = [_pi(40, 31), _pi(31, 30), _pi(30, 1), _pi(1, 0, 0)]
    assert anchor(chain)[0].pid == 30


def test_anchor_pid_must_be_in_my_chain_and_never_pid_1_or_another_user():
    chain = [_pi(40, 31), _pi(31, 20), _pi(20, 10), _pi(10, 1, uid=0), _pi(1, 0, 0)]
    assert anchor(chain, 31) == (chain[1], "run")
    with pytest.raises(dl.Unkeyable):
        anchor(chain, 777)
    with pytest.raises(dl.Unkeyable):
        anchor(chain, 1)
    with pytest.raises(dl.Unkeyable):
        anchor(chain, 10)


def test_anchor_pid_of_the_imirror_app_is_kind_app():
    chain = [_pi(91, 90), _pi(90, 1), _pi(1, 0, 0)]
    assert anchor(chain, 90)[1] == "app"


def test_no_anchor_when_my_parent_is_launchd():
    with pytest.raises(dl.Unkeyable):
        anchor([_pi(40, 1), _pi(1, 0, 0)])


def test_break_gate():
    claude_chain = [_pi(30, 20), _pi(20, 10), _pi(10, 1, uid=0), _pi(1, 0, 0)]
    shell_chain = [_pi(40, 30), _pi(30, 10), _pi(10, 1, uid=0), _pi(1, 0, 0)]
    app_chain = [_pi(91, 90), _pi(90, 1), _pi(1, 0, 0)]
    via_sh = [_pi(92, 93), _pi(93, 90), _pi(90, 1), _pi(1, 0, 0)]
    paths = {**PATHS, 93: "/bin/sh"}

    def gate(chain, **kw):
        return dl._break_gate(chain, my_uid=501, path_of=lambda p: paths.get(p, "/bin/zsh"),
                              argv0_of=lambda p: ARGV0.get(p, "zsh"), **kw)
    assert "Claude" in gate(claude_chain, from_app=False, stdin_tty=True)
    assert "Claude" in gate(claude_chain, from_app=True, stdin_tty=True)
    assert "terminal" in gate(shell_chain, from_app=False, stdin_tty=False)
    assert gate(shell_chain, from_app=False, stdin_tty=True) is None
    assert gate(app_chain, from_app=True, stdin_tty=False) is None
    assert gate(via_sh, from_app=True, stdin_tty=False) is None
    assert "iMirror app" in gate(shell_chain, from_app=True, stdin_tty=True)


def test_settings_overrides_only_without_claude_or_under_testing(monkeypatch):
    real = dl._lease_dir_under(dl._home())
    monkeypatch.setattr(dl, "default_lease_dir", lambda: real)     # a path only
    env = {"IMIRROR_LEASE": "off", "IMIRROR_LEASE_DIR": "/tmp/elsewhere",
           "IMIRROR_LEASE_IDLE_S": "5000"}
    st = dl.settings_from_env(env, has_claude=True)
    assert st.enabled and st.lease_dir == real
    assert set(st.ignored) == set(env)
    st = dl.settings_from_env(env, has_claude=False)
    assert not st.enabled and st.lease_dir == "/tmp/elsewhere" and st.idle_s == 900
    st = dl.settings_from_env({**env, "IMIRROR_LEASE_TESTING": "1", "IMIRROR_LEASE_IDLE_S": "1"},
                              has_claude=True)
    assert not st.enabled and st.idle_s == 60
    st = dl.settings_from_env({"IMIRROR_LEASE_CONTEXT": "run", "IMIRROR_LEASE_REQUIRED": "1",
                               "IMIRROR_LEASE_LABELS": "off"}, has_claude=True)
    assert st.covered_only and st.required and not st.labels


def test_default_dir_comes_from_the_password_database(monkeypatch):
    monkeypatch.setenv("HOME", "/nonexistent")
    import pwd
    home = pwd.getpwuid(os.getuid()).pw_dir
    assert dl._home() == home
    assert dl._lease_dir_under(dl._home()) == \
        home + "/Library/Application Support/iMirror/leases"


def test_nothing_given_no_dir_falls_back_past_imirror_lease_dir():
    """Regression: register_server(None) once wrote to the real directory."""
    assert dl.Store().root == os.environ["IMIRROR_LEASE_DIR"]
    assert dl.configured_lease_dir() == os.environ["IMIRROR_LEASE_DIR"]
    path = dl.register_server(None, "test", "imirror_mcp.py")
    try:
        assert path.startswith(os.environ["IMIRROR_LEASE_DIR"] + os.sep)
    finally:
        dl.unregister_server(path)


def test_key_helpers_and_the_launcher_path():
    assert dl.device_key("00008140-0006423002d3401c") == "device:00008140-0006423002D3401C"
    assert dl.sim_key("5b3c1f2a-0000-4000-8000-00000000a1b2").startswith("sim:5B3C1F2A")
    assert dl.wda_key("127.0.0.1", 8100) == "wda:127.0.0.1:8100"
    assert dl.launcher_path().endswith("/Library/Application Support/iMirror/bin/imirror-lease")


@pytest.mark.parametrize("raw,canon", [
    ("device:00008140-0006423002d3401c", "device:00008140-0006423002D3401C"),
    ("sim:5b3c1f2a-0000-4000-8000-00000000a1b2", "sim:5B3C1F2A-0000-4000-8000-00000000A1B2"),
    ("wda:127.0.0.1:8100", "wda:127.0.0.1:8100"),
    ("buddy:e2e", "buddy:e2e"),
])
def test_keys_are_canonical(raw, canon):
    assert dl.normalize_key(raw) == canon


@pytest.mark.parametrize("bad", ["", "device", "Device:X", "device:", "device:a b", "x" * 17 + ":a"])
def test_bad_keys_are_refused(bad):
    with pytest.raises(dl.UsageError):
        dl.normalize_key(bad)


# ---- the process adapter, against real processes ------------------------------------

def test_adapter_reads_this_process_like_ps_does():
    me = dl.proc_info(os.getpid())
    assert me is not None and me.pid == os.getpid() and me.ppid == os.getppid()
    assert me.uid == os.getuid()
    ps = subprocess.run(["ps", "-o", "ppid=,uid=", "-p", str(os.getpid())],
                        capture_output=True, text=True).stdout.split()
    assert [me.ppid, me.uid] == [int(x) for x in ps]
    ucomm = subprocess.run(["ps", "-o", "ucomm=", "-p", str(os.getpid())],
                           capture_output=True, text=True).stdout.strip()
    assert me.comm == ucomm[:16]
    chain = dl.ancestry()
    assert chain[0].pid == os.getpid() and chain[1].pid == os.getppid()
    assert chain[-1].pid == 1 or len(chain) < 64
    assert dl.proc_argv(os.getpid())[:1] and dl.proc_path(os.getpid())


def test_a_zombie_counts_as_dead():
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    deadline = time.time() + 5
    while time.time() < deadline:                     # exited but not reaped
        st = subprocess.run(["ps", "-o", "stat=", "-p", str(child.pid)],
                            capture_output=True, text=True).stdout.strip()
        if st.startswith("Z"):
            break
        time.sleep(0.02)
    assert st.startswith("Z")
    assert not dl.proc_alive(child.pid)
    assert dl.proc_info(child.pid) is None
    child.wait()


def test_uniqueid_tells_a_reused_pid_apart():
    uniq = dl.proc_unique(os.getpid())[0]
    assert dl.proc_alive(os.getpid(), uniq)
    assert not dl.proc_alive(os.getpid(), uniq + 1)
    assert dl.proc_alive(1)                           # launchd, another uid, still readable
    assert not dl.proc_alive(0) and not dl.proc_alive(-5) and not dl.proc_alive(True)


def test_eperm_counts_as_not_this_process(monkeypatch):
    class Fake:
        def proc_pidinfo(self, *a):
            import ctypes
            ctypes.set_errno(1)                       # EPERM
            return 0
    real = dl._libs()
    monkeypatch.setattr(dl, "_libs", lambda: (Fake(), real[1]))
    assert dl.proc_unique(os.getpid()) is None
    assert not dl.proc_alive(os.getpid())


def test_boot_session_id_is_a_uuid():
    b = dl.boot_session_id()
    assert len(b) == 36 and b.count("-") == 4
