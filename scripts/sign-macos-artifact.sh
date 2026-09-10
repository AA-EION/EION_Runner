#!/usr/bin/env bash
#
# sign-macos-artifact.sh — Developer ID sign, notarize and staple.
#
# Four steps, in this order, none optional:
#
#   1. EPHEMERAL KEYCHAIN. The p12 is imported into runnerforge-ci-$$, a keychain
#      created for this job and deleted in a trap. The login keychain is never
#      touched, so a parallel job cannot see this job's key and a crashed job
#      cannot leave one unlocked.
#
#   2. SIGN INSIDE-OUT. codesign --options runtime --timestamp, innermost bundle
#      first, outermost last.
#
#      NEVER --deep. It is deprecated, and it mis-signs nested bundles: it
#      applies the OUTER bundle's entitlements to inner code, which is wrong for
#      a plugin containing helper binaries. Signing inside-out is more typing and
#      actually correct.
#
#   3. productsign the .pkg with the Developer ID INSTALLER identity, which is a
#      different certificate from the Application one.
#
#   4. NOTARIZE AND STAPLE. xcrun notarytool submit --wait, then stapler staple.
#      Stapling is not optional: notarization records the result on Apple's
#      servers, stapling writes the ticket into the artifact. Without it a user
#      installing offline — or behind a firewall that blocks Apple's OCSP
#      responder — gets a Gatekeeper rejection for a plugin that IS notarized.
#
# Credentials arrive in the ENVIRONMENT, never as arguments:
#   APPLE_DEV_ID_P12            base64 of the .p12
#   APPLE_DEV_ID_P12_PASSWORD   its password
#   APPLE_ASC_ISSUER_ID         App Store Connect issuer id
#   APPLE_ASC_KEY_ID            App Store Connect key id
#   APPLE_ASC_PRIVATE_KEY       the .p8 contents
#
set -euo pipefail

ARTIFACT_DIR=""
PKG_PATH=""
DMG_PATH=""
APP_IDENTITY=""
INSTALLER_IDENTITY=""
TEAM_ID=""
NOTARIZE=1
DRY_RUN=0

usage() {
  cat <<'USAGE'
sign-macos-artifact.sh — Developer ID sign, notarize and staple a macOS plugin.

Usage:
  sign-macos-artifact.sh --artifact-dir <dir> --app-identity <name>
                         [--pkg <path>] [--dmg <path>]
                         [--installer-identity <name>] [--team-id <id>]
                         [--no-notarize] [--dry-run] [--help]

  --artifact-dir        Directory holding the .vst3 / .component / .clap / .app bundles.
  --app-identity        "Developer ID Application: Example Ltd (ABCDE12345)".
  --installer-identity  "Developer ID Installer: Example Ltd (ABCDE12345)". Required with --pkg.
  --team-id             Apple Developer Team ID, required for notarization.
  --no-notarize         Sign only. The artifact will fail Gatekeeper on other machines.
  --dry-run             Print every command that would run, change nothing, and
                        still validate that all required credentials are present.

Required environment (never passed as arguments):
  APPLE_DEV_ID_P12, APPLE_DEV_ID_P12_PASSWORD
  APPLE_ASC_ISSUER_ID, APPLE_ASC_KEY_ID, APPLE_ASC_PRIVATE_KEY   (notarization only)

Exit codes: 0 ok, 2 usage, 3 missing credential, 4 signing failure, 5 notarization failure.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact-dir)        ARTIFACT_DIR="${2:-}"; shift 2 ;;
    --pkg)                 PKG_PATH="${2:-}"; shift 2 ;;
    --dmg)                 DMG_PATH="${2:-}"; shift 2 ;;
    --app-identity)        APP_IDENTITY="${2:-}"; shift 2 ;;
    --installer-identity)  INSTALLER_IDENTITY="${2:-}"; shift 2 ;;
    --team-id)             TEAM_ID="${2:-}"; shift 2 ;;
    --no-notarize)         NOTARIZE=0; shift ;;
    --dry-run)             DRY_RUN=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '[sign-macos] %s\n' "$*"; }
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

[[ -n "$ARTIFACT_DIR" ]] || { echo "error: --artifact-dir is required" >&2; usage >&2; exit 2; }
[[ -n "$APP_IDENTITY" ]] || { echo "error: --app-identity is required" >&2; usage >&2; exit 2; }

if [[ "$DRY_RUN" -eq 0 && ! -d "$ARTIFACT_DIR" ]]; then
  echo "error: artifact dir does not exist: $ARTIFACT_DIR" >&2
  exit 2
fi

if [[ -n "$PKG_PATH" && -z "$INSTALLER_IDENTITY" ]]; then
  echo "error: --installer-identity is required when --pkg is given. The Installer certificate is a DIFFERENT certificate from the Application one." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Credential check. Done BEFORE any work so a missing secret fails in a second
# rather than after a twenty-minute build.
# ---------------------------------------------------------------------------
missing=()
[[ -n "${APPLE_DEV_ID_P12:-}" ]]          || missing+=("APPLE_DEV_ID_P12")
[[ -n "${APPLE_DEV_ID_P12_PASSWORD:-}" ]] || missing+=("APPLE_DEV_ID_P12_PASSWORD")

if [[ "$NOTARIZE" -eq 1 ]]; then
  [[ -n "${APPLE_ASC_ISSUER_ID:-}" ]]   || missing+=("APPLE_ASC_ISSUER_ID")
  [[ -n "${APPLE_ASC_KEY_ID:-}" ]]      || missing+=("APPLE_ASC_KEY_ID")
  [[ -n "${APPLE_ASC_PRIVATE_KEY:-}" ]] || missing+=("APPLE_ASC_PRIVATE_KEY")
  [[ -n "$TEAM_ID" ]]                   || missing+=("--team-id")
fi

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "error: cannot sign — the following required credentials are absent:" >&2
  for item in "${missing[@]}"; do echo "  - $item" >&2; done
  echo "" >&2
  echo "They live in the macOS Keychain under service com.runnerforge.secrets and are" >&2
  echo "injected as environment variables at job time. Never put them in forge.json." >&2
  echo "Use --no-notarize to sign without notarizing (the artifact will then fail" >&2
  echo "Gatekeeper on any machine but this one)." >&2
  exit 3
fi

log "all required credentials are present"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry run: credentials validated, no changes will be made"
fi

# ---------------------------------------------------------------------------
# The ephemeral keychain, and the trap that guarantees its removal.
# ---------------------------------------------------------------------------
KEYCHAIN="runnerforge-ci-$$"
KEYCHAIN_PATH="${HOME}/Library/Keychains/${KEYCHAIN}.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sign-macos.XXXXXX")"

cleanup() {
  local status=$?
  set +e
  # Shred the p8 and p12 before unlinking: an unlinked file on a running system
  # can still be recovered until the blocks are reused.
  if [[ -d "$WORK" ]]; then
    find "$WORK" -type f -exec sh -c 'dd if=/dev/urandom of="$1" bs=1k count=8 conv=notrunc 2>/dev/null' _ {} \;
    rm -rf "$WORK"
  fi
  if [[ "$DRY_RUN" -eq 0 ]] && security list-keychains 2>/dev/null | grep -q "$KEYCHAIN"; then
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1
  fi
  [[ -f "$KEYCHAIN_PATH" ]] && rm -f "$KEYCHAIN_PATH"
  exit $status
}
trap cleanup EXIT INT TERM

if [[ "$DRY_RUN" -eq 0 ]]; then
  log "creating ephemeral keychain $KEYCHAIN"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

  printf '%s' "$APPLE_DEV_ID_P12" | base64 --decode > "$WORK/devid.p12"
  security import "$WORK/devid.p12" -k "$KEYCHAIN_PATH" \
    -P "$APPLE_DEV_ID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/productsign

  # Without this, codesign blocks on a UI prompt that no CI machine can answer.
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

  # Prepend rather than replace, so system roots stay reachable.
  security list-keychains -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | tr -d '"')
else
  log "[dry-run] would create ephemeral keychain $KEYCHAIN and import the p12"
fi

# ---------------------------------------------------------------------------
# Sign inside-out.
#
# Deepest paths first. `sort -r` on path depth is not enough on its own, so the
# depth is computed explicitly and sorted numerically descending.
# ---------------------------------------------------------------------------
log "signing bundles inside-out (never --deep)"

sign_one() {
  local target="$1"
  log "  codesign $target"
  run codesign --force --options runtime --timestamp \
      --sign "$APP_IDENTITY" "$target" \
    || { echo "error: codesign failed for $target" >&2; exit 4; }
}

if [[ -d "$ARTIFACT_DIR" ]]; then
  # 1. Nested Mach-O binaries and frameworks, deepest first.
  while IFS= read -r target; do
    [[ -n "$target" ]] && sign_one "$target"
  done < <(
    find "$ARTIFACT_DIR" \( -name '*.dylib' -o -name '*.framework' -o -path '*/Contents/MacOS/*' \) \
         -type f -o -name '*.framework' -type d 2>/dev/null |
    awk '{ n = gsub("/","/"); print n "\t" $0 }' | sort -rn | cut -f2-
  )

  # 2. The plugin bundles themselves, outermost last.
  while IFS= read -r bundle; do
    [[ -n "$bundle" ]] && sign_one "$bundle"
  done < <(
    find "$ARTIFACT_DIR" -maxdepth 3 \( -name '*.vst3' -o -name '*.component' -o -name '*.clap' -o -name '*.app' \) \
         -type d 2>/dev/null |
    awk '{ n = gsub("/","/"); print n "\t" $0 }' | sort -rn | cut -f2-
  )
fi

# ---------------------------------------------------------------------------
# productsign the installer package.
# ---------------------------------------------------------------------------
if [[ -n "$PKG_PATH" ]]; then
  log "productsign $PKG_PATH"
  SIGNED_PKG="${PKG_PATH%.pkg}-signed.pkg"
  run productsign --sign "$INSTALLER_IDENTITY" "$PKG_PATH" "$SIGNED_PKG" \
    || { echo "error: productsign failed" >&2; exit 4; }
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mv -f "$SIGNED_PKG" "$PKG_PATH"
    log "  signed in place: $PKG_PATH"
  fi
fi

# ---------------------------------------------------------------------------
# Notarize and staple.
# ---------------------------------------------------------------------------
if [[ "$NOTARIZE" -eq 1 ]]; then
  ASC_KEY="$WORK/asc.p8"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '%s' "$APPLE_ASC_PRIVATE_KEY" > "$ASC_KEY"
    chmod 600 "$ASC_KEY"
  fi

  notarize_and_staple() {
    local target="$1"
    [[ -n "$target" ]] || return 0
    if [[ "$DRY_RUN" -eq 0 && ! -e "$target" ]]; then return 0; fi

    log "notarizing $target"
    run xcrun notarytool submit "$target" \
        --key "$ASC_KEY" \
        --key-id "$APPLE_ASC_KEY_ID" \
        --issuer "$APPLE_ASC_ISSUER_ID" \
        --team-id "$TEAM_ID" \
        --wait \
      || { echo "error: notarization failed for $target. Run 'xcrun notarytool log <submission-id>' for Apple's reasons." >&2; exit 5; }

    # STAPLING IS NOT OPTIONAL. Without it the artifact fails offline validation.
    log "stapling $target"
    run xcrun stapler staple "$target" \
      || { echo "error: stapling failed for $target. The artifact is notarized but will be rejected by Gatekeeper offline." >&2; exit 5; }

    log "validating the staple on $target"
    run xcrun stapler validate "$target" \
      || { echo "error: stapler validate failed for $target" >&2; exit 5; }
  }

  notarize_and_staple "$PKG_PATH"
  notarize_and_staple "$DMG_PATH"
else
  log "notarization skipped (--no-notarize). The artifact will fail Gatekeeper on any machine but this one."
fi

log 'done'
