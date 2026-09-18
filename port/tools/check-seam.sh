#!/usr/bin/env bash
# calfNXT macOS — seam drift checks.
#
# Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
#
#   - viz kinds handled by the WebEditor cover the VizBin kinds
#   - UI→host message types in the bridge alias are all handled
#   - codegen param fields are present in the descriptors
# Exits non-zero on drift. Run via `make check`.
set -euo pipefail

PORT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${1:-}"
if [ -z "$UPSTREAM" ]; then
  UPSTREAM="$(cd "$PORT/../calfnxt" && pwd)"
fi

fail=0
err() { echo "[check-seam] ERROR: $*" >&2; fail=1; }
ok()  { echo "[check-seam] ok: $*"; }

[ -d "$UPSTREAM" ] || { err "upstream submodule missing at $UPSTREAM"; exit 1; }

# --- 1. viz kinds -----------------------------------------------------------
# Kinds the upstream VizBin encoder profiles (from std::strcmp(kind, "...")).
UPSTREAM_KINDS="$(rg -o 'std::strcmp\(kind, "[a-z]+"\)' \
  "$UPSTREAM/common/ui/viz_bin.h" 2>/dev/null | grep -o '"[a-z]*"' | tr -d '"' | sort -u)"
# Kinds the port bridge alias type accepts.
PORT_KINDS="$(rg -o "'(levels|unit|spectrum|gains|corr|gonio|envelope|pitch|midi|gr|bandio|point|tempo|shape|hz|ctrl|lfo|response|comb|wave)'" \
  "$PORT/ui/aliases/bridge.ts" 2>/dev/null | tr -d "'" | sort -u)"

for k in $UPSTREAM_KINDS; do
  if ! printf '%s\n' "$PORT_KINDS" | grep -qx "$k"; then
    err "viz kind '$k' in upstream viz_bin.h not handled by port bridge.ts"
  fi
done
[ "$fail" = 0 ] && ok "viz kinds covered ($(echo $UPSTREAM_KINDS | wc -w | tr -d ' ') kinds)"

# Kinds the port WebEditor drain emits (flushVizArray kind literals) must all
# be accepted by the bridge alias — guards the all-CNXB drain against drift.
DRAIN_KINDS="$(rg -o 'flushVizArray\([^\n]*, "[a-z]+",' \
  "$PORT/native/web_editor.cpp" 2>/dev/null | grep -o '"[a-z]*"' | tr -d '"' | sort -u)"
for k in $DRAIN_KINDS; do
  if ! printf '%s\n' "$PORT_KINDS" | grep -qx "$k"; then
    err "viz kind '$k' emitted by port web_editor.cpp not accepted by port bridge.ts"
  fi
done
[ "$fail" = 0 ] && ok "drain viz kinds covered ($(echo $DRAIN_KINDS | wc -w | tr -d ' ') kinds)"

# --- 2. UI→host message types ----------------------------------------------
# Types the upstream UI posts to the host.
UPSTREAM_MSGS="$(rg -o 'postToHost\(\{[^}]*t: ["'"'"'][a-z_]+["'"'"']' "$UPSTREAM/ui/src" 2>/dev/null \
  | sed -E 's/.*t: ["'"'"']([a-z_]+)["'"'"'].*/\1/' | sort -u)"
# Types the port WebEditor::onWebMessage handles.
PORT_MSGS="$(rg -o 'jsonHasType\(json, "[a-z_]+"\)' \
  "$PORT/native/web_editor.cpp" 2>/dev/null | grep -o '"[a-z_]*"' | tr -d '"' | sort -u)"

for m in $UPSTREAM_MSGS; do
  # viewport is a no-op and _diag is logged natively on the port by design.
  case "$m" in viewport|_diag) continue;; esac
  if ! printf '%s\n' "$PORT_MSGS" | grep -qx "$m"; then
    err "UI→host message type '$m' used upstream not handled by port web_editor.cpp"
  fi
done
[ "$fail" = 0 ] && ok "UI→host message types covered"

# --- 2b. port shim actually bundled ------------------------------------------
# A silent alias miss builds a dead UI (upstream bridge.ts expects
# window.calfnxtNative). When a built bundle exists, assert the port shim won.
SHIM_BUNDLE="$(ls "$PORT"/build/ui-dist/plugins/compressor/assets/compressor-*.js 2>/dev/null | head -1 || true)"
if [ -n "$SHIM_BUNDLE" ]; then
  if ! grep -q "_recvBin" "$SHIM_BUNDLE"; then
    err "built compressor bundle lacks the port __auxbridge shim (vite alias broken?)"
  fi
  if grep -q "calfnxtNative?.post" "$SHIM_BUNDLE"; then
    err "built compressor bundle contains the upstream bridge (vite alias broken?)"
  fi
  [ "$fail" = 0 ] && ok "port bridge shim bundled"
fi

# --- 3. codegen schema -------------------------------------------------------
# Fields the upstream codegen and the port UI rely on in each descriptor param.
for field in id name min max default; do
  if ! rg -q "\"$field\"" "$UPSTREAM/dsp/compressor/compressor.plugin.json" 2>/dev/null; then
    err "param field '$field' missing from upstream descriptor schema"
  fi
done
[ "$fail" = 0 ] && ok "codegen schema fields present"

if [ "$fail" -ne 0 ]; then
  echo "[check-seam] drift detected" >&2
  exit 1
fi
echo "[check-seam] all seam checks passed"
