#!/usr/bin/env bash
#
# sweeper.sh — "clean on close, keep only what makes the next run fast".
#
# Works from two EXPLICIT lists, never a heuristic, because erring in either
# direction is a bug:
#
#   deleting a KEEP item  -> the next build re-clones JUCE and re-pulls a
#                            multi-gigabyte base image, for nothing
#   keeping a PURGE item  -> the disk fills up and the machine stops building
#
# The single most important rule in this file: `docker system prune -a` is NEVER
# used. It would delete the tagged base images, which is precisely the thing the
# KEEP list exists to prevent. Targeted prunes only.
#
# Usage:
#   sweeper.sh --work-dir <dir> [--log-retention-days <n>] [--dry-run]
#              [--report-json <path>] [--quiet]
#
# --report-json writes the KEEP/PURGE breakdown with per-item sizes, which is
# what the GUI's Cleanup page renders as its two columns.
#
set -uo pipefail

WORK_DIR=""
LOG_RETENTION_DAYS=7
DRY_RUN=0
REPORT_JSON=""
QUIET=0

usage() {
  cat >&2 <<'USAGE'
Usage: sweeper.sh --work-dir <dir> [--log-retention-days <n>] [--dry-run]
                  [--report-json <path>] [--quiet]

  --work-dir             Runner Forge work directory (jobs/, cache/, logs/, proof/).
  --log-retention-days   Delete logs older than this many days (default 7).
  --dry-run              Report only; delete nothing.
  --report-json          Write the KEEP/PURGE breakdown here for the GUI.

Exit codes: 0 ok, 2 usage error.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir)            WORK_DIR="${2:-}"; shift 2 ;;
    --log-retention-days)  LOG_RETENTION_DAYS="${2:-7}"; shift 2 ;;
    --dry-run)             DRY_RUN=1; shift ;;
    --report-json)         REPORT_JSON="${2:-}"; shift 2 ;;
    --quiet)               QUIET=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$WORK_DIR" ]] || { echo "error: --work-dir is required" >&2; usage; exit 2; }

log() { [[ "$QUIET" -eq 1 ]] || printf '[sweeper] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# THE KEEP LIST. Nothing here is ever deleted, on close or on demand.
# ---------------------------------------------------------------------------
KEEP_VOLUMES=(forge-fetchcontent forge-sccache forge-ccache forge-aax-sdk)

# Image tags are read from versions.toml so this list cannot drift from what the
# builds actually produce.
KEEP_IMAGE_TAGS=()
VERSIONS_TOML=""
for candidate in "$(dirname "$0")/../versions.toml" "./versions.toml" "$WORK_DIR/versions.toml"; do
  [[ -f "$candidate" ]] && { VERSIONS_TOML="$candidate"; break; }
done

read_pin() {
  # read_pin <file> <section> <key>
  awk -v section="[$2]" -v key="$3" '
    /^\[/ { in_section = ($0 == section) }
    in_section && $0 !~ /^[ \t]*#/ {
      if (match($0, "^[ \t]*" key "[ \t]*=[ \t]*\"")) {
        line = substr($0, RSTART + RLENGTH)
        sub(/".*/, "", line)
        print line
        exit
      }
    }' "$1"
}

if [[ -n "$VERSIONS_TOML" ]]; then
  WIN_TAG="$(read_pin "$VERSIONS_TOML" windows_image tag)"
  LINUX_TAG="$(read_pin "$VERSIONS_TOML" linux_image tag)"
  WIN_BASE="$(read_pin "$VERSIONS_TOML" windows_image base)"
  LINUX_BASE="$(read_pin "$VERSIONS_TOML" linux_image base)"
  MAC_TAG="$(read_pin "$VERSIONS_TOML" macos_image tag)"
  MAC_BASE="$(read_pin "$VERSIONS_TOML" macos_image base_image)"
  [[ -n "$WIN_TAG"    ]] && KEEP_IMAGE_TAGS+=("runnerforge/win-build:$WIN_TAG")
  [[ -n "$LINUX_TAG"  ]] && KEEP_IMAGE_TAGS+=("runnerforge/linux-util:$LINUX_TAG")
  [[ -n "$WIN_BASE"   ]] && KEEP_IMAGE_TAGS+=("$WIN_BASE")
  [[ -n "$LINUX_BASE" ]] && KEEP_IMAGE_TAGS+=("$LINUX_BASE")
  KEEP_TART_IMAGES=()
  [[ -n "$MAC_TAG"  ]] && KEEP_TART_IMAGES+=("runnerforge-macos:$MAC_TAG")
  [[ -n "$MAC_BASE" ]] && KEEP_TART_IMAGES+=("$MAC_BASE")
  log "KEEP list read from $VERSIONS_TOML"
else
  KEEP_TART_IMAGES=()
  log "warning: versions.toml not found; the KEEP list cannot be verified, so no image pruning will run"
fi

dir_bytes() {
  [[ -d "$1" ]] || { printf '0'; return; }
  du -sb "$1" 2>/dev/null | cut -f1 || printf '0'
}

RECLAIMABLE=0
RECLAIMED=0
# KEEP images that actually exist on this host before the sweep. A host that
# only runs Linux containers legitimately has no win-build image, and reporting
# that as "missing after the sweep" would cry wolf.
PRESENT_BEFORE=" "
KEEP_REPORT=()
PURGE_REPORT=()

note_keep()  { KEEP_REPORT+=("$1|$2"); }
note_purge() { PURGE_REPORT+=("$1|$2"); RECLAIMABLE=$(( RECLAIMABLE + $2 )); }

log "==> surveying"

# --- KEEP: report their sizes so the user can see what the speed costs -------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  for volume in "${KEEP_VOLUMES[@]}"; do
    if docker volume inspect "$volume" >/dev/null 2>&1; then
      mountpoint="$(docker volume inspect "$volume" --format '{{.Mountpoint}}' 2>/dev/null)"
      note_keep "volume $volume" "$(dir_bytes "$mountpoint")"
    fi
  done
  for tag in "${KEEP_IMAGE_TAGS[@]}"; do
    if size="$(docker image inspect "$tag" --format '{{.Size}}' 2>/dev/null)"; then
      note_keep "image $tag" "$size"
      PRESENT_BEFORE="${PRESENT_BEFORE}${tag} "
    fi
  done
fi

[[ -d "$WORK_DIR/cache" ]] && note_keep "cache $WORK_DIR/cache" "$(dir_bytes "$WORK_DIR/cache")"

if command -v tart >/dev/null 2>&1; then
  for image in "${KEEP_TART_IMAGES[@]}"; do
    tart list --quiet 2>/dev/null | grep -qx "$image" && note_keep "tart image $image" 0
  done
fi

# --- PURGE ------------------------------------------------------------------
STOPPED_CONTAINERS=()
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  while IFS= read -r container; do
    [[ -n "$container" ]] && STOPPED_CONTAINERS+=("$container")
  done < <(docker ps -a --filter status=exited --filter status=created --filter status=dead --format '{{.ID}}' 2>/dev/null)
  [[ ${#STOPPED_CONTAINERS[@]} -gt 0 ]] && note_purge "containers (exited/created/dead) x${#STOPPED_CONTAINERS[@]}" 0
fi

STRAY_TART_CLONES=()
if command -v tart >/dev/null 2>&1; then
  # CLONES ONLY. A clone is named forge-*; an image is not. Deleting an image
  # here would destroy tens of gigabytes that take an hour to rebuild.
  while IFS= read -r clone; do
    [[ -n "$clone" ]] && STRAY_TART_CLONES+=("$clone")
  done < <(tart list --quiet 2>/dev/null | grep -E '^forge-' || true)
  [[ ${#STRAY_TART_CLONES[@]} -gt 0 ]] && note_purge "tart clones x${#STRAY_TART_CLONES[@]}" 0
fi

JOBS_BYTES=0
[[ -d "$WORK_DIR/jobs" ]] && { JOBS_BYTES="$(dir_bytes "$WORK_DIR/jobs")"; note_purge "job workspaces $WORK_DIR/jobs" "$JOBS_BYTES"; }

TMP_BYTES=0
[[ -d "$WORK_DIR/tmp" ]] && { TMP_BYTES="$(dir_bytes "$WORK_DIR/tmp")"; note_purge "temp downloads $WORK_DIR/tmp" "$TMP_BYTES"; }

OLD_LOGS=()
if [[ -d "$WORK_DIR/logs" ]]; then
  while IFS= read -r logfile; do
    [[ -n "$logfile" ]] && OLD_LOGS+=("$logfile")
  done < <(find "$WORK_DIR/logs" -type f -mtime "+${LOG_RETENTION_DAYS}" 2>/dev/null)
  bytes=0
  for logfile in "${OLD_LOGS[@]:-}"; do
    [[ -f "$logfile" ]] && bytes=$(( bytes + $(stat -c%s "$logfile" 2>/dev/null || stat -f%z "$logfile") ))
  done
  [[ ${#OLD_LOGS[@]} -gt 0 ]] && note_purge "logs older than ${LOG_RETENTION_DAYS}d x${#OLD_LOGS[@]}" "$bytes"
fi

# Proof bundles: keep the most recent, purge older ones. The most recent proof
# is what the Runners page shows as "currently known-good"; deleting it would
# make the GUI claim the setup has never been verified.
OLD_PROOFS=()
if [[ -d "$WORK_DIR/proof" ]]; then
  newest="$(ls -1t "$WORK_DIR/proof" 2>/dev/null | head -1)"
  while IFS= read -r bundle; do
    [[ -n "$bundle" && "$bundle" != "$newest" ]] || continue
    OLD_PROOFS+=("$WORK_DIR/proof/$bundle")
  done < <(ls -1 "$WORK_DIR/proof" 2>/dev/null)
  bytes=0
  for bundle in "${OLD_PROOFS[@]:-}"; do bytes=$(( bytes + $(dir_bytes "$bundle") )); done
  [[ ${#OLD_PROOFS[@]} -gt 0 ]] && note_purge "old proof bundles x${#OLD_PROOFS[@]} (keeping $newest)" "$bytes"
fi

STRAY_KEYCHAINS=()
if command -v security >/dev/null 2>&1; then
  while IFS= read -r keychain; do
    [[ -n "$keychain" ]] && STRAY_KEYCHAINS+=("$keychain")
  done < <(security list-keychains 2>/dev/null | tr -d ' "' | grep 'runnerforge-ci-' || true)
  [[ ${#STRAY_KEYCHAINS[@]} -gt 0 ]] && note_purge "ephemeral keychains x${#STRAY_KEYCHAINS[@]}" 0
fi

log "KEEP (never deleted):"
for entry in "${KEEP_REPORT[@]:-}"; do
  [[ -n "$entry" ]] && log "  ${entry%%|*}  (${entry##*|} bytes)"
done
log "PURGE:"
for entry in "${PURGE_REPORT[@]:-}"; do
  [[ -n "$entry" ]] && log "  ${entry%%|*}  (${entry##*|} bytes)"
done
log "reclaimable: ${RECLAIMABLE} bytes"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry run: nothing was deleted"
else
  log "==> purging"

  if [[ ${#STOPPED_CONTAINERS[@]} -gt 0 ]]; then
    log "removing ${#STOPPED_CONTAINERS[@]} stopped container(s)"
    docker rm -f "${STOPPED_CONTAINERS[@]}" >/dev/null 2>&1 || true
  fi

  for clone in "${STRAY_TART_CLONES[@]:-}"; do
    [[ -n "$clone" ]] || continue
    log "deleting tart CLONE $clone (images are never touched)"
    tart stop "$clone" >/dev/null 2>&1 || true
    tart delete "$clone" >/dev/null 2>&1 || true
  done

  if [[ -d "$WORK_DIR/jobs" ]]; then
    log "removing job workspaces"
    rm -rf -- "$WORK_DIR/jobs"/* 2>/dev/null || true
    RECLAIMED=$(( RECLAIMED + JOBS_BYTES ))
  fi

  if [[ -d "$WORK_DIR/tmp" ]]; then
    log "removing this session's temp downloads"
    rm -rf -- "$WORK_DIR/tmp"/* 2>/dev/null || true
    RECLAIMED=$(( RECLAIMED + TMP_BYTES ))
  fi

  for logfile in "${OLD_LOGS[@]:-}"; do
    [[ -n "$logfile" ]] && rm -f -- "$logfile" 2>/dev/null || true
  done

  for bundle in "${OLD_PROOFS[@]:-}"; do
    [[ -n "$bundle" ]] && rm -rf -- "$bundle" 2>/dev/null || true
  done

  for keychain in "${STRAY_KEYCHAINS[@]:-}"; do
    [[ -n "$keychain" ]] || continue
    log "deleting ephemeral keychain $keychain"
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
  done

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    # TARGETED prunes only. `docker image prune -f` removes dangling (untagged)
    # images; it does not touch a tagged image, so every KEEP tag survives.
    #
    # `docker system prune -a` would delete them and is NEVER used here.
    log "pruning dangling images and build cache (never 'system prune -a')"
    before_images="$(docker image prune -f 2>/dev/null | grep -oE 'Total reclaimed space: .*' || true)"
    before_builder="$(docker builder prune -f 2>/dev/null | grep -oE 'Total:.*' || true)"
    [[ -n "$before_images"  ]] && log "  images:  $before_images"
    [[ -n "$before_builder" ]] && log "  builder: $before_builder"
  fi

  log "reclaimed at least ${RECLAIMED} bytes from tracked directories"

  # Prove the KEEP list survived. A sweeper that quietly ate a base image would
  # otherwise only be discovered by the next build taking an hour.
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    for tag in "${KEEP_IMAGE_TAGS[@]:-}"; do
      [[ -n "$tag" ]] || continue
      case "$PRESENT_BEFORE" in
        *" $tag "*) : ;;
        *) log "  KEEP not on this host (nothing to verify): $tag"; continue ;;
      esac
      if docker image inspect "$tag" >/dev/null 2>&1; then
        log "  KEEP verified present: $tag"
      else
        log "  ERROR: a KEEP image was present before the sweep and is gone now: $tag"
      fi
    done
    for volume in "${KEEP_VOLUMES[@]}"; do
      if docker volume inspect "$volume" >/dev/null 2>&1; then
        log "  KEEP verified present: volume $volume"
      fi
    done
  fi
fi

if [[ -n "$REPORT_JSON" ]]; then
  {
    printf '{\n  "reclaimableBytes": %s,\n  "reclaimedBytes": %s,\n  "keep": [\n' "$RECLAIMABLE" "$RECLAIMED"
    first=1
    for entry in "${KEEP_REPORT[@]:-}"; do
      [[ -n "$entry" ]] || continue
      [[ $first -eq 0 ]] && printf ',\n'; first=0
      printf '    {"item": "%s", "bytes": %s}' "${entry%%|*}" "${entry##*|}"
    done
    printf '\n  ],\n  "purge": [\n'
    first=1
    for entry in "${PURGE_REPORT[@]:-}"; do
      [[ -n "$entry" ]] || continue
      [[ $first -eq 0 ]] && printf ',\n'; first=0
      printf '    {"item": "%s", "bytes": %s}' "${entry%%|*}" "${entry##*|}"
    done
    printf '\n  ]\n}\n'
  } > "$REPORT_JSON"
  log "wrote report to $REPORT_JSON"
fi

exit 0
