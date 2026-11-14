#!/usr/bin/env bash
# Enable/disable iMirror's Simulators from a shell — no GUI. The running app
# polls the list this edits (`imirror.enabledSimulators` in com.local.imirror)
# every 2 s and brings WebDriverAgent up or down on each sim to match.
#
#   scripts/imirror-sim.sh list
#   scripts/imirror-sim.sh enable "iPhone 17 Pro" --wait     # UDID, alias or name
#   scripts/imirror-sim.sh disable all
#
# The logic lives in mcp-server/sim_control.py (the MCP server's sim_enable /
# sim_disable tools use it too). Standard-library Python only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec /usr/bin/env python3 -I "$ROOT/mcp-server/sim_control.py" "$@"
