#!/bin/bash
#-----------------------------------------------------------------------------
# calfNXT macOS — release: Developer ID sign, verify, optional notarize + staple.
#
#   tools/release.sh                        # sign all 25 (identity from .env.local / env)
#   tools/release.sh equalizer              # one plugin (substring match on bundle name)
#   tools/release.sh --notarize             # sign + notarize + staple all 25
#   tools/release.sh compressor --notarize  # one plugin, full pipeline
#
# Credentials: repo-root .env.local (gitignored) — see .env.local.example.
#   CODE_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
#   DEVELOPMENT_TEAM=<TEAMID>
#   NOTARY_PROFILE=com.calfNXT   (keychain profile; one-time `notarytool
#                                 store-credentials` — see port/HOWTO-DISTRIBUTE.md)
#
# Make-style KEY=VALUE overrides (override .env.local):
#   tools/release.sh equalizer CODE_SIGN_IDENTITY="Developer ID Application: …" \
#     CONFIG=Release NOTARY_PROFILE=com.calfNXT
#
# NOTE: local DAW testing does NOT need this script — `make install` produces
# ad-hoc signed bundles, which is correct for this machine. This script is the
# distribution path (other Macs, Gatekeeper). Rebuild/re-sign ⇒ re-notarize.
#-----------------------------------------------------------------------------
set -euo pipefail

PORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$PORT_DIR/.." && pwd)"

NOTARIZE=0
MATCH=""

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

for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    -h|--help)
      sed -n '2,22p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    CONFIG=*|CODE_SIGN_IDENTITY=*|DEVELOPMENT_TEAM=*|NOTARY_PROFILE=*)
      key="${arg%%=*}"; val="${arg#*=}"
      case "$key" in
        CONFIG) CONFIG="$val" ;;
        CODE_SIGN_IDENTITY) CODE_SIGN_IDENTITY="$val" ;;
        DEVELOPMENT_TEAM) DEVELOPMENT_TEAM="$val" ;;
        NOTARY_PROFILE) NOTARY_PROFILE="$val" ;;
      esac
      ;;
    --*) echo "[calfNXT] ERROR: unknown option '$arg' (supported: --notarize)" >&2; exit 1 ;;
    *) MATCH="$arg" ;;
  esac
done

if [ "$NOTARIZE" = 1 ] && [ "$CODE_SIGN_IDENTITY" = "-" ]; then
  echo "[calfNXT] ERROR: --notarize needs CODE_SIGN_IDENTITY='Developer ID Application: ...'" >&2
  echo "          Set it in .env.local or pass CODE_SIGN_IDENTITY=..." >&2
  exit 1
fi

VST3_DIR="$PORT_DIR/build/VST3/$CONFIG"
if [ ! -d "$VST3_DIR" ]; then
  echo "[calfNXT] ERROR: no build tree at $VST3_DIR — run 'make -C port' first" >&2
  exit 1
fi

# Collect bundles (all, or case-insensitive substring match on the bundle name).
shopt -s nocasematch
BUNDLES=()
while IFS= read -r -d '' b; do
  name="$(basename "$b" .vst3)"
  if [ -z "$MATCH" ] || [[ "$name" == *"$MATCH"* ]]; then
    BUNDLES+=("$b")
  fi
done < <(find "$VST3_DIR" -maxdepth 1 -name '*.vst3' -print0 | sort -z)

if [ "${#BUNDLES[@]}" -eq 0 ]; then
  echo "[calfNXT] ERROR: no bundles matching '${MATCH:-<all>}' in $VST3_DIR" >&2
  exit 1
fi

echo "[calfNXT] Releasing ${#BUNDLES[@]} bundle(s) — identity: $CODE_SIGN_IDENTITY$([ "$NOTARIZE" = 1 ] && echo ' [notarize]')"

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

notarize_bundle() {
  local bundle="$1"
  local name
  name="$(basename "$bundle" .vst3)"
  local stage_dir zip
  stage_dir="$(mktemp -d /tmp/calfnxt-notarize.XXXXXX)"
  zip="$stage_dir/${name}.vst3.zip"
  echo "[calfNXT] $name: notarytool submit (profile: $NOTARY_PROFILE) ..."
  ditto -c -k --keepParent "$bundle" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "[calfNXT] $name: staple ..."
  xcrun stapler staple "$bundle"
  xcrun stapler validate "$bundle"
  spctl -a -vv -t install "$bundle" || true
  rm -rf "$stage_dir"
}

publish() {
  local bundle="$1"
  local name dest
  name="$(basename "$bundle")"
  # dist/ drop (repo root, gitignored)
  dest="$ROOT/dist/$name"
  mkdir -p "$ROOT/dist"
  rm -rf "$dest"
  cp -R "$bundle" "$dest"
  xattr -cr "$dest" 2>/dev/null || true
  # refresh the user install
  dest="$HOME/Library/Audio/Plug-Ins/VST3/$name"
  rm -rf "$dest"
  cp -R "$bundle" "$dest"
  xattr -cr "$dest" 2>/dev/null || true
}

FAILED=()
for bundle in "${BUNDLES[@]}"; do
  name="$(basename "$bundle" .vst3)"
  echo "----------------------------------------------------------------------"
  echo "[calfNXT] $name"
  if ! sign_bundle "$bundle"; then
    echo "[calfNXT] ERROR: signing failed for $name" >&2
    FAILED+=("$name")
    continue
  fi
  if [ "$NOTARIZE" = 1 ]; then
    if ! notarize_bundle "$bundle"; then
      echo "[calfNXT] ERROR: notarization failed for $name" >&2
      FAILED+=("$name")
      continue
    fi
  fi
  publish "$bundle"
done

echo "======================================================================"
if [ "${#FAILED[@]}" -ne 0 ]; then
  echo "[calfNXT] FAILED: ${FAILED[*]}" >&2
  exit 1
fi
echo "[calfNXT] Done. dist/ + ~/Library/Audio/Plug-Ins/VST3 updated$([ "$NOTARIZE" = 1 ] && echo ' (notarized + stapled)')."
