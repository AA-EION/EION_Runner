#!/usr/bin/env bash
#
# tart-runner.sh — run exactly one job in a throwaway macOS VM.
#
# The whole lifecycle of a mac-build runner:
#
#   1. `tart clone` the immutable image to forge-mac-<uuid>. A clone is
#      copy-on-write, so this is cheap and the image is never modified.
#   2. Boot it headless and wait for SSH.
#   3. Inject the JIT config over stdin. Never argv: argv is visible in the
#      guest's process list and, on some configurations, in host-side logs.
#   4. `./run.sh --jitconfig <blob>` — one job, then the runner unregisters
#      itself and exits. There is no config.sh step.
#   5. `tart delete` the clone. ALWAYS, in a trap EXIT, whether the job passed,
#      failed, or the script was interrupted. A leaked clone is tens of
#      gigabytes and a poisoned environment for the next job.
#
# Runs only on macOS on Apple Silicon. There is no Windows, Linux, QEMU or KVM
# path to a macOS runner: Tart uses Apple's Virtualization framework, and
# virtualizing macOS on non-Apple hardware is both technically impossible on
# that hardware and a violation of Apple's licence.
#
set -euo pipefail

IMAGE=""
JITCONFIG=""
JOB_TIMEOUT_MINUTES=90
SSH_USER="admin"
SSH_PASSWORD="admin"
CACHE_DIR=""
KEEP_ON_FAILURE=0

usage() {
  cat >&2 <<'USAGE'
Usage: tart-runner.sh --image <name:tag> [--jitconfig <blob> | blob on stdin]
                      [--job-timeout-minutes <n>] [--cache-dir <path>]
                      [--ssh-user <u>] [--ssh-password <p>] [--keep-on-failure]

  --image                 The Tart IMAGE to clone (never modified).
  --jitconfig             Prefer stdin. Passing it here puts it in this
                          process's argv, which is exactly what we avoid.
  --cache-dir             Host directory bind-mounted into the clone so JUCE is
                          cloned once per machine rather than once per build.
  --keep-on-failure       Leave the clone behind for post-mortem. Off by
                          default: leaked clones are the single most expensive
                          mistake this script can make.

Exit codes: the runner's own exit code, or 2 usage, 3 environment, 4 VM error.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)                IMAGE="${2:-}"; shift 2 ;;
    --jitconfig)            JITCONFIG="${2:-}"; shift 2 ;;
    --job-timeout-minutes)  JOB_TIMEOUT_MINUTES="${2:-90}"; shift 2 ;;
    --cache-dir)            CACHE_DIR="${2:-}"; shift 2 ;;
    --ssh-user)             SSH_USER="${2:-admin}"; shift 2 ;;
    --ssh-password)         SSH_PASSWORD="${2:-admin}"; shift 2 ;;
    --keep-on-failure)      KEEP_ON_FAILURE=1; shift ;;
    -h|--help)              usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

log() { printf '[tart-runner] %s\n' "$*"; }

[[ -n "$IMAGE" ]] || { echo "error: --image is required" >&2; usage; exit 2; }

command -v tart >/dev/null 2>&1 || {
  echo "error: tart is not on PATH. macOS runners require Tart; install it with 'brew install cirruslabs/cli/tart'." >&2
  exit 3
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this script runs only on macOS. macOS cannot be virtualized on non-Apple hardware — not in Docker, QEMU, KVM or WSL." >&2
  exit 3
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: Apple Silicon is required. Tart uses Apple's Virtualization framework." >&2
  exit 3
fi

# --- the JIT config ---------------------------------------------------------
if [[ -z "$JITCONFIG" && ! -t 0 ]]; then
  IFS= read -r JITCONFIG || true
fi

if [[ -z "$JITCONFIG" ]]; then
  echo "error: no JIT config supplied. Provide it on stdin (preferred) or with --jitconfig." >&2
  echo "       This runner never registers with a long-lived registration token." >&2
  exit 2
fi

log "JIT config received (${#JITCONFIG} bytes)"   # length only, never the value

# --- clone ------------------------------------------------------------------
CLONE="forge-mac-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-12)"

# The trap is registered BEFORE the clone exists so that a failure during
# `tart clone` itself cannot leak a partial VM.
cleanup() {
  local status=$?
  set +e
  if [[ "$KEEP_ON_FAILURE" -eq 1 && "$status" -ne 0 ]]; then
    log "leaving clone $CLONE behind for post-mortem (--keep-on-failure). Delete it with: tart delete $CLONE"
    return
  fi
  if tart list --quiet 2>/dev/null | grep -qx "$CLONE"; then
    log "deleting clone $CLONE"
    tart stop "$CLONE" >/dev/null 2>&1
    tart delete "$CLONE" >/dev/null 2>&1
    if tart list --quiet 2>/dev/null | grep -qx "$CLONE"; then
      log "WARNING: clone $CLONE could not be deleted; the Reaper will retry"
    else
      log "clone $CLONE deleted"
    fi
  fi
}
trap cleanup EXIT INT TERM

log "cloning image $IMAGE -> $CLONE"
tart clone "$IMAGE" "$CLONE" || { echo "error: tart clone failed" >&2; exit 4; }

# --- boot -------------------------------------------------------------------
RUN_ARGS=(--no-graphics)
if [[ -n "$CACHE_DIR" ]]; then
  mkdir -p "$CACHE_DIR"
  # The persistent cache is the reason run 2 is faster than run 1. It is a KEEP
  # item on the host and lives outside the clone entirely.
  RUN_ARGS+=(--dir="cache:$CACHE_DIR")
  log "mounting host cache $CACHE_DIR into the clone"
fi

log "booting $CLONE headless"
tart run "$CLONE" "${RUN_ARGS[@]}" &
TART_PID=$!

# --- wait for SSH -----------------------------------------------------------
log "waiting for the guest to accept SSH"
VM_IP=""
for _ in $(seq 1 60); do
  VM_IP="$(tart ip "$CLONE" 2>/dev/null || true)"
  [[ -n "$VM_IP" ]] && break
  sleep 2
done

[[ -n "$VM_IP" ]] || { echo "error: the clone never reported an IP address" >&2; exit 4; }
log "guest is at $VM_IP"

ssh_guest() {
  # BatchMode is off because the base image uses password auth; the password is
  # the cirruslabs image's well-known default, not a Runner Forge credential.
  SSHPASS="$SSH_PASSWORD" sshpass -e ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "${SSH_USER}@${VM_IP}" "$@"
}

command -v sshpass >/dev/null 2>&1 || {
  echo "error: sshpass is not on PATH. Install it with 'brew install sshpass' (or hudochenkov/sshpass/sshpass)." >&2
  exit 3
}

for _ in $(seq 1 60); do
  ssh_guest true >/dev/null 2>&1 && break
  sleep 2
done

ssh_guest true >/dev/null 2>&1 || { echo "error: SSH never became available on $VM_IP" >&2; exit 4; }
log "SSH is up"

# --- run exactly one job ----------------------------------------------------
#
# The blob goes over SSH STDIN into a shell that reads it into a variable. It
# never appears in this script's argv, in the ssh command line, or in any log.
log "starting the runner for a single job (timeout ${JOB_TIMEOUT_MINUTES}m)"

set +e
printf '%s\n' "$JITCONFIG" | ssh_guest "bash -s" <<REMOTE
set -euo pipefail
IFS= read -r blob
cd "\$HOME/actions-runner"
export FETCHCONTENT_BASE_DIR="\$HOME/cache/fetchcontent"
export CCACHE_DIR="\$HOME/cache/ccache"
mkdir -p "\$FETCHCONTENT_BASE_DIR" "\$CCACHE_DIR"
./run.sh --jitconfig "\$blob"
REMOTE
RUNNER_EXIT=$?
set -e

JITCONFIG=""
unset JITCONFIG

log "runner exited with code ${RUNNER_EXIT}"

# Stop the VM so the trap's delete is quick. The trap still runs regardless.
tart stop "$CLONE" >/dev/null 2>&1 || true
wait "$TART_PID" 2>/dev/null || true

exit "$RUNNER_EXIT"
