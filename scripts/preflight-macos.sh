#!/usr/bin/env bash
#
# preflight-macos.sh — macOS host preflight for Runner Forge.
#
# Says exactly what is missing on this machine, and which of it can be fixed
# automatically. The GUI renders these results as rows with a status pill and a
# Fix button; this script is the engine behind that page and is equally usable
# from a terminal.
#
# Emits a JSON array with --json so the GUI consumes structured results rather
# than parsing console text.
#
# Each check reports Pass, Warn or Fail. Intel Macs are a hard Fail: Tart uses
# Apple's Virtualization framework on Apple Silicon, and there is no fallback.
#
set -uo pipefail

MAX_DISK_GB=120
MACOS_MINIMUM="26.0"
TART_MINIMUM="2.27.0"
SIGNING_MODE="windows-ilok"
APPLY_FIX=0
AS_JSON=0

usage() {
  cat >&2 <<'USAGE'
Usage: preflight-macos.sh [--max-disk-gb <n>] [--macos-minimum <x.y>]
                          [--tart-minimum <x.y.z>] [--signing-mode <mode>]
                          [--fix] [--json]

  --fix    Apply the automatic fixes for checks that have one.
  --json   Emit a JSON array instead of a table.

Exit codes: 0 no failures, 1 at least one Fail.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-disk-gb)    MAX_DISK_GB="${2:-120}"; shift 2 ;;
    --macos-minimum)  MACOS_MINIMUM="${2:-26.0}"; shift 2 ;;
    --tart-minimum)   TART_MINIMUM="${2:-2.27.0}"; shift 2 ;;
    --signing-mode)   SIGNING_MODE="${2:-windows-ilok}"; shift 2 ;;
    --fix)            APPLY_FIX=1; shift ;;
    --json)           AS_JSON=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

RESULT_NAMES=(); RESULT_STATUS=(); RESULT_DETAIL=(); RESULT_FIX=(); RESULT_AUTO=(); RESULT_BLOCKS=()

add_result() {
  RESULT_NAMES+=("$1"); RESULT_STATUS+=("$2"); RESULT_DETAIL+=("$3")
  RESULT_FIX+=("${4:-}"); RESULT_AUTO+=("${5:-false}"); RESULT_BLOCKS+=("${6:-}")
}

# Compares dotted versions without sort -V, which is absent on stock macOS.
version_ge() {
  local a="$1" b="$2"
  local IFS=.
  # shellcheck disable=SC2206
  local va=($a) vb=($b)
  for i in 0 1 2; do
    local x="${va[i]:-0}" y="${vb[i]:-0}"
    x="${x//[^0-9]/}"; y="${y//[^0-9]/}"
    x="${x:-0}"; y="${y:-0}"
    if (( 10#$x > 10#$y )); then return 0; fi
    if (( 10#$x < 10#$y )); then return 1; fi
  done
  return 0
}

# --- 0. is this even a Mac? -------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  add_result "Host operating system" "Fail" \
    "This preflight targets macOS; it is running on $(uname -s) $(uname -r)." \
    "" "false" "mac-build,mac-ilok"
  if [[ "$AS_JSON" -eq 1 ]]; then
    printf '[{"name":"%s","status":"Fail","detail":"%s","fixHint":"","autoFixable":false,"blocksClasses":"mac-build,mac-ilok"}]\n' \
      "Host operating system" "This preflight targets macOS; it is running on $(uname -s) $(uname -r)."
  else
    printf 'Fail  %-32s %s\n' "Host operating system" "not macOS ($(uname -s))"
  fi
  exit 1
fi

# --- 1. Apple Silicon --------------------------------------------------------
ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  add_result "Apple Silicon" "Pass" "arm64"
else
  add_result "Apple Silicon" "Fail" \
    "This Mac reports $ARCH. Tart uses Apple's Virtualization framework, which requires Apple Silicon. There is no supported fallback." \
    "Use an Apple Silicon Mac for the mac-build class." "false" "mac-build,mac-ilok"
fi

# --- 2. macOS version --------------------------------------------------------
MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo 0)"
if version_ge "$MACOS_VERSION" "$MACOS_MINIMUM"; then
  add_result "macOS version" "Pass" "$MACOS_VERSION (minimum $MACOS_MINIMUM)"
else
  add_result "macOS version" "Fail" \
    "$MACOS_VERSION is below the minimum $MACOS_MINIMUM." \
    "Update macOS." "false" "mac-build"
fi

# --- 3. Tart -----------------------------------------------------------------
if command -v tart >/dev/null 2>&1; then
  TART_VERSION="$(tart --version 2>/dev/null | tr -cd '0-9.' )"
  if version_ge "${TART_VERSION:-0}" "$TART_MINIMUM"; then
    add_result "Tart installed" "Pass" "${TART_VERSION} (minimum $TART_MINIMUM)"
  else
    add_result "Tart installed" "Warn" \
      "tart ${TART_VERSION:-unknown} is below the pinned minimum $TART_MINIMUM." \
      "brew upgrade cirruslabs/cli/tart" "true" "mac-build"
  fi
else
  if [[ "$APPLY_FIX" -eq 1 ]] && command -v brew >/dev/null 2>&1; then
    echo "[preflight] installing tart"
    brew install cirruslabs/cli/tart && add_result "Tart installed" "Pass" "installed" "" "true" \
      || add_result "Tart installed" "Fail" "brew install failed" "brew install cirruslabs/cli/tart" "true" "mac-build"
  else
    add_result "Tart installed" "Fail" "tart is not on PATH." \
      "brew install cirruslabs/cli/tart" "true" "mac-build"
  fi
fi

# --- 4. Xcode ----------------------------------------------------------------
if XCODE_PATH="$(xcode-select -p 2>/dev/null)" && [[ -d "$XCODE_PATH" ]]; then
  if xcodebuild -version >/dev/null 2>&1; then
    add_result "Xcode" "Pass" "$(xcodebuild -version 2>/dev/null | head -1) at $XCODE_PATH"
  else
    add_result "Xcode" "Fail" \
      "xcode-select points at $XCODE_PATH but xcodebuild fails — the licence is probably unaccepted." \
      "sudo xcodebuild -license accept" "false" "mac-build"
  fi
else
  add_result "Xcode" "Fail" "xcode-select does not point at a valid developer directory." \
    "Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app" "false" "mac-build"
fi

# --- 5. Rosetta 2 ------------------------------------------------------------
if [[ "$ARCH" == "arm64" ]]; then
  if /usr/bin/pgrep -q oahd 2>/dev/null || [[ -d /Library/Apple/usr/share/rosetta ]]; then
    add_result "Rosetta 2" "Pass" "installed"
  else
    if [[ "$APPLY_FIX" -eq 1 ]]; then
      echo "[preflight] installing Rosetta 2"
      softwareupdate --install-rosetta --agree-to-license >/dev/null 2>&1 \
        && add_result "Rosetta 2" "Pass" "installed" "" "true" \
        || add_result "Rosetta 2" "Warn" "installation failed" "softwareupdate --install-rosetta --agree-to-license" "true"
    else
      add_result "Rosetta 2" "Warn" \
        "not installed. Needed for x86_64 slices of universal2 builds and some Intel-only tooling." \
        "softwareupdate --install-rosetta --agree-to-license" "true" "mac-build"
    fi
  fi
fi

# --- 6. Free disk ------------------------------------------------------------
FREE_GB="$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ -n "$FREE_GB" ]] && (( FREE_GB >= MAX_DISK_GB )); then
  add_result "Free disk space" "Pass" "${FREE_GB} GB free (minimum ${MAX_DISK_GB} GB)"
else
  add_result "Free disk space" "Fail" \
    "${FREE_GB:-unknown} GB free, below the configured minimum of ${MAX_DISK_GB} GB. A macOS Tart image alone is tens of GB." \
    "Free space, or lower limits.maxDiskGb in forge.json." "false" "mac-build"
fi

# --- 7. Sleep ----------------------------------------------------------------
# The app holds its own caffeinate assertion while runners are active; this
# reports whether that assertion is currently held.
if pgrep -f 'caffeinate.*RunnerForge' >/dev/null 2>&1 || pgrep -x caffeinate >/dev/null 2>&1; then
  add_result "Sleep prevented while runners are active" "Pass" "a caffeinate assertion is held"
else
  add_result "Sleep prevented while runners are active" "Warn" \
    "no caffeinate assertion is currently held. Runner Forge takes one automatically while runners are running; a sleeping Mac drops in-flight jobs." \
    "Runner Forge holds this itself; no action needed unless runners are active and this still says no." "false"
fi

# --- 8. Outbound HTTPS -------------------------------------------------------
for endpoint in github.com api.github.com ghcr.io; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$endpoint" 2>/dev/null)"
  if [[ -n "$code" && "$code" != "000" ]]; then
    add_result "Outbound HTTPS: $endpoint" "Pass" "HTTP $code (reachable)"
  else
    add_result "Outbound HTTPS: $endpoint" "Fail" "unreachable" \
      "Check your firewall, proxy, or corporate TLS inspection settings." "false" "mac-build,mac-ilok"
  fi
done

# --- 9. Base Tart image (informational) -------------------------------------
if command -v tart >/dev/null 2>&1; then
  if tart list --quiet 2>/dev/null | grep -q 'runnerforge-macos'; then
    add_result "Base Tart image" "Pass" "$(tart list --quiet 2>/dev/null | grep 'runnerforge-macos' | head -1)"
  else
    add_result "Base Tart image" "Warn" \
      "not built yet. Informational: the first build takes a long time but only happens once." \
      "packer build images/macos/packer/runnerforge-macos.pkr.hcl" "true"
  fi
fi

# --- 10. Developer ID identities --------------------------------------------
if command -v security >/dev/null 2>&1; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
  for kind in "Developer ID Application" "Developer ID Installer"; do
    if printf '%s' "$IDENTITIES" | grep -q "$kind"; then
      add_result "$kind identity" "Pass" "present in the keychain"
    else
      add_result "$kind identity" "Warn" \
        "no '$kind' identity found. Only signing is affected; unsigned builds still produce artifacts." \
        "Import the certificate from your Apple Developer account." "false"
    fi
  done
fi

# --- 11. notarytool ----------------------------------------------------------
if xcrun --find notarytool >/dev/null 2>&1; then
  add_result "xcrun notarytool" "Pass" "$(xcrun --find notarytool)"
else
  add_result "xcrun notarytool" "Warn" \
    "notarytool is not available. Notarization will be skipped; stapling then cannot happen either, and the artifact fails Gatekeeper offline." \
    "Install a current Xcode." "false"
fi

# --- 12. iLok, only in macos-ilok mode --------------------------------------
if [[ "$SIGNING_MODE" == "macos-ilok" ]]; then
  if [[ -d /Library/Application\ Support/PACE ]] || pkgutil --pkgs 2>/dev/null | grep -qi pace; then
    add_result "iLok driver" "Pass" "PACE support files present"
  else
    add_result "iLok driver" "Fail" "The PACE/iLok driver is not installed." \
      "Install iLok License Manager." "false" "mac-ilok"
  fi

  if system_profiler SPUSBDataType 2>/dev/null | grep -qi 'ilok'; then
    add_result "iLok dongle detected" "Pass" "an iLok USB device is attached"
  else
    add_result "iLok dongle detected" "Fail" "No iLok USB device found." \
      "Plug the dongle into this Mac, or switch signing.mode to 'cloud'." "false" "mac-ilok"
  fi

  if command -v wraptool >/dev/null 2>&1; then
    add_result "wraptool on PATH" "Pass" "$(command -v wraptool)"
  else
    add_result "wraptool on PATH" "Fail" "wraptool is not on PATH." \
      "Install PACE Eden tools and add its bin directory to PATH." "false" "mac-ilok"
  fi
else
  add_result "iLok checks" "Pass" "skipped: signing.mode is '$SIGNING_MODE', which needs no dongle on this host"
fi

# --- output ------------------------------------------------------------------
json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null \
                || printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

fail_count=0
for status in "${RESULT_STATUS[@]}"; do [[ "$status" == "Fail" ]] && fail_count=$(( fail_count + 1 )); done

if [[ "$AS_JSON" -eq 1 ]]; then
  printf '[\n'
  for i in "${!RESULT_NAMES[@]}"; do
    [[ $i -gt 0 ]] && printf ',\n'
    printf '  {"name": "%s", "status": "%s", "detail": "%s", "fixHint": "%s", "autoFixable": %s, "blocksClasses": "%s"}' \
      "$(json_escape "${RESULT_NAMES[$i]}")" "${RESULT_STATUS[$i]}" \
      "$(json_escape "${RESULT_DETAIL[$i]}")" "$(json_escape "${RESULT_FIX[$i]}")" \
      "${RESULT_AUTO[$i]}" "${RESULT_BLOCKS[$i]}"
  done
  printf '\n]\n'
else
  for i in "${!RESULT_NAMES[@]}"; do
    printf '%-5s %-42s %s\n' "${RESULT_STATUS[$i]}" "${RESULT_NAMES[$i]}" "${RESULT_DETAIL[$i]}"
  done
  echo
  pass=0; warn=0
  for status in "${RESULT_STATUS[@]}"; do
    [[ "$status" == "Pass" ]] && pass=$(( pass + 1 ))
    [[ "$status" == "Warn" ]] && warn=$(( warn + 1 ))
  done
  echo "Pass $pass   Warn $warn   Fail $fail_count"
fi

# A single Fail is enough to block: the affected classes cannot run.
[[ "$fail_count" -gt 0 ]] && exit 1
exit 0
