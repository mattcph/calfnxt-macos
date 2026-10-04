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

# --- Reapply the patch queue ------------------------------------------------
# Apply a patch only when the tag still has the old behavior. Verbatim
# presence and a rewrite that already does the job are both "not needed".
# A queue file with no predicate below is reapplied when it applies cleanly.
patch_still_needed() {
  local base
  base="$(basename "$1")"
  case "$base" in
    0004-*)
      grep -q 'Library/Application Support/calfNXT' \
        "$UPSTREAM/dsp/impulse/source/impulse_dsp.cpp" && return 1
      return 0
      ;;
    0005-*)
      grep -q 'vizFloor_' \
        "$UPSTREAM/dsp/tamer/source/tamer_dsp.cpp" && return 1
      return 0
      ;;
    *)
      return 2
      ;;
  esac
}

echo "== patch queue =="
reapplied=0
shopt -s nullglob
for patch in "$PORT_DIR"/patches/*.patch; do
  name="$(basename "$patch")"
  if git apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "  $name: already in $TAG (verbatim), left in the queue"
    continue
  fi
  need=0
  patch_still_needed "$patch" || need=$?
  if [ "$need" -eq 1 ]; then
    echo "  $name: not needed (upstream already has this behavior), left in the queue"
    continue
  fi
  if git apply --check "$patch" >/dev/null 2>&1; then
    git am --quiet "$patch"
    echo "  $name: reapplied"
    reapplied=1
    continue
  fi
  if [ "$need" -eq 2 ]; then
    echo "  $name: no still-needed check, and the hunks do not apply." >&2
    echo "  Add a predicate in tools/upstream-sync.sh or rebase the patch." >&2
    exit 1
  fi
  echo "  $name: still needed, but the hunks no longer match." >&2
  echo "  Rebase that file by hand, replace the patch, and rerun sync." >&2
  exit 1
done
echo

# --- Classify changed paths -------------------------------------------------
CHANGED="$(git diff --name-only "$OLD" "$NEW" 2>/dev/null || true)"
if [ -z "$CHANGED" ] && [ "$reapplied" -eq 0 ]; then
  echo "no changes between $OLD and $NEW"
  exit 0
fi

# allow / known-out live in upstream-paths.txt. Anything else stops the sync.
path_matches() {
  local p="$1" pattern="$2"
  case "$pattern" in
    */) [[ "$p" == "$pattern"* ]] ;;
    *\**) [[ "$p" == $pattern ]] ;;
    *) [[ "$p" == "$pattern" ]] ;;
  esac
}

classify_upstream_path() {
  local p="$1" kind pattern
  local listed
  for listed in known-out allow; do
    while read -r kind pattern; do
      [[ -z "$kind" || "$kind" == \#* ]] && continue
      [[ "$kind" == "$listed" ]] || continue
      if path_matches "$p" "$pattern"; then
        echo "$listed"
        return
      fi
    done < "$PORT_DIR/upstream-paths.txt"
  done
  echo unlisted
}

portable=(); seam=(); ignored=(); unlisted=()
while IFS= read -r p; do
  [ -z "$p" ] && continue
  case "$(classify_upstream_path "$p")" in
    known-out)
      ignored+=("$p") ;;
    unlisted)
      unlisted+=("$p") ;;
    allow)
      case "$p" in
        common/ui/viz_bin.h|common/ui/viz_source.h|common/ui/viz_hz.*|\
        common/dsp/effect_base.*|tools/codegen/*|ui/src/utils/bridge.ts|\
        ui/src/utils/reportViewport.ts|*/CMakeLists.txt)
          seam+=("$p") ;;
        *)
          portable+=("$p") ;;
      esac ;;
  esac
done <<< "$CHANGED"

if [ "${#unlisted[@]}" -ne 0 ]; then
  echo "UNLISTED (not taken — add to port/upstream-paths.txt, or leave unlisted):" >&2
  printf '  %s\n' "${unlisted[@]}" >&2
  exit 1
fi

echo "PORTABLE (take as-is):    ${#portable[@]}"
printf '  %s\n' "${portable[@]:0:20}"
[ "${#portable[@]}" -gt 20 ] && echo "  … and $(( ${#portable[@]} - 20 )) more"
echo
echo "SEAM (review vs overlay): ${#seam[@]}"
if [ "${#seam[@]}" -gt 0 ]; then
  printf '  %s\n' "${seam[@]}"
fi
echo
echo "IGNORED (Linux-only):     ${#ignored[@]}"
if [ "${#ignored[@]}" -gt 0 ]; then
  printf '  %s\n' "${ignored[@]}"
fi
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
