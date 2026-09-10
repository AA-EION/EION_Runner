#!/usr/bin/env bash
#
# sign-aax-cloud.sh — AAX signing via PACE Cloud 2 Cloud. No dongle anywhere.
#
# This mode signs INSIDE THE BUILD JOB, because there is no physical device to
# be near. The flow is:
#
#   1. Open an iLok Cloud session on this machine.
#   2. Run `wraptool sign` with --allowsigningservice appended.
#   3. Close the session in a trap, so a failed build can never leak an open
#      session that counts against the account's activation limit.
#
# Confirm with PACE that your entitlement includes the cloud signing service
# before relying on this. --allowsigningservice is the documented flag, but the
# flag is only half the story: the ACCOUNT has to be entitled. If it is not,
# wraptool fails at sign time with a licensing error, which this script surfaces
# verbatim rather than swallowing.
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
SESSION_OPENED=0

usage() {
  cat <<'USAGE'
sign-aax-cloud.sh — sign an .aaxplugin using PACE Cloud 2 Cloud (no dongle).

Usage:
  sign-aax-cloud.sh --input <bundle.aaxplugin> --wcguid <guid> --signid <id>
                    [--output <path>] [--dry-run] [--help]

  --input     The UNSIGNED .aaxplugin bundle.
  --wcguid    PACE wrapping certificate GUID (signing.paceWcGuid).
  --signid    PACE signing identifier (signing.paceSignId).
  --output    Where to write the signed bundle. Defaults to signing in place.
  --dry-run   Print every command that would run, change nothing, and still
              validate that all required credentials are present.

Required environment (never passed as arguments):
  PACE_ACCOUNT, PACE_PASSWORD

Exit codes: 0 ok, 2 usage, 3 missing credential, 4 signing failure.
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

log() { printf '[sign-aax-cloud] %s\n' "$*"; }
run() { if [[ "$DRY_RUN" -eq 1 ]]; then printf '[dry-run] %s\n' "$*"; return 0; fi; "$@"; }

[[ -n "$INPUT"   ]] || { echo "error: --input is required" >&2; usage >&2; exit 2; }
[[ -n "$WC_GUID" ]] || { echo "error: --wcguid is required" >&2; usage >&2; exit 2; }
[[ -n "$SIGN_ID" ]] || { echo "error: --signid is required" >&2; usage >&2; exit 2; }

# ---------------------------------------------------------------------------
# Credential check first, so a missing secret fails in a second rather than
# after a twenty-minute build.
# ---------------------------------------------------------------------------
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
    echo "error: wraptool is not on PATH. Install PACE Eden tools." >&2
    exit 3
  }
  [[ -e "$INPUT" ]] || { echo "error: input does not exist: $INPUT" >&2; exit 2; }
fi

log "credentials present; wraptool $(command -v wraptool >/dev/null 2>&1 && wraptool --version 2>/dev/null | head -1 || echo '(not checked in dry run)')"

# ---------------------------------------------------------------------------
# The session, and the trap that guarantees it is closed.
#
# Registered BEFORE the session is opened so that a failure during activation
# cannot leak one either.
# ---------------------------------------------------------------------------
close_session() {
  local status=$?
  set +e
  if [[ "$SESSION_OPENED" -eq 1 ]]; then
    log "closing the iLok Cloud session"
    wraptool deactivate --account "$PACE_ACCOUNT" --password "$PACE_PASSWORD" >/dev/null 2>&1 \
      && log "session closed" \
      || log "WARNING: could not close the iLok Cloud session; it may count against your activation limit until it expires"
  fi
  exit $status
}
trap close_session EXIT INT TERM

log "opening an iLok Cloud session"
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '[dry-run] wraptool activate --account <PACE_ACCOUNT> --password <redacted> --cloud\n'
else
  if ! wraptool activate --account "$PACE_ACCOUNT" --password "$PACE_PASSWORD" --cloud; then
    echo "error: could not open an iLok Cloud session." >&2
    echo "       Confirm with PACE that this account is entitled to iLok Cloud (Cloud 2 Cloud)." >&2
    exit 4
  fi
  SESSION_OPENED=1
fi

# ---------------------------------------------------------------------------
# Sign. --allowsigningservice is what makes cloud signing work; without it
# wraptool expects a local activation.
# ---------------------------------------------------------------------------
TARGET="${OUTPUT:-$INPUT}"

log "signing $INPUT -> $TARGET"
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '[dry-run] wraptool sign --verbose --account <PACE_ACCOUNT> --password <redacted> --wcguid %s --signid %s --in %s --out %s --allowsigningservice\n' \
    "$WC_GUID" "$SIGN_ID" "$INPUT" "$TARGET"
else
  if ! wraptool sign --verbose \
        --account "$PACE_ACCOUNT" \
        --password "$PACE_PASSWORD" \
        --wcguid "$WC_GUID" \
        --signid "$SIGN_ID" \
        --in "$INPUT" \
        --out "$TARGET" \
        --allowsigningservice; then
    echo "error: wraptool sign failed. The message above is PACE's, reproduced verbatim." >&2
    echo "       A licensing error here usually means the account is not entitled to the" >&2
    echo "       cloud signing service, which --allowsigningservice cannot grant on its own." >&2
    exit 4
  fi

  log "verifying the signature"
  wraptool verify --verbose --in "$TARGET" || {
    echo "error: the signed bundle failed verification" >&2
    exit 4
  }
fi

log 'done'
