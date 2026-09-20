#!/bin/bash
#-----------------------------------------------------------------------------
# calfNXT macOS — versioned release: clean rebuild, Developer ID sign,
# notarize + staple, and a versioned local backup.
#
#   tools/release.sh 2.3.1.1                  # clean rebuild + sign all 25
#   tools/release.sh 2.3.1.1 --notarize       # + notarize + staple all 25
#   make -C port release VERSION=2.3.1.1 NOTARIZE=1
#
# The version (e.g. 2.3.1.1) is required. It is baked into the bundles
# (CFBundleShortVersionString) and used for the backup folder:
#
#   Releases/2.3.1.1/<Name>.vst3            # versioned local backup (repo root)
#   Releases/calfNXT-macOS-2.3.1.1.zip      # ready for a manual GitHub Release
#
# (dist/ is the scratch/test area; Releases/ is the versioned backup.)
#
# This script always wipes port/build (same as `make clean`) before rebuilding,
# so a notarized run can never pick up stale products or a leftover version.
#
# Credentials: repo-root .env.local (gitignored) — see .env.local.example.
#   CODE_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
#   DEVELOPMENT_TEAM=<TEAMID>
#   NOTARY_PROFILE=com.calfNXT   (keychain profile; one-time `notarytool
#                                 store-credentials` — see port/HOWTO-DISTRIBUTE.md)
#
# Make-style KEY=VALUE overrides (override .env.local):
#   tools/release.sh 2.3.1.1 --notarize \
#     CODE_SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=com.calfNXT
#
# NOTE: local DAW testing does NOT need this script — `make install` produces
# ad-hoc signed bundles, which is correct for this machine. This script is the
# distribution path (other Macs, Gatekeeper). Rebuild/re-sign ⇒ re-notarize.
#-----------------------------------------------------------------------------
set -euo pipefail

PORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$PORT_DIR/.." && pwd)"

NOTARIZE=0
VERSION="${VERSION:-}"

# Optional local release credentials (never commit .env.local).
if [ -f "$ROOT/.env.local" ]; then
  echo "[calfNXT] Loading $ROOT/.env.local"
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env.local"
  set +a
fi

CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-com.calfNXT}"
CONFIG="${CONFIG:-Release}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"

for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    -h|--help)
      sed -n '2,32p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    CONFIG=*|CODE_SIGN_IDENTITY=*|DEVELOPMENT_TEAM=*|NOTARY_PROFILE=*|VERSION=*)
      key="${arg%%=*}"; val="${arg#*=}"
      case "$key" in
        CONFIG) CONFIG="$val" ;;
        CODE_SIGN_IDENTITY) CODE_SIGN_IDENTITY="$val" ;;
        DEVELOPMENT_TEAM) DEVELOPMENT_TEAM="$val" ;;
        NOTARY_PROFILE) NOTARY_PROFILE="$val" ;;
        VERSION) VERSION="$val" ;;
      esac
      ;;
    --*) echo "[calfNXT] ERROR: unknown option '$arg' (supported: --notarize)" >&2; exit 1 ;;
    *)
      if [ -z "$VERSION" ]; then
        VERSION="$arg"
      elif [ "$arg" = "$VERSION" ]; then
        : # already set from the environment; ignore the duplicate
      else
        echo "[calfNXT] ERROR: unexpected argument '$arg'" >&2
        exit 1
      fi
      ;;
  esac
done

# Ask for the version when interactive; fail when scripted.
if [ -z "$VERSION" ] && [ -t 0 ]; then
  read -r -p "Release version (e.g. 2.3.1.1): " VERSION
fi
if [ -z "$VERSION" ]; then
  echo "[calfNXT] ERROR: release version required." >&2
  echo "          Usage: tools/release.sh 2.3.1.1 [--notarize]" >&2
  echo "          or:    make -C port release VERSION=2.3.1.1 NOTARIZE=1" >&2
  exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "[calfNXT] ERROR: version '$VERSION' must look like N.N.N or N.N.N.N" >&2
  exit 1
fi

if [ "$NOTARIZE" = 1 ] && [ "$CODE_SIGN_IDENTITY" = "-" ]; then
  echo "[calfNXT] ERROR: --notarize needs CODE_SIGN_IDENTITY='Developer ID Application: ...'" >&2
  echo "          Set it in .env.local or pass CODE_SIGN_IDENTITY=..." >&2
  exit 1
fi

BUILD_DIR="$PORT_DIR/build"
VST3_DIR="$BUILD_DIR/VST3/$CONFIG"
RELEASES_DIR="$ROOT/Releases"
DIST_VERSION_DIR="$RELEASES_DIR/$VERSION"
DIST_ZIP="$RELEASES_DIR/calfNXT-macOS-$VERSION.zip"

echo "[calfNXT] Release $VERSION — identity: $CODE_SIGN_IDENTITY$([ "$NOTARIZE" = 1 ] && echo ' [notarize]')"

# --- 1. Same wipe as `make clean`, then rebuild with the required version ---
echo "[calfNXT] Clean: $BUILD_DIR"
rm -rf "$BUILD_DIR"

cmake -S "$PORT_DIR" -B "$BUILD_DIR" -G Xcode \
  -DSMTG_XCODE_MANUAL_CODE_SIGN_STYLE=ON \
  -DSMTG_BUILD_UNIVERSAL_BINARY=OFF \
  -DCALFNXT_PORT_VERSION:STRING="$VERSION"

cmake --build "$BUILD_DIR" --config "$CONFIG" --target calfnxt-plugins --parallel "$JOBS"

if [ ! -d "$VST3_DIR" ]; then
  echo "[calfNXT] ERROR: no build products at $VST3_DIR after rebuild" >&2
  exit 1
fi

# Collect the freshly built bundles.
BUNDLES=()
while IFS= read -r -d '' b; do
  BUNDLES+=("$b")
done < <(find "$VST3_DIR" -maxdepth 1 -name '*.vst3' -print0 | sort -z)

if [ "${#BUNDLES[@]}" -eq 0 ]; then
  echo "[calfNXT] ERROR: no .vst3 bundles in $VST3_DIR" >&2
  exit 1
fi

echo "[calfNXT] Signing ${#BUNDLES[@]} bundle(s) ..."

sign_bundle() {
  local bundle="$1"
  if [ "$CODE_SIGN_IDENTITY" = "-" ]; then
    # Ad-hoc: refresh the linker signature after resource embedding.
    codesign --force -s - "$bundle"
  else
    # Developer ID: hardened runtime + secure timestamp are required for notarization.
    codesign --force -s "$CODE_SIGN_IDENTITY" --timestamp --options runtime "$bundle"
  fi
  codesign --verify --deep --strict --verbose=2 "$bundle" 2>&1 | sed 's/^/  /'
  codesign -dv --verbose=4 "$bundle" 2>&1 | grep -E '^(Authority|TeamIdentifier|Identifier)=' | sed 's/^/  /' || true
}

FAILED=()
for bundle in "${BUNDLES[@]}"; do
  name="$(basename "$bundle" .vst3)"
  echo "----------------------------------------------------------------------"
  echo "[calfNXT] $name"
  if ! sign_bundle "$bundle"; then
    echo "[calfNXT] ERROR: signing failed for $name" >&2
    FAILED+=("$name")
  fi
done

if [ "${#FAILED[@]}" -ne 0 ]; then
  echo "[calfNXT] FAILED to sign: ${FAILED[*]}" >&2
  exit 1
fi

# --- 2. Notarize once for the whole suite, then staple each bundle ---------
if [ "$NOTARIZE" = 1 ]; then
  stage_dir="$(mktemp -d /tmp/calfnxt-notarize.XXXXXX)"
  suite_zip="$stage_dir/calfNXT-macOS-$VERSION.zip"
  echo "[calfNXT] notarytool submit (profile: $NOTARY_PROFILE) — ${#BUNDLES[@]} bundles ..."
  # ditto takes one source: stage the bundles, then zip the folder.
  inner="calfNXT-MacOS-$VERSION"
  mkdir -p "$stage_dir/$inner"
  for bundle in "${BUNDLES[@]}"; do
    cp -R "$bundle" "$stage_dir/$inner/"
  done
  ditto -c -k --keepParent "$stage_dir/$inner" "$suite_zip"
  xcrun notarytool submit "$suite_zip" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -rf "$stage_dir"

  for bundle in "${BUNDLES[@]}"; do
    name="$(basename "$bundle" .vst3)"
    echo "[calfNXT] $name: staple ..."
    if ! xcrun stapler staple "$bundle"; then
      echo "[calfNXT] ERROR: staple failed for $name" >&2
      FAILED+=("$name")
      continue
    fi
    xcrun stapler validate "$bundle"
    spctl -a -vv -t install "$bundle" || true
  done

  if [ "${#FAILED[@]}" -ne 0 ]; then
    echo "[calfNXT] FAILED to staple: ${FAILED[*]}" >&2
    exit 1
  fi
fi

# --- 3. Versioned backup + install -----------------------------------------
mkdir -p "$DIST_VERSION_DIR"
for bundle in "${BUNDLES[@]}"; do
  name="$(basename "$bundle")"
  dest="$DIST_VERSION_DIR/$name"
  rm -rf "$dest"
  cp -R "$bundle" "$dest"
  xattr -cr "$dest" 2>/dev/null || true

  # refresh the user install
  dest="$HOME/Library/Audio/Plug-Ins/VST3/$name"
  rm -rf "$dest"
  cp -R "$bundle" "$dest"
  xattr -cr "$dest" 2>/dev/null || true
done

# Suite zip for a manual GitHub Release (contains the stapled bundles).
# Unpacks as calfNXT-MacOS-<version>/, not a dump of 25 bundles in cwd.
rm -f "$DIST_ZIP"
zip_stage="$(mktemp -d /tmp/calfnxt-dist.XXXXXX)"
inner="calfNXT-MacOS-$VERSION"
mkdir -p "$zip_stage/$inner"
for bundle in "${BUNDLES[@]}"; do
  cp -R "$DIST_VERSION_DIR/$(basename "$bundle")" "$zip_stage/$inner/"
done
ditto -c -k --keepParent "$zip_stage/$inner" "$DIST_ZIP"
rm -rf "$zip_stage"

echo "======================================================================"
echo "[calfNXT] Done: $VERSION"
echo "  backup:  $DIST_VERSION_DIR"
echo "  zip:     $DIST_ZIP"
echo "  install: ~/Library/Audio/Plug-Ins/VST3"
[ "$NOTARIZE" = 1 ] && echo "  (notarized + stapled)"
