"""Shared pytest setup for the MCP server's tests.

Every test gets its own device-lease directory. The real one,
~/Library/Application Support/iMirror/leases, is shared by every live Claude
session on this Mac, so a test that took or broke a lease there would get in
their way. The live suites (IMIRROR_LIVE*) drive real phones, so they keep
the real directory and take real leases.
"""
from __future__ import annotations

import os
import sys

import pytest

# Knobs that change lease behaviour; a test sets its own.
_LEASE_KNOBS = ("IMIRROR_LEASE", "IMIRROR_LEASE_CONTEXT", "IMIRROR_LEASE_REQUIRED",
                "IMIRROR_LEASE_IDLE_S", "IMIRROR_LEASE_LABELS")


def _live() -> bool:
    return any(name.startswith("IMIRROR_LIVE") and value
               for name, value in os.environ.items())


def _real_dir_forbidden() -> str:
    """Stands in for devicelease.default_lease_dir during tests. It is a
    safety net, not a fix: code that ignores IMIRROR_LEASE_DIR fails here
    instead of writing beside the live sessions' leases."""
    raise AssertionError("a test reached the real lease directory; pass a dir or rely "
                         "on IMIRROR_LEASE_DIR")


@pytest.fixture(autouse=True)
def _private_lease_dir(tmp_path, monkeypatch):
    if _live():
        yield
        return
    monkeypatch.setenv("IMIRROR_LEASE_DIR", str(tmp_path / "leases"))
    monkeypatch.setenv("IMIRROR_LEASE_TESTING", "1")
    for name in _LEASE_KNOBS:
        monkeypatch.delenv(name, raising=False)
    try:
        import devicelease
    except ImportError:
        devicelease = None
    if devicelease is not None:
        monkeypatch.setattr(devicelease, "default_lease_dir", _real_dir_forbidden)
    yield
    # Stop the server's lease heartbeat thread; each test makes one.
    server = sys.modules.get("imirror_mcp")
    if server is not None and hasattr(server, "_leases_close"):
        server._leases_close()
