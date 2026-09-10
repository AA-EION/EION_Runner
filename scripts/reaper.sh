#!/usr/bin/env bash
#
# reaper.sh — "verify nothing keeps running".
#
# Answers exactly one question: is anything still alive that should not be?
# It runs on container/VM exit, on job completion, on app close, and on a
# 30-second watchdog poll.
#
# It does NOT decide what to delete — that is the Sweeper's job (sweeper.sh).
# Keeping the two apart matters: "is it running?" and "can I delete it?" have
# different answers and different blast radii.
#
# Exit codes are part of the contract and the GUI depends on them:
#   0   clean            nothing stray was found
#   10  strays killed    strays were found and are now gone
#   20  strays survived  something ignored SIGKILL; the GUI shows a red banner
#                        and refuses to start new runners until acknowledged
#   2   usage error
#
set -uo pipefail

WORK_DIR=""
SCOPE=""
DRY_RUN=0
GRACE_SECONDS=10
QUIET=0

usage() {
  cat >&2 <<'USAGE'
Usage: reaper.sh [--work-dir <dir>] [--scope <runner-name>] [--dry-run]
                 [--grace-seconds <n>] [--quiet]

  --work-dir        Runner Forge work directory. Its state.json lists the runners
                    that are legitimately alive, so their processes are spared.
  --scope           Only reap leftovers belonging to this runner name.
  --dry-run         Report what would be killed; kill nothing. Never exits 10/20.
  --grace-seconds   Seconds to wait after SIGTERM before SIGKILL (default 10).

Exit codes: 0 clean, 10 strays found and killed, 20 strays survived, 2 usage.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir)      WORK_DIR="${2:-}"; shift 2 ;;
    --scope)         SCOPE="${2:-}"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --grace-seconds) GRACE_SECONDS="${2:-10}"; shift 2 ;;
    --quiet)         QUIET=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

log()  { [[ "$QUIET" -eq 1 ]] || printf '[reaper] %s\n' "$*"; }
warn() { printf '[reaper] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Processes that must not exist outside a live, registered job.
#
# This list is the macOS/Linux half of the contract; reaper.ps1 carries the
# Windows half. A build toolchain still running after the job that spawned it
# has ended is holding file locks and burning CPU on a machine the user thinks
# is idle.
# ---------------------------------------------------------------------------
STRAY_PROCESS_NAMES=(
  "Runner.Listener"
  "Runner.Worker"
  "xcodebuild"
  "clang"
  "ld"
  "cmake"
  "ninja"
  "wraptool"
  "notarytool"
)

# ---------------------------------------------------------------------------
# PIDs that are legitimately alive, read from state.json. Without this the
# Reaper would happily kill the runner it is supposed to be protecting.
# ---------------------------------------------------------------------------
LIVE_PIDS=" "
LIVE_NAMES=""

if [[ -n "$WORK_DIR" && -f "$WORK_DIR/state.json" ]]; then
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r pid;  do [[ -n "$pid"  ]] && LIVE_PIDS="${LIVE_PIDS}${pid} "; done \
      < <(jq -r '.runners[]? | select(.pid != null) | .pid' "$WORK_DIR/state.json" 2>/dev/null)
    while IFS= read -r name; do [[ -n "$name" ]] && LIVE_NAMES="${LIVE_NAMES}${name} "; done \
      < <(jq -r '.runners[]? | .runnerName // empty' "$WORK_DIR/state.json" 2>/dev/null)
    log "state.json lists live runners:${LIVE_NAMES:- (none)}"
  else
    warn "jq not found: cannot read state.json, so every matching process is treated as stray"
  fi
else
  log "no state.json found; treating every matching process as stray"
fi

is_live_pid() {
  case "$LIVE_PIDS" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

SELF_PID=$$
PARENT_PID="$(ps -o ppid= -p "$SELF_PID" 2>/dev/null | tr -d ' ')"

# ---------------------------------------------------------------------------
# Find strays.
# ---------------------------------------------------------------------------
STRAY_PIDS=()
STRAY_DESCRIPTIONS=()

for name in "${STRAY_PROCESS_NAMES[@]}"; do
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    [[ "$pid" == "$SELF_PID" || "$pid" == "$PARENT_PID" ]] && continue
    is_live_pid "$pid" && continue

    cmdline="$(ps -o command= -p "$pid" 2>/dev/null | tr -s ' ')"
    [[ -n "$cmdline" ]] || continue

    # Never match ourselves through our own argument list.
    case "$cmdline" in *reaper.sh*) continue ;; esac

    # When scoped to one runner, only that runner's leftovers are in play.
    if [[ -n "$SCOPE" ]]; then
      case "$cmdline" in *"$SCOPE"*) : ;; *) continue ;; esac
    fi

    STRAY_PIDS+=("$pid")
    STRAY_DESCRIPTIONS+=("$name pid=$pid :: $cmdline")
  done < <(pgrep -x "$name" 2>/dev/null || true)
done

# ---------------------------------------------------------------------------
# Tart VM clones that are running with no job claiming them (macOS only).
# ---------------------------------------------------------------------------
STRAY_VMS=()
if command -v tart >/dev/null 2>&1; then
  while IFS= read -r vm; do
    [[ -n "$vm" ]] || continue
    case "$LIVE_NAMES" in *"$vm"*) continue ;; esac
    STRAY_VMS+=("$vm")
  done < <(tart list --quiet 2>/dev/null | grep -E '^forge-' || true)
fi

# ---------------------------------------------------------------------------
# Ephemeral signing keychains. One left behind means a signing script died
# before its trap ran, which also means a private key is sitting unlocked.
# ---------------------------------------------------------------------------
STRAY_KEYCHAINS=()
if command -v security >/dev/null 2>&1; then
  while IFS= read -r keychain; do
    [[ -n "$keychain" ]] || continue
    STRAY_KEYCHAINS+=("$keychain")
  done < <(security list-keychains 2>/dev/null | tr -d ' "' | grep 'runnerforge-ci-' || true)
fi

TOTAL=$(( ${#STRAY_PIDS[@]} + ${#STRAY_VMS[@]} + ${#STRAY_KEYCHAINS[@]} ))

if [[ "$TOTAL" -eq 0 ]]; then
  log "clean: no stray processes, VM clones or ephemeral keychains"
  exit 0
fi

log "found $TOTAL stray item(s)"
for description in "${STRAY_DESCRIPTIONS[@]}"; do log "  process  $description"; done
for vm          in "${STRAY_VMS[@]}";          do log "  vm clone $vm"; done
for keychain    in "${STRAY_KEYCHAINS[@]}";    do log "  keychain $keychain"; done

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry run: nothing was killed"
  exit 0
fi

# ---------------------------------------------------------------------------
# SIGTERM, wait, SIGKILL, re-verify. Never SIGKILL first: a runner that is
# given the chance to shut down cleanly will unregister itself from GitHub,
# and one that is killed outright leaves an offline registration behind.
# ---------------------------------------------------------------------------
for pid in "${STRAY_PIDS[@]}"; do
  log "SIGTERM -> $pid"
  kill -TERM "$pid" 2>/dev/null || true
done

if [[ ${#STRAY_PIDS[@]} -gt 0 ]]; then
  log "waiting ${GRACE_SECONDS}s for a clean exit"
  waited=0
  while [[ "$waited" -lt "$GRACE_SECONDS" ]]; do
    still_running=0
    for pid in "${STRAY_PIDS[@]}"; do
      kill -0 "$pid" 2>/dev/null && still_running=1
    done
    [[ "$still_running" -eq 0 ]] && break
    sleep 1
    waited=$(( waited + 1 ))
  done

  for pid in "${STRAY_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      log "SIGKILL -> $pid (ignored SIGTERM for ${GRACE_SECONDS}s)"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
fi

for vm in "${STRAY_VMS[@]}"; do
  log "deleting stray VM clone $vm"
  tart stop "$vm" >/dev/null 2>&1 || true
  tart delete "$vm" >/dev/null 2>&1 || true
done

for keychain in "${STRAY_KEYCHAINS[@]}"; do
  log "deleting ephemeral keychain $keychain"
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------------------
# Re-verify. Reporting "killed" without checking is how a stray survives a
# Reaper run and nobody notices.
# ---------------------------------------------------------------------------
sleep 1
SURVIVORS=()

for pid in "${STRAY_PIDS[@]}"; do
  kill -0 "$pid" 2>/dev/null && SURVIVORS+=("process pid=$pid")
done
for vm in "${STRAY_VMS[@]}"; do
  if command -v tart >/dev/null 2>&1 && tart list --quiet 2>/dev/null | grep -qx "$vm"; then
    SURVIVORS+=("vm clone $vm")
  fi
done
for keychain in "${STRAY_KEYCHAINS[@]}"; do
  if command -v security >/dev/null 2>&1 && security list-keychains 2>/dev/null | grep -q "$keychain"; then
    SURVIVORS+=("keychain $keychain")
  fi
done

if [[ ${#SURVIVORS[@]} -gt 0 ]]; then
  warn "STRAYS SURVIVED — ${#SURVIVORS[@]} item(s) are still present after SIGKILL:"
  for survivor in "${SURVIVORS[@]}"; do warn "  $survivor"; done
  warn "new runners must not be started until this is resolved."
  exit 20
fi

log "all $TOTAL stray item(s) confirmed gone"
exit 10
