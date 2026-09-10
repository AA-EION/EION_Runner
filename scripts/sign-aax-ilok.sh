#!/usr/bin/env bash
#
# sign-aax-ilok.sh — AAX signing with a physical iLok dongle, as a HOST PROCESS.
#
# This runs on the mac-ilok runner, which is deliberately NOT containerized and
# deliberately has NO COMPILER.
#
# Not containerized because a container cannot see a USB device. On Windows that
# is absolute — USB passthrough into a Windows container does not exist. Keeping
# it a host process on macOS too means the two iLok classes behave identically.
#
# No compiler because this machine holds a signing credential. A build job that
# could run here would be a build job that could compromise the signing host, so
# the split is a security boundary rather than a packaging detail.
#
# Credentials arrive in the ENVIRONMENT, never as arguments:
#   PACE_ACCOUNT, PACE_PASSWORD
#
set -euo pipefail

INPUT=""
OUTPUT=""
WC_GUID=""
SIGN_ID=""
DRY_RUN=0

usage() {
  cat <<'USAGE'
sign-aax-ilok.sh — sign an .aaxplugin using a physical iLok dongle on this host.

Usage:
  sign-aax-ilok.sh --input <bundle.aaxplugin> --wcguid <guid> --signid <id>
                   [--output <path>] [--dry-run] [--help]

  --input     The UNSIGNED .aaxplugin bundle, downloaded from the build job.
  --wcguid    PACE wrapping certificate GUID (signing.paceWcGuid).
  --signid    PACE signing identifier (signing.paceSignId).
  --output    Where to write the signed bundle. Defaults to signing in place.
  --dry-run   Print every command that would run, change nothing, and still
              validate that all required credentials and the dongle are present.

Required environment (never passed as arguments):
  PACE_ACCOUNT, PACE_PASSWORD

Exit codes: 0 ok, 2 usage, 3 missing credential or dongle, 4 signing failure.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)   INPUT="${2:-}"; shift 2 ;;
    --output)  OUTPUT="${2:-}"; shift 2 ;;
    --wcguid)  WC_GUID="${2:-}"; shift 2 ;;
    --signid)  SIGN_ID="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '[sign-aax-ilok] %s\n' "$*"; }

[[ -n "$INPUT"   ]] || { echo "error: --input is required" >&2; usage >&2; exit 2; }
[[ -n "$WC_GUID" ]] || { echo "error: --wcguid is required" >&2; usage >&2; exit 2; }
[[ -n "$SIGN_ID" ]] || { echo "error: --signid is required" >&2; usage >&2; exit 2; }

missing=()
[[ -n "${PACE_ACCOUNT:-}"  ]] || missing+=("PACE_ACCOUNT")
[[ -n "${PACE_PASSWORD:-}" ]] || missing+=("PACE_PASSWORD")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "error: cannot sign — the following required credentials are absent:" >&2
  for item in "${missing[@]}"; do echo "  - $item" >&2; done
  echo "" >&2
  echo "They live in the OS keystore (paceAccount / pacePassword) and are injected as" >&2
  echo "environment variables at job time. Never put them in forge.json." >&2
  exit 3
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  command -v wraptool >/dev/null 2>&1 || {
    echo "error: wraptool is not on PATH. Install PACE Eden tools on this host." >&2
    echo "       This runner signs and does nothing else; it has no compiler by design." >&2
    exit 3
  }

  # A dongle that is not plugged in is the single most common failure here, and
  # the resulting wraptool error is unhelpfully generic. Check it up front.
  if ! wraptool list-tokens 2>/dev/null | grep -qi 'ilok'; then
    echo "error: no iLok token is visible to wraptool on this host." >&2
    echo "       Plug the dongle in, or switch signing.mode to 'cloud'." >&2
    echo "       Note that a container can never see a USB device: this runner is a" >&2
    echo "       host process precisely so that the dongle is reachable at all." >&2
    exit 3
  fi

  [[ -e "$INPUT" ]] || { echo "error: input does not exist: $INPUT" >&2; exit 2; }
fi

TARGET="${OUTPUT:-$INPUT}"

log "signing $INPUT -> $TARGET using the local dongle"
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '[dry-run] wraptool sign --verbose --account <PACE_ACCOUNT> --password <redacted> --wcguid %s --signid %s --in %s --out %s\n' \
    "$WC_GUID" "$SIGN_ID" "$INPUT" "$TARGET"
  log "dry run: credentials validated, no changes made"
  exit 0
fi

# No --allowsigningservice here: this is a local activation on a physical token.
if ! wraptool sign --verbose \
      --account "$PACE_ACCOUNT" \
      --password "$PACE_PASSWORD" \
      --wcguid "$WC_GUID" \
      --signid "$SIGN_ID" \
      --in "$INPUT" \
      --out "$TARGET"; then
  echo "error: wraptool sign failed. The message above is PACE's, reproduced verbatim." >&2
  exit 4
fi

log "verifying the signature"
wraptool verify --verbose --in "$TARGET" || {
  echo "error: the signed bundle failed verification" >&2
  exit 4
}

log 'done'
