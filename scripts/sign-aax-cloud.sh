#!/usr/bin/env bash
#
# sign-aax-cloud.sh — AAX signing on macOS WITHOUT a physical iLok.
#
# ---------------------------------------------------------------------------
# WHAT THIS ACTUALLY DOES, because two different PACE products share the word
# "cloud" and confusing them wastes a day:
#
#   iLok Cloud    — PACE's internet licensing system. An open Cloud session
#                   makes your PACE Tools license available to wraptool on a
#                   machine with no iLok plugged in. Opened with `iloktool`,
#                   which ships with iLok License Manager, NOT with the SDK.
#
#   Cloud Signing — the subscription service that performs the signature when
#                   no signing iLok is present. Enabled per invocation with
#                   wraptool's --allowsigningservice.
#
# You need BOTH for a CI runner with no hardware: the session authorizes the
# tool, the flag authorizes the signature.
#
# An earlier version of this script called `wraptool activate --cloud` and
# `wraptool deactivate`. Neither exists. The session is `iloktool cloud`.
# ---------------------------------------------------------------------------
#
# CREDENTIALS AND ARGV. wraptool reads PF_ACCOUNT_ID / PF_ACCOUNT_PASSWORD from
# the environment, so the signing call carries no secret in its argument list.
#
# `iloktool cloud --open` is the exception: PACE documents only --account and
# --password for it, and there is no documented environment equivalent. That is
# why opening a session is OPT-IN here via --open-session rather than automatic.
# Prefer opening the session once, by hand or from iLok License Manager, and
# leaving it open — it persists until explicitly closed, so CI never needs the
# password at all.
#
set -euo pipefail

INPUT=""
OUTPUT=""
WC_GUID=""
CUSTOMER_NUMBER=""
CUSTOMER_NAME=""
PRODUCT_NAME=""
SIGN_ID=""
KEYCHAIN=""
OPEN_SESSION=0
CLOSE_SESSION=0
SELF_SIGNED=0
NO_HARDEN=0
DRY_RUN=0
SESSION_OPENED=0

usage() {
  cat <<'USAGE'
sign-aax-cloud.sh — sign an .aaxplugin on macOS with no iLok attached.

Usage:
  sign-aax-cloud.sh --input <bundle.aaxplugin> --signid <identity> \
                    (--wcguid <guid> | --customernumber <n> --customername <s>) \
                    [--output <path>] [--open-session] [--close-session] \
                    [--keychain <path>] [--productname <s>] \
                    [--self-signed] [--no-harden] [--dry-run] [--help]

  --open-session   Open an iLok Cloud session with iloktool before signing.
                   Needs PACE_ACCOUNT and PACE_PASSWORD. This is the one step
                   whose documented CLI takes the password as an argument, so
                   it is opt-in. If a session is already open, iloktool reports
                   success and nothing changes.
  --close-session  Close the session afterwards. Off by default: a session is
                   per-account and per-machine, and closing one that another
                   job is using breaks that job.

  Remaining options are identical to sign-aax-ilok.sh; run it with --help.

Environment (never passed as arguments to wraptool):
  PACE_ACCOUNT, PACE_PASSWORD   Required — --allowsigningservice needs both.
  WRAPTOOL, ILOKTOOL            Explicit paths, overriding discovery.

Exit codes: 0 ok, 2 usage, 3 missing prerequisite, 4 signing failure.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)          INPUT="${2:-}"; shift 2 ;;
    --output)         OUTPUT="${2:-}"; shift 2 ;;
    --wcguid)         WC_GUID="${2:-}"; shift 2 ;;
    --customernumber) CUSTOMER_NUMBER="${2:-}"; shift 2 ;;
    --customername)   CUSTOMER_NAME="${2:-}"; shift 2 ;;
    --productname)    PRODUCT_NAME="${2:-}"; shift 2 ;;
    --signid)         SIGN_ID="${2:-}"; shift 2 ;;
    --keychain)       KEYCHAIN="${2:-}"; shift 2 ;;
    --open-session)   OPEN_SESSION=1; shift ;;
    --close-session)  CLOSE_SESSION=1; shift ;;
    --self-signed)    SELF_SIGNED=1; shift ;;
    --no-harden)      NO_HARDEN=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '[sign-aax-cloud] %s\n' "$*"; }

find_wraptool() {
  if [[ -n "${WRAPTOOL:-}" ]]; then
    [[ -x "$WRAPTOOL" ]] && { printf '%s' "$WRAPTOOL"; return 0; }
    return 1
  fi
  command -v wraptool >/dev/null 2>&1 && { command -v wraptool; return 0; }
  local candidate
  for candidate in $(ls -d /Applications/PACEAntiPiracy/Eden/Fusion/Versions/*/bin/wraptool 2>/dev/null | sort -rV); do
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

find_iloktool() {
  if [[ -n "${ILOKTOOL:-}" ]]; then
    [[ -x "$ILOKTOOL" ]] && { printf '%s' "$ILOKTOOL"; return 0; }
    return 1
  fi
  command -v iloktool >/dev/null 2>&1 && { command -v iloktool; return 0; }
  return 1
}

[[ -n "$INPUT"   ]] || { echo "error: --input is required" >&2; usage >&2; exit 2; }
[[ -n "$SIGN_ID" ]] || { echo "error: --signid is required on macOS" >&2; usage >&2; exit 2; }

if [[ -z "$WC_GUID" && -z "$CUSTOMER_NUMBER" ]]; then
  echo "error: the publisher must be identified by --wcguid or by" >&2
  echo "       --customernumber together with --customername." >&2
  exit 2
fi
if [[ -n "$CUSTOMER_NUMBER" && -z "$CUSTOMER_NAME" ]]; then
  echo "error: --customernumber requires --customername; wraptool rejects it alone." >&2
  exit 2
fi

# --allowsigningservice is documented as requiring BOTH the account and the
# password. Fail here, in a second, rather than after a twenty-minute build.
missing=()
[[ -n "${PACE_ACCOUNT:-}"  ]] || missing+=("PACE_ACCOUNT")
[[ -n "${PACE_PASSWORD:-}" ]] || missing+=("PACE_PASSWORD")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "error: cloud signing needs both of these, and they are absent:" >&2
  for item in "${missing[@]}"; do echo "  - $item" >&2; done
  echo "" >&2
  echo "PACE requires an account and password for --allowsigningservice; unlike" >&2
  echo "the iLok path, an ILM login is not enough. They live in the OS keystore" >&2
  echo "(paceAccount / pacePassword) and are injected as environment variables." >&2
  echo "Never put them in forge.json." >&2
  exit 3
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "error: this is the macOS signer. A macOS plugin must be signed on macOS." >&2
    exit 3
  fi
  log "NOTE: not running on macOS. --dry-run still assembles and prints the command."
fi

WRAPTOOL_BIN=""
if [[ "$DRY_RUN" -eq 0 ]]; then
  WRAPTOOL_BIN="$(find_wraptool)" || {
    echo "error: wraptool was not found on PATH or under" >&2
    echo "       /Applications/PACEAntiPiracy/Eden/Fusion/Versions/*/bin/wraptool" >&2
    echo "       Install the PACE Fusion SDK, or set WRAPTOOL to its path." >&2
    exit 3
  }
  log "wraptool: $WRAPTOOL_BIN"
  [[ -e "$INPUT" ]] || { echo "error: input does not exist: $INPUT" >&2; exit 2; }
fi

# ---------------------------------------------------------------------------
# The iLok Cloud session, and the trap that closes it.
#
# Registered BEFORE the session is opened, so a failure during opening cannot
# leak one either.
# ---------------------------------------------------------------------------
ILOKTOOL_BIN=""
close_session() {
  local status=$?
  set +e
  if [[ "$SESSION_OPENED" -eq 1 && "$CLOSE_SESSION" -eq 1 ]]; then
    log "closing the iLok Cloud session"
    "$ILOKTOOL_BIN" cloud --close --account "$PACE_ACCOUNT" >/dev/null 2>&1 \
      && log "session closed" \
      || log "WARNING: could not close the iLok Cloud session. Close it from iLok License Manager."
  fi
  exit $status
}
trap close_session EXIT INT TERM

if [[ "$OPEN_SESSION" -eq 1 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] iloktool cloud --open --account <PACE_ACCOUNT> --password <redacted> -v\n'
  else
    ILOKTOOL_BIN="$(find_iloktool)" || {
      echo "error: iloktool was not found." >&2
      echo "       It installs with iLok License Manager (the License Support installer" >&2
      echo "       from ilok.com), NOT with the Fusion SDK. On macOS it is added to PATH." >&2
      echo "       Alternatively open the Cloud session by hand, from iLok License" >&2
      echo "       Manager: File > Open Your Cloud Session, and drop --open-session." >&2
      exit 3
    }
    log "opening an iLok Cloud session"
    log "NOTE: this is the one call whose documented CLI takes the password as an"
    log "      argument. Open the session once by hand and it persists, so routine"
    log "      runs need neither this flag nor the password."
    if ! "$ILOKTOOL_BIN" cloud --open --account "$PACE_ACCOUNT" --password "$PACE_PASSWORD" -v; then
      echo "error: could not open an iLok Cloud session." >&2
      echo "       Check that this account holds a Cloud-enabled PACE Tools license," >&2
      echo "       and that no physical iLok with PACE Tools activated is connected —" >&2
      echo "       PACE documents that combination as a conflict." >&2
      echo "       A Cloud session also cannot be shared across machines: each build" >&2
      echo "       machine needs its own iLok account." >&2
      exit 3
    fi
    SESSION_OPENED=1
  fi
fi

# ---------------------------------------------------------------------------
# Sign. --allowsigningservice is what makes this work with no signing iLok.
# ---------------------------------------------------------------------------
TARGET="${OUTPUT:-$INPUT}"

args=(sign --verbose --in "$INPUT" --signid "$SIGN_ID" --allowsigningservice)
[[ "$TARGET" != "$INPUT" ]] && args+=(--out "$TARGET")
[[ -n "$WC_GUID"         ]] && args+=(--wcguid "$WC_GUID")
[[ -n "$CUSTOMER_NUMBER" ]] && args+=(--customernumber "$CUSTOMER_NUMBER")
[[ -n "$CUSTOMER_NAME"   ]] && args+=(--customername "$CUSTOMER_NAME")
[[ -n "$PRODUCT_NAME"    ]] && args+=(--productname "$PRODUCT_NAME")
[[ -n "$KEYCHAIN"        ]] && args+=(--keychain "$KEYCHAIN")

if [[ "$SELF_SIGNED" -eq 1 ]]; then
  log "self-signed mode: skipping the notarization hardening options"
  log "  A self-signed certificate cannot be notarized. See docs/SIGNING.md."
elif [[ "$NO_HARDEN" -eq 0 ]]; then
  args+=(--dsigharden)
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '[dry-run] PF_ACCOUNT_ID=<PACE_ACCOUNT> PF_ACCOUNT_PASSWORD=<redacted> \\\n'
  printf '[dry-run]   wraptool'
  printf ' %q' "${args[@]}"
  printf '\n'
  log "dry run: inputs validated, nothing signed, no credentials on any wraptool command line"
  exit 0
fi

log "signing $INPUT -> $TARGET through the PACE signing service"

set +e
PF_ACCOUNT_ID="$PACE_ACCOUNT" \
PF_ACCOUNT_PASSWORD="$PACE_PASSWORD" \
  "$WRAPTOOL_BIN" "${args[@]}" 2>&1 | tee "/tmp/wraptool-cloud.$$.log"
status="${PIPESTATUS[0]}"
set -e
output="$(cat "/tmp/wraptool-cloud.$$.log")"
rm -f "/tmp/wraptool-cloud.$$.log"

if [[ "$status" -ne 0 ]]; then
  echo "" >&2
  echo "error: wraptool sign failed. The message above is PACE's, verbatim." >&2
  case "$output" in
    *CouldNotFindSignerCredentials*)
      echo "  -> With --allowsigningservice this means the service could not authorize" >&2
      echo "     the signature. Check internet access, that PACE_ACCOUNT/PACE_PASSWORD" >&2
      echo "     are right, and that an iLok Cloud session is open for this account." >&2
      echo "     Open one with --open-session, or from iLok License Manager." >&2 ;;
    *MissingFusionToolsLicense*)
      echo "  -> No PACE Tools license is reachable. Cloud signing needs a" >&2
      echo "     Cloud-enabled PACE Tools license and an open iLok Cloud session." >&2 ;;
    *InvalidPassword*)
      echo "  -> PACE_PASSWORD was rejected. Re-enter it on the Credentials page." >&2 ;;
  esac
  echo "     A licensing error here often means the account is not subscribed to the" >&2
  echo "     Cloud Signing service, which --allowsigningservice cannot grant by itself." >&2
  exit 4
fi

log "verifying the signature"
if ! "$WRAPTOOL_BIN" verify --verbose --in "$TARGET"; then
  echo "error: the signed bundle failed wraptool verify." >&2
  echo "       A bundle that signs but does not verify is the shape of a copy that" >&2
  echo "       lost its symlinks. Copy bundles with 'ditto' or 'cp -R -H'." >&2
  exit 4
fi

log 'done'
