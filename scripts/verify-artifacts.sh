#!/usr/bin/env bash
#
# verify-artifacts.sh — the artifact contract gate.
#
# A build workflow is not green because its build jobs passed. It is green when
# every artifact the contract promises exists, is non-empty, and contains what it
# is supposed to contain. This script is what decides that, and it is the last
# job in every build workflow.
#
# Usage:
#   verify-artifacts.sh --manifest <manifest.json> --dir <downloaded artifacts dir>
#                       [--untar-dir <scratch dir>] [--quiet]
#
# The manifest describes the expected artifact set:
#
#   {
#     "project": "Canary",
#     "artifacts": [
#       {
#         "name":     "Canary-windows-x64",
#         "required": true,
#         "globs":    ["*.vst3", "*.clap", "*.exe"],
#         "untar":    false,
#         "bundles":  []
#       },
#       {
#         "name":     "Canary-macos-universal",
#         "required": true,
#         "globs":    ["*.vst3", "*.component", "*.clap", "*.app"],
#         "untar":    true,
#         "bundles":  ["*.vst3", "*.component", "*.app"]
#       }
#     ]
#   }
#
#   name     artifact directory name under --dir (upload-artifact v4 creates one
#            directory per artifact when download-artifact runs with
#            merge-multiple: false)
#   required a missing required artifact fails the run; a missing optional one is
#            reported and tolerated (used for the aax-skipped marker)
#   globs    at least one entry must match each pattern, and every match must be
#            non-empty
#   untar    the artifact holds tarred macOS bundles; extract before asserting
#   bundles  patterns that name macOS bundle directories, which must still have
#            Contents/MacOS/ and Contents/Info.plist after the tar round-trip
#
# Exit codes: 0 every required artifact passed, 1 one or more failed,
#             2 usage or environment error.
#
set -uo pipefail

MANIFEST=""
ARTIFACT_DIR=""
UNTAR_DIR=""
QUIET=0

usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)  MANIFEST="${2:-}"; shift 2 ;;
    --dir)       ARTIFACT_DIR="${2:-}"; shift 2 ;;
    --untar-dir) UNTAR_DIR="${2:-}"; shift 2 ;;
    --quiet)     QUIET=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[[ -n "$MANIFEST"     ]] || { echo "error: --manifest is required" >&2; exit 2; }
[[ -n "$ARTIFACT_DIR" ]] || { echo "error: --dir is required" >&2; exit 2; }
[[ -f "$MANIFEST"     ]] || { echo "error: manifest not found: $MANIFEST" >&2; exit 2; }
[[ -d "$ARTIFACT_DIR" ]] || { echo "error: artifact dir not found: $ARTIFACT_DIR" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "error: jq is required but not on PATH" >&2; exit 2; }

if [[ -z "$UNTAR_DIR" ]]; then
  UNTAR_DIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-artifacts.XXXXXX")"
  trap 'rm -rf "$UNTAR_DIR"' EXIT
fi
mkdir -p "$UNTAR_DIR"

log() { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*"; }

# --- helpers ---------------------------------------------------------------

# Total bytes of a file or of everything under a directory.
size_of() {
  local target="$1"
  if [[ -d "$target" ]]; then
    local total=0 f
    while IFS= read -r -d '' f; do
      total=$(( total + $(stat -c%s "$f" 2>/dev/null || stat -f%z "$f") ))
    done < <(find "$target" -type f -print0 2>/dev/null)
    printf '%s' "$total"
  elif [[ -e "$target" ]]; then
    stat -c%s "$target" 2>/dev/null || stat -f%z "$target"
  else
    printf '0'
  fi
}

# Number of regular files at or under a path.
count_files() {
  local target="$1"
  if [[ -d "$target" ]]; then
    find "$target" -type f 2>/dev/null | wc -l | tr -d ' '
  elif [[ -e "$target" ]]; then
    printf '1'
  else
    printf '0'
  fi
}

PROJECT="$(jq -r '.project // "project"' "$MANIFEST")"
ARTIFACT_COUNT="$(jq -r '.artifacts | length' "$MANIFEST")"

log "verify-artifacts: project '$PROJECT', $ARTIFACT_COUNT expected artifacts"
log "verify-artifacts: reading from $ARTIFACT_DIR"
log ""

declare -a ROW_NAME ROW_PRESENT ROW_BYTES ROW_FILES ROW_VERDICT
declare -a FAILURES

overall_rc=0

for index in $(seq 0 $(( ARTIFACT_COUNT - 1 ))); do
  name="$(jq -r ".artifacts[$index].name" "$MANIFEST")"
  # NOTE: `.x // true` is wrong here. jq's alternative operator treats `false`
  # as empty, so an explicit "required": false would come back as true. Test for
  # the key's presence instead.
  required="$(jq -r ".artifacts[$index] | if has(\"required\") then .required else true end" "$MANIFEST")"
  untar="$(jq -r ".artifacts[$index] | if has(\"untar\") then .untar else false end" "$MANIFEST")"

  mapfile -t globs   < <(jq -r ".artifacts[$index].globs   // [] | .[]" "$MANIFEST")
  mapfile -t bundles < <(jq -r ".artifacts[$index].bundles // [] | .[]" "$MANIFEST")

  path="$ARTIFACT_DIR/$name"
  problems=()

  log "── $name"

  # 1. it exists
  if [[ ! -d "$path" ]]; then
    if [[ "$required" == "true" ]]; then
      problems+=("artifact directory is missing entirely")
    else
      log "   optional artifact not present — tolerated"
      ROW_NAME+=("$name"); ROW_PRESENT+=("no"); ROW_BYTES+=("0")
      ROW_FILES+=("0");    ROW_VERDICT+=("skip")
      log ""
      continue
    fi
  fi

  if [[ ${#problems[@]} -eq 0 ]]; then
    # 2. untar any tarred macOS bundles before asserting on them
    search_root="$path"
    if [[ "$untar" == "true" ]]; then
      extract_root="$UNTAR_DIR/$name"
      mkdir -p "$extract_root"
      tar_count=0
      while IFS= read -r -d '' tarball; do
        tar_count=$(( tar_count + 1 ))
        # -p preserves permissions; tar restores the symlinks that upload-artifact
        # would otherwise have flattened, which is the entire reason bundles are
        # tarred in the first place.
        if ! tar -xpf "$tarball" -C "$extract_root" 2>/dev/null; then
          problems+=("failed to extract $(basename "$tarball")")
        fi
      done < <(find "$path" -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' \) -print0 2>/dev/null)

      if [[ "$tar_count" -eq 0 ]]; then
        problems+=("expected a tar archive of macOS bundles but found none")
      else
        log "   extracted $tar_count tar archive(s)"
        # Assert against the extracted tree plus anything shipped untarred.
        search_root="$extract_root"
      fi
    fi

    # 3. size > 0
    bytes="$(size_of "$path")"
    if [[ "$bytes" -eq 0 ]]; then
      problems+=("artifact is empty (0 bytes) — if-no-files-found: error should have caught this")
    fi

    # 4. every required glob matches at least one non-empty entry
    for pattern in "${globs[@]}"; do
      mapfile -t matches < <(find "$search_root" -name "$pattern" -print 2>/dev/null | sort)

      if [[ ${#matches[@]} -eq 0 ]]; then
        problems+=("no entry matching '$pattern'")
        continue
      fi

      non_empty=0
      for match in "${matches[@]}"; do
        [[ "$(size_of "$match")" -gt 0 ]] && non_empty=$(( non_empty + 1 ))
      done

      if [[ "$non_empty" -eq 0 ]]; then
        problems+=("every entry matching '$pattern' is 0 bytes")
      else
        log "   ok  $pattern -> ${#matches[@]} match(es), $non_empty non-empty"
      fi
    done

    # 5. macOS bundles survived the tar round-trip intact
    for pattern in "${bundles[@]}"; do
      while IFS= read -r bundle; do
        [[ -n "$bundle" ]] || continue
        if [[ ! -d "$bundle/Contents/MacOS" ]]; then
          problems+=("$(basename "$bundle") has no Contents/MacOS/ — the bundle did not survive the tar round-trip")
        fi
        if [[ ! -f "$bundle/Contents/Info.plist" ]]; then
          problems+=("$(basename "$bundle") has no Contents/Info.plist")
        fi
        if [[ -d "$bundle/Contents/MacOS" && -f "$bundle/Contents/Info.plist" ]]; then
          log "   ok  $(basename "$bundle") bundle structure intact"
        fi
      done < <(find "$search_root" -maxdepth 6 -name "$pattern" -type d -print 2>/dev/null | sort)
    done
  fi

  bytes="$(size_of "$path")"
  files="$(count_files "$path")"

  if [[ ${#problems[@]} -eq 0 ]]; then
    verdict="pass"
    log "   PASS  ${bytes} bytes, ${files} files"
  else
    verdict="FAIL"
    overall_rc=1
    for problem in "${problems[@]}"; do
      log "   FAIL  $problem"
      FAILURES+=("$name: $problem")
    done
  fi

  ROW_NAME+=("$name")
  ROW_PRESENT+=("$([[ -d "$path" ]] && echo yes || echo no)")
  ROW_BYTES+=("$bytes")
  ROW_FILES+=("$files")
  ROW_VERDICT+=("$verdict")
  log ""
done

# --- summary table ---------------------------------------------------------
echo ""
printf '%-34s %-8s %14s %7s  %s\n' "ARTIFACT" "PRESENT" "BYTES" "FILES" "VERDICT"
printf '%-34s %-8s %14s %7s  %s\n' "----------------------------------" "--------" "--------------" "-------" "-------"
for i in "${!ROW_NAME[@]}"; do
  printf '%-34s %-8s %14s %7s  %s\n' \
    "${ROW_NAME[$i]}" "${ROW_PRESENT[$i]}" "${ROW_BYTES[$i]}" "${ROW_FILES[$i]}" "${ROW_VERDICT[$i]}"
done
echo ""

if [[ "$overall_rc" -ne 0 ]]; then
  echo "ARTIFACT CONTRACT VIOLATED — ${#FAILURES[@]} problem(s):"
  for failure in "${FAILURES[@]}"; do
    echo "  - $failure"
  done
  echo ""
  echo "This run is NOT green regardless of whether the build jobs passed."
  exit 1
fi

echo "ARTIFACT CONTRACT SATISFIED — every required artifact is present, non-empty and well formed."
exit 0
