#!/usr/bin/env bash
# calfNXT macOS — upstream sync ritual.
#
# Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
#
# Bumps the upstream submodule to a tag, classifies each changed path as
# PORTABLE / SEAM / IGNORED, runs the seam drift checks, and rebuilds.
#
# Usage:
#   tools/upstream-sync.sh vX.Y.Z
# Run from calfnxt-macos/port (or via `make sync-upstream TAG=vX.Y.Z`).
set -euo pipefail

TAG="${1:?upstream tag required, e.g. v2.4.0}"
PORT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="$(cd "$PORT_DIR/../calfnxt" && pwd)"

cd "$UPSTREAM"
OLD="$(git describe --tags --always 2>/dev/null || git rev-parse --short HEAD)"
echo "== upstream sync: $OLD -> $TAG =="

git fetch --tags --quiet
git checkout --quiet "$TAG"
NEW="$(git describe --tags --always 2>/dev/null || git rev-parse --short HEAD)"
echo "now at: $NEW"
echo

# --- Classify changed paths -------------------------------------------------
CHANGED="$(git diff --name-only "$OLD" "$NEW" 2>/dev/null || true)"
if [ -z "$CHANGED" ]; then
  echo "no changes between $OLD and $NEW"
  exit 0
fi

portable=(); seam=(); ignored=()
while IFS= read -r p; do
  [ -z "$p" ] && continue
  case "$p" in
    # Linux-only: never reintroduce
    common/ui/web_host*|common/ui/web_editor.cpp|*gtk*|*x11*|*socketpair*|\
    tools/install-user-vst3.sh|tools/release.sh)
      ignored+=("$p") ;;
    # Seam: review against the port overlay
    common/ui/viz_bin.h|common/ui/viz_source.h|common/ui/viz_hz.*|\
    common/dsp/effect_base.*|tools/codegen/*|ui/src/utils/bridge.ts|\
    ui/src/utils/reportViewport.ts|*/CMakeLists.txt)
      seam+=("$p") ;;
    # Everything else (DSP, descriptors, React/AUX UI) is portable
    *)
      portable+=("$p") ;;
  esac
done <<< "$CHANGED"

echo "PORTABLE (take as-is):    ${#portable[@]}"
printf '  %s\n' "${portable[@]:0:20}"
[ "${#portable[@]}" -gt 20 ] && echo "  … and $(( ${#portable[@]} - 20 )) more"
echo
echo "SEAM (review vs overlay): ${#seam[@]}"
printf '  %s\n' "${seam[@]}"
echo
echo "IGNORED (Linux-only):     ${#ignored[@]}"
printf '  %s\n' "${ignored[@]}"
echo

# --- Seam drift checks + rebuild --------------------------------------------
echo "== seam drift checks =="
"$PORT_DIR/tools/check-seam.sh" "$UPSTREAM"
echo

echo "== rebuild + validate =="
make -C "$PORT_DIR" -j"$(sysctl -n hw.ncpu)"
make -C "$PORT_DIR" check

echo
echo "== sync complete: $NEW =="
[ "${#seam[@]}" -gt 0 ] && echo "NOTE: review the SEAM paths above against the port overlay."
exit 0
