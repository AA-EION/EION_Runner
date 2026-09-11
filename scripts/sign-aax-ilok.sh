#!/usr/bin/env bash
#
# sign-aax-ilok.sh — AAX signing on macOS with a physical iLok, as a HOST PROCESS.
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
# ---------------------------------------------------------------------------
# CREDENTIALS NEVER APPEAR IN ARGV.
#
# wraptool reads its account credentials from the environment, and this script
# uses that rather than --account/--password:
#
#   PF_ACCOUNT_ID        <- PACE_ACCOUNT
#   PF_ACCOUNT_PASSWORD  <- PACE_PASSWORD
#
# An argument list is readable from the process table by any user on the
# machine; an environment is not. If you are already signed in to iLok License
# Manager you can omit both — wraptool finds the account itself.
# ---------------------------------------------------------------------------
set -euo pipefail

INPUT=""
OUTPUT=""
WC_GUID=""
CUSTOMER_NUMBER=""
CUSTOMER_NAME=""
PRODUCT_NAME=""
SIGN_ID=""
KEYCHAIN=""
SELF_SIGNED=0
NO_HARDEN=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
sign-aax-ilok.sh — sign an .aaxplugin on macOS using a physical iLok.

Usage:
  sign-aax-ilok.sh --input <bundle.aaxplugin> --signid <identity> \
                   (--wcguid <guid> | --customernumber <n> --customername <s>) \
                   [--output <path>] [--keychain <path>] [--productname <s>] \
                   [--self-signed] [--no-harden] [--dry-run] [--help]

  --input            The UNSIGNED .aaxplugin bundle from the build job.
  --signid           macOS signing identity NAME, e.g. the Developer ID
                     Application common name, or the name of a self-signed
                     certificate made by scripts/make-signing-cert.sh.
  --wcguid           Wrap Config GUID. The normal way to identify the publisher.
  --customernumber   PACE customer number. Alternative to --wcguid; requires
  --customername     the publisher company name alongside it.
  --output           Where to write the signed bundle. Default: sign in place.
  --keychain         Restrict the identity lookup to one keychain.
  --productname      Product name embedded in the signature metadata.
                     Defaults to the bundle filename.
  --self-signed      The identity is a self-signed certificate. Skips the
                     notarization hardening flags, which cannot help a
                     certificate Apple has never seen, and prints what that
                     means for anyone you give the plugin to.
  --no-harden        Do not pass --dsigharden even with a real Developer ID.
                     Only correct if something later re-signs with hardening.
  --dry-run          Print the exact command, change nothing, validate inputs.

Environment (never passed as arguments):
  PACE_ACCOUNT, PACE_PASSWORD   Optional if iLok License Manager is signed in.
  WRAPTOOL                      Explicit path to wraptool, overriding discovery.

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
    --self-signed)    SELF_SIGNED=1; shift ;;
    --no-harden)      NO_HARDEN=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '[sign-aax-ilok] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Find wraptool.
#
# The SDK installs it at a versioned path that is NOT on PATH by default, so
# requiring PATH would make the common case fail for no reason.
# ---------------------------------------------------------------------------
find_wraptool() {
  if [[ -n "${WRAPTOOL:-}" ]]; then
    [[ -x "$WRAPTOOL" ]] && { printf '%s' "$WRAPTOOL"; return 0; }
    echo "error: WRAPTOOL is set to '$WRAPTOOL', which is not executable." >&2
    return 1
  fi
  if command -v wraptool >/dev/null 2>&1; then
    command -v wraptool; return 0
  fi
  # Newest SDK major version first.
  local candidate
  for candidate in $(ls -d /Applications/PACEAntiPiracy/Eden/Fusion/Versions/*/bin/wraptool 2>/dev/null | sort -rV); do
    [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

[[ -n "$INPUT"   ]] || { echo "error: --input is required" >&2; usage >&2; exit 2; }
[[ -n "$SIGN_ID" ]] || { echo "error: --signid is required on macOS" >&2; usage >&2; exit 2; }

# wraptool needs a publisher identity from exactly one of these two sources.
if [[ -z "$WC_GUID" && -z "$CUSTOMER_NUMBER" ]]; then
  echo "error: the publisher must be identified by --wcguid or by" >&2
  echo "       --customernumber together with --customername." >&2
  exit 2
fi
if [[ -n "$CUSTOMER_NUMBER" && -z "$CUSTOMER_NAME" ]]; then
  echo "error: --customernumber requires --customername; wraptool rejects it alone." >&2
  exit 2
fi

# The platform check gates SIGNING, not argument assembly: --dry-run has to be
# runnable anywhere so the command this script builds can be gate-tested in CI
# without a Mac in the loop.
if [[ "$(uname -s)" != "Darwin" ]]; then
  if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "error: this is the macOS signer. A macOS plugin must be signed on macOS," >&2
    echo "       and a Windows plugin on Windows — the platform signature is not" >&2
    echo "       something one machine can produce for the other." >&2
    exit 3
  fi
  log "NOTE: not running on macOS. --dry-run still assembles and prints the command."
fi

WRAPTOOL_BIN=""
if [[ "$DRY_RUN" -eq 0 ]]; then
  WRAPTOOL_BIN="$(find_wraptool)" || {
    echo "error: wraptool was not found." >&2
    echo "       Looked on PATH and under" >&2
    echo "         /Applications/PACEAntiPiracy/Eden/Fusion/Versions/*/bin/wraptool" >&2
    echo "       Install the PACE Fusion SDK on this host, or set WRAPTOOL to its path." >&2
    echo "       This runner signs and does nothing else; it has no compiler by design." >&2
    exit 3
  }
  log "wraptool: $WRAPTOOL_BIN"
  "$WRAPTOOL_BIN" --version 2>/dev/null | head -1 || true

  [[ -e "$INPUT" ]] || { echo "error: input does not exist: $INPUT" >&2; exit 2; }

  # The identity has to exist before we spend a minute finding out from wraptool.
  identity_search=(security find-identity -p codesigning)
  [[ -n "$KEYCHAIN" ]] && identity_search+=("$KEYCHAIN")
  if ! "${identity_search[@]}" 2>/dev/null | grep -qF "\"$SIGN_ID\""; then
    echo "error: no code-signing identity named \"$SIGN_ID\" is visible to this user." >&2
    echo "       Available identities:" >&2
    "${identity_search[@]}" 2>/dev/null | sed 's/^/         /' >&2 || true
    echo "" >&2
    echo "       --signid takes the quoted NAME from that list, not the hash." >&2
    echo "       No certificate at all? Create one for testing with:" >&2
    echo "         scripts/make-signing-cert.sh --name \"$SIGN_ID\"" >&2
    exit 3
  fi
  log "signing identity \"$SIGN_ID\" found"
fi

# ---------------------------------------------------------------------------
# Build the argument list. Credentials are NOT in it.
# ---------------------------------------------------------------------------
TARGET="${OUTPUT:-$INPUT}"

args=(sign --verbose --in "$INPUT" --signid "$SIGN_ID")
[[ "$TARGET" != "$INPUT" ]] && args+=(--out "$TARGET")
[[ -n "$WC_GUID"         ]] && args+=(--wcguid "$WC_GUID")
[[ -n "$CUSTOMER_NUMBER" ]] && args+=(--customernumber "$CUSTOMER_NUMBER")
[[ -n "$CUSTOMER_NAME"   ]] && args+=(--customername "$CUSTOMER_NAME")
[[ -n "$PRODUCT_NAME"    ]] && args+=(--productname "$PRODUCT_NAME")
[[ -n "$KEYCHAIN"        ]] && args+=(--keychain "$KEYCHAIN")

if [[ "$SELF_SIGNED" -eq 1 ]]; then
  # --dsigharden exists to satisfy notarization. A self-signed certificate can
  # never be notarized, so adding it would imply a guarantee that is not there.
  log "self-signed mode: skipping the notarization hardening options"
  log "  A self-signed certificate cannot be notarized. Gatekeeper will block this"
  log "  bundle on any Mac but the ones that explicitly trust the certificate."
  log "  The PACE signature is unaffected — Pro Tools checks that, not Apple's."
elif [[ "$NO_HARDEN" -eq 0 ]]; then
  # Runtime hardening plus a secure timestamp: both are required before Apple
  # will notarize, and adding them at signing time is the supported way.
  args+=(--dsigharden)
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '[dry-run] PF_ACCOUNT_ID=<PACE_ACCOUNT> PF_ACCOUNT_PASSWORD=<redacted> \\\n'
  printf '[dry-run]   wraptool'
  printf ' %q' "${args[@]}"
  printf '\n'
  log "dry run: inputs validated, nothing signed, no credentials on any command line"
  exit 0
fi

log "signing $INPUT -> $TARGET with the local iLok"

set +e
PF_ACCOUNT_ID="${PACE_ACCOUNT:-}" \
PF_ACCOUNT_PASSWORD="${PACE_PASSWORD:-}" \
  "$WRAPTOOL_BIN" "${args[@]}" 2>&1 | tee /tmp/wraptool-sign.$$.log
status="${PIPESTATUS[0]}"
set -e
output="$(cat /tmp/wraptool-sign.$$.log)"
rm -f "/tmp/wraptool-sign.$$.log"

if [[ "$status" -ne 0 ]]; then
  echo "" >&2
  echo "error: wraptool sign failed. The message above is PACE's, verbatim." >&2

  # PACE's failures are precise but the remedy is not in the message. Map the
  # ones a signing host actually hits to the exact next action.
  case "$output" in
    *CouldNotFindSignerCredentials*)
      echo "  -> No connected iLok holds a code-signing certificate for this publisher." >&2
      echo "     In iLok License Manager, right-click the iLok and choose Synchronize." >&2
      echo "     The icon gains a 'seal' once the certificate is installed." >&2 ;;
    *SigningCertExpired*)
      echo "  -> The iLok's code-signing certificate has expired. Connect ONLY the" >&2
      echo "     signing iLok and Synchronize it in iLok License Manager to renew." >&2 ;;
    *SigningCertWrongPublisherId*)
      echo "  -> The iLok's certificate does not match the publisher you asked for." >&2
      echo "     This happens when the account covers several publishers. Connect" >&2
      echo "     ONLY the signing iLok, Synchronize, and check --wcguid." >&2 ;;
    *MissingFusionToolsLicense*)
      echo "  -> The PACE Tools license authorizing wraptool is not reachable." >&2
      echo "     Connect the iLok holding it, or activate it to this machine." >&2 ;;
    *InvalidPassword*|*"must specify a password"*)
      echo "  -> PACE_ACCOUNT / PACE_PASSWORD were rejected or incomplete." >&2
      echo "     They come from the OS keystore; re-enter them on the Credentials page." >&2 ;;
  esac
  exit 4
fi

log "verifying the signature"
if ! "$WRAPTOOL_BIN" verify --verbose --in "$TARGET"; then
  echo "error: the signed bundle failed wraptool verify." >&2
  echo "       A bundle that signs but does not verify is the shape of a copy that" >&2
  echo "       lost its symlinks. Copy bundles with 'ditto' or 'cp -R -H'." >&2
  exit 4
fi

# codesign is a second, independent opinion, and it is the one Gatekeeper uses.
log "checking the Apple signature"
codesign --verify --verbose=4 "$TARGET" || {
  echo "warning: codesign --verify was not satisfied." >&2
  if [[ "$SELF_SIGNED" -eq 1 ]]; then
    echo "         Expected with a self-signed certificate on a machine that does" >&2
    echo "         not trust it. The PACE signature above is what Pro Tools reads." >&2
  else
    exit 4
  fi
}

log 'done'
