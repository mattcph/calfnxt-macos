#!/usr/bin/env bash
# calfNXT macOS — run the Steinberg VST3 validator across all plugins.
#
# Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
#
# Usage: tools/validate-all.sh [build-dir] [Release|Debug]
# Exits non-zero on the first failure. Run via `make check`.
set -euo pipefail

PORT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$PORT/build}"
CONFIG="${2:-Release}"
UPSTREAM="$(cd "$PORT/../calfnxt" && pwd)"

PLUGINS="equalizer stereo transients compressor expander deesser delay reverb \
mbcomp limiter mblimiter harmonics analyzer filter ringmod pulsator \
crusher phaser flanger chorus split tuner octaver bender impulse"

VALIDATOR="$BUILD/bin/$CONFIG/validator"
[ -x "$VALIDATOR" ] || VALIDATOR="$BUILD/bin/validator"
[ -x "$VALIDATOR" ] || { echo "validator not built (run: make)"; exit 1; }

fail=0
for pid in $PLUGINS; do
  name="$(sed -nE 's/.*PACKAGE_NAME[[:space:]]+"([^"]+)".*/\1/p' \
    "$UPSTREAM/dsp/$pid/CMakeLists.txt" | head -1)"
  bundle="$BUILD/VST3/$CONFIG/${name}.vst3"
  if [ ! -d "$bundle" ]; then
    echo "MISSING  $name (build first: make PLUGIN=$pid)"
    fail=1
    continue
  fi
  if "$VALIDATOR" "$bundle" >/dev/null 2>&1; then
    echo "ok       $name"
  else
    echo "FAIL     $name"
    fail=1
  fi
done
exit $fail
