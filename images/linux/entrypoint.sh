#!/usr/bin/env bash
#
# Runner Forge — linux-util container entrypoint.
#
# Contract (identical to the Windows image's entrypoint.ps1):
#   1. Read the JIT config from stdin, or from RUNNER_JITCONFIG in the
#      environment when the caller used --env-file.
#   2. Export the cache locations the build expects.
#   3. Run the Actions runner for exactly ONE job.
#   4. Exit with the runner's exit code, unchanged.
#
# There is NO config.sh step. A JIT config is not something you configure from;
# it *is* the configuration, valid for a single job.
#
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }

fail() { printf '[entrypoint] error: %s\n' "$*" >&2; exit 78; }

# ---------------------------------------------------------------------------
# 1. Obtain the JIT config.
#
# It crosses the host -> container boundary by stdin or by an --env-file that
# the host overwrites with random bytes and deletes the moment the container
# reports started. It is NEVER a --build-arg (recorded in image history), never
# inline in compose, and never on the host's `docker run` command line, where
# any user on the machine could read it out of the process list.
# ---------------------------------------------------------------------------
JITCONFIG=""

if [[ -n "${RUNNER_JITCONFIG:-}" ]]; then
  JITCONFIG="${RUNNER_JITCONFIG}"
  # Drop it from the environment immediately: /proc/<pid>/environ is readable
  # by anything running as this user inside the container.
  unset RUNNER_JITCONFIG
  log "JIT config received from the environment (${#JITCONFIG} bytes)"
elif [[ ! -t 0 ]]; then
  # Read one line from stdin. `read -r` keeps backslashes literal; base64 has
  # none, but a config that silently lost a character is worse than one that
  # fails loudly.
  IFS= read -r JITCONFIG || true
  log "JIT config received on stdin (${#JITCONFIG} bytes)"
fi

if [[ -z "$JITCONFIG" ]]; then
  fail "no JIT config supplied. Provide it on stdin or as RUNNER_JITCONFIG.
       This image never registers with a long-lived registration token, and it
       has no config.sh step to fall back to."
fi

# Only ever report the length. The value itself must not reach a log, the
# console, or a file.
log "JIT config length looks plausible: ${#JITCONFIG} bytes"

# ---------------------------------------------------------------------------
# 2. Cache locations.
#
# These point at the named volumes (forge-fetchcontent, forge-ccache) so JUCE is
# cloned once per machine rather than once per build. They are KEEP items: the
# Sweeper never deletes them, because deleting them is precisely what makes the
# next build slow.
# ---------------------------------------------------------------------------
export FETCHCONTENT_BASE_DIR="${FETCHCONTENT_BASE_DIR:-/cache/fetchcontent}"
export CCACHE_DIR="${CCACHE_DIR:-/cache/ccache}"
mkdir -p "$FETCHCONTENT_BASE_DIR" "$CCACHE_DIR"

log "FETCHCONTENT_BASE_DIR=$FETCHCONTENT_BASE_DIR"
log "CCACHE_DIR=$CCACHE_DIR"

cd "${RUNNER_HOME:-/home/runner/actions-runner}"

# ---------------------------------------------------------------------------
# 3. Run exactly one job.
#
# run.sh --jitconfig is the only interface the Actions runner offers, so the
# blob does appear in this process's argv. That is inside the container's own
# PID namespace, which is not shared with the host and is destroyed with the
# container after a single job. The boundary that matters — the host process
# list — never sees it, which is what the stdin/env-file handoff above is for.
# ---------------------------------------------------------------------------
log "starting the runner for a single job"

set +e
./run.sh --jitconfig "$JITCONFIG"
RUNNER_EXIT=$?
set -e

# Drop the blob from this shell's memory as soon as it is no longer needed.
JITCONFIG=""
unset JITCONFIG

log "runner exited with code ${RUNNER_EXIT}"

# 4. The runner's exit code is the container's exit code. The supervisor uses it
#    to decide between "job finished" and "this class is broken" (three non-zero
#    exits in five minutes stops the class).
exit "${RUNNER_EXIT}"
