#!/usr/bin/env bash
# calfNXT macOS — performance baseline capture.
#
# Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
#
# Captures the per-pilot baseline the RT-safety work is measured against:
#   - process µs/block (from the plugin's own timing, when AUXVST_DEBUG=1)
#   - idle CPU of the host with the editor open vs closed
#   - RSS of the WebContent process per open editor
#
# This is a manual harness: run it while the plugin is loaded in a DAW.
# Usage:
#   tools/baseline.sh <plugin-id> [host-process-name]
# Example:
#   tools/baseline.sh compressor Nuendo
set -euo pipefail

PLUGIN="${1:?plugin id required}"
HOST="${2:-}"

echo "== calfNXT baseline: $PLUGIN =="
echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "host: ${HOST:-<unknown>}"
echo

# --- Host process CPU (idle, editor open vs closed) -------------------------
if [ -n "$HOST" ]; then
  PID="$(pgrep -x "$HOST" | head -1 || true)"
  if [ -n "$PID" ]; then
    echo "host pid: $PID"
    echo "host CPU% (sample over 2 s):"
    top -l 2 -pid "$PID" -stats pid,cpu,mem 2>/dev/null | awk 'NR>1{print}' | tail -1
  else
    echo "host '$HOST' not running — start it with the plugin loaded."
  fi
else
  echo "pass the host process name to sample CPU/RSS (e.g. tools/baseline.sh compressor Nuendo)"
fi
echo

# --- WebContent process RSS (one shared process across editors) -------------
echo "WebContent processes (com.apple.WebKit.WebContent):"
ps -axo pid,rss,comm 2>/dev/null | awk '/WebContent/ {printf "  pid=%s rss=%.1f MB\n", $1, $2/1024}'
echo

# --- DSP process time (from the plugin's own debug timing) -------------------
echo "process µs/block: enable AUXVST_DEBUG=1 in the host env and read the"
echo "plugin's stderr timing, or use the Steinberg validator's process test."
echo

echo "== done =="
