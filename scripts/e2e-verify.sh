#!/usr/bin/env bash
#
# e2e-verify.sh — the Stage B and Stage C driver.
#
# Dispatches the self-test workflow, waits for it, proves the jobs landed on
# Runner Forge runners, downloads every artifact, re-asserts the artifact
# contract locally, runs the Reaper, and checks nothing was left behind. Then it
# does the whole thing again, `--runs` times, and reports the durations so you
# can see the caches warming.
#
# A run is GREEN only when all of these hold:
#   - the run's conclusion is success
#   - EVERY job's runner_name matches forge-*  (a job that silently landed on a
#     hosted runner proves nothing about your runners)
#   - every expected artifact exists, is non-empty and passes verify-artifacts.sh
#   - the Reaper exits 0 afterwards
#   - no leftover container or VM clone remains
#
# If any run fails the count RESTARTS FROM ZERO. Two out of three is a failure,
# not a pass.
#
# Requires GITHUB_TOKEN in the environment with actions:read/write on the repo.
#
set -uo pipefail

REPO=""
WORKFLOW="selftest-selfhosted.yml"
REF="main"
RUNS=3
PROJECT="Canary"
WORK_DIR="${RUNNER_FORGE_WORK_DIR:-$PWD/.forge-work}"
POLL_SECONDS=15
TIMEOUT_MINUTES=90
API="${GITHUB_API_URL:-https://api.github.com}"
SKIP_REAPER=0

usage() {
  cat >&2 <<'USAGE'
Usage: e2e-verify.sh --repo <owner/repo> [--workflow <file>] [--ref <branch>]
                     [--runs <n>] [--project <name>] [--work-dir <path>]
                     [--timeout-minutes <n>] [--skip-reaper]

  --repo              owner/repo holding the self-test workflow.
  --workflow          Workflow file name. Default selftest-selfhosted.yml.
  --runs              Consecutive green runs required. Default 3.
  --skip-reaper       Do not run the Reaper between runs (diagnostics only).

Requires GITHUB_TOKEN with actions read/write on the repository.

Exit codes: 0 the required number of consecutive green runs was achieved,
            1 a run was not green (the count restarted), 2 usage, 3 environment.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)             REPO="${2:-}"; shift 2 ;;
    --workflow)         WORKFLOW="${2:-}"; shift 2 ;;
    --ref)              REF="${2:-}"; shift 2 ;;
    --runs)             RUNS="${2:-3}"; shift 2 ;;
    --project)          PROJECT="${2:-Canary}"; shift 2 ;;
    --work-dir)         WORK_DIR="${2:-}"; shift 2 ;;
    --timeout-minutes)  TIMEOUT_MINUTES="${2:-90}"; shift 2 ;;
    --skip-reaper)      SKIP_REAPER=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

log() { printf '[e2e] %s\n' "$*"; }

[[ -n "$REPO" ]] || { echo "error: --repo is required" >&2; usage; exit 2; }
[[ -n "${GITHUB_TOKEN:-}" ]] || { echo "error: GITHUB_TOKEN is required" >&2; exit 3; }
for tool in curl jq unzip; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required but not on PATH" >&2; exit 3; }
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROOF_ROOT="$WORK_DIR/proof"
mkdir -p "$PROOF_ROOT"

api() {
  curl -sS --max-time 120 \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

# ---------------------------------------------------------------------------
# One run, end to end. Echoes the run id on stdout; everything else to stderr.
# ---------------------------------------------------------------------------
run_once() {
  local attempt="$1"
  local tag="rf-e2e-$(date +%s)-$RANDOM"

  log "run $attempt: dispatching $WORKFLOW with run_name_tag=$tag" >&2

  local dispatch_body
  dispatch_body="$(jq -cn --arg ref "$REF" --arg tag "$tag" --arg project "$PROJECT" \
      '{ref:$ref, inputs:{run_name_tag:$tag, project_name:$project}}')"

  local http
  http="$(api -o /dev/null -w '%{http_code}' -X POST \
      "$API/repos/$REPO/actions/workflows/$WORKFLOW/dispatches" \
      -H 'Content-Type: application/json' -d "$dispatch_body")"

  if [[ "$http" != "204" ]]; then
    echo "error: dispatch returned HTTP $http" >&2
    return 1
  fi

  # Resolve the run WE just created by matching the unique tag echoed into
  # run-name. Taking "the newest run" is race-prone and wrong under concurrency.
  local run_id="" i
  for i in $(seq 1 30); do
    run_id="$(api "$API/repos/$REPO/actions/runs?event=workflow_dispatch&per_page=30" |
              jq -r --arg tag "$tag" '.workflow_runs[] | select((.name // "") | contains($tag)) | .id' | head -1)"
    [[ -n "$run_id" ]] && break
    sleep 4
  done

  if [[ -z "$run_id" ]]; then
    echo "error: could not resolve the dispatched run by its tag '$tag'" >&2
    return 1
  fi

  log "run $attempt: run id $run_id" >&2

  # --- wait -----------------------------------------------------------------
  local started deadline status conclusion
  started="$(date +%s)"
  deadline=$(( started + TIMEOUT_MINUTES * 60 ))
  local last_status=""

  while :; do
    local run_json
    run_json="$(api "$API/repos/$REPO/actions/runs/$run_id")"
    status="$(printf '%s' "$run_json" | jq -r '.status')"
    conclusion="$(printf '%s' "$run_json" | jq -r '.conclusion // "null"')"

    if [[ "$status" != "$last_status" ]]; then
      log "run $attempt: status -> $status" >&2
      last_status="$status"
    fi

    [[ "$status" == "completed" ]] && break

    if (( $(date +%s) > deadline )); then
      log "run $attempt: TIMED OUT after ${TIMEOUT_MINUTES}m" >&2
      conclusion="timed_out"
      break
    fi
    sleep "$POLL_SECONDS"
  done

  local duration=$(( $(date +%s) - started ))
  log "run $attempt: conclusion=$conclusion duration=${duration}s" >&2

  # --- prove it landed on Runner Forge runners ------------------------------
  local jobs_json runner_names bad_runners
  jobs_json="$(api "$API/repos/$REPO/actions/runs/$run_id/jobs?per_page=100")"
  runner_names="$(printf '%s' "$jobs_json" | jq -r '.jobs[] | "\(.name)\t\(.runner_name // "unknown")\t\(.conclusion)"')"

  log "run $attempt: jobs and their runners:" >&2
  printf '%s\n' "$runner_names" | sed 's/^/    /' >&2

  # A job that silently landed on a hosted runner proves nothing about YOUR
  # runners, so this is a hard check, not a note.
  bad_runners="$(printf '%s' "$jobs_json" |
    jq -r '.jobs[] | select((.runner_name // "") | startswith("forge-") | not) | .name' | tr '\n' ' ')"

  local proof_dir="$PROOF_ROOT/$run_id"
  mkdir -p "$proof_dir"
  printf '%s' "$jobs_json" > "$proof_dir/jobs.json"

  # --- artifacts ------------------------------------------------------------
  local artifacts_json
  artifacts_json="$(api "$API/repos/$REPO/actions/runs/$run_id/artifacts?per_page=100")"
  printf '%s' "$artifacts_json" > "$proof_dir/artifacts.json"

  log "run $attempt: artifacts:" >&2
  printf '%s' "$artifacts_json" |
    jq -r '.artifacts[] | "    \(.name)\t\(.size_in_bytes) bytes"' >&2

  local download_dir="$proof_dir/downloaded"
  mkdir -p "$download_dir"

  local id name
  while IFS=$'\t' read -r id name; do
    [[ -n "$id" ]] || continue
    api -L -o "$download_dir/$name.zip" "$API/repos/$REPO/actions/artifacts/$id/zip"
    mkdir -p "$download_dir/$name"
    unzip -qo "$download_dir/$name.zip" -d "$download_dir/$name" && rm -f "$download_dir/$name.zip"
  done < <(printf '%s' "$artifacts_json" | jq -r '.artifacts[] | "\(.id)\t\(.name)"')

  # --- re-assert the contract locally ---------------------------------------
  local manifest="$proof_dir/manifest.json"
  jq -n --arg p "$PROJECT" '{
    project: $p,
    artifacts: [
      {name:($p+"-windows-x64"),       required:true,  globs:["*.vst3","*.clap","*.exe"]},
      {name:($p+"-windows-arm64"),     required:true,  globs:["*.vst3","*.clap","*.exe"]},
      {name:($p+"-windows-installer"), required:true,  globs:["*.exe"]},
      {name:($p+"-macos-universal"),   required:true,  untar:true,
       globs:["*.vst3","*.component","*.clap","*.app"], bundles:["*.vst3","*.component","*.app"]},
      {name:($p+"-macos-installer"),   required:true,  globs:["*.pkg","*.dmg"]},
      {name:($p+"-aax-windows"),       required:false, globs:["*.aaxplugin"]},
      {name:($p+"-aax-macos"),         required:false, globs:["*.aaxplugin"]},
      {name:($p+"-aax-skipped"),       required:true,  globs:["*.txt"]},
      {name:($p+"-logs-windows"),      required:true,  globs:["summary.txt"]},
      {name:($p+"-logs-macos"),        required:true,  globs:["summary.txt"]}
    ]}' > "$manifest"

  local contract_ok=0
  if "$SCRIPT_DIR/verify-artifacts.sh" --manifest "$manifest" --dir "$download_dir" > "$proof_dir/verify.txt" 2>&1; then
    contract_ok=1
  fi
  sed 's/^/    /' "$proof_dir/verify.txt" >&2

  # --- reaper ---------------------------------------------------------------
  local reaper_exit=0
  if [[ "$SKIP_REAPER" -eq 0 ]]; then
    "$SCRIPT_DIR/reaper.sh" --work-dir "$WORK_DIR" > "$proof_dir/reaper.txt" 2>&1
    reaper_exit=$?
    log "run $attempt: reaper exit=$reaper_exit" >&2
    sed 's/^/    /' "$proof_dir/reaper.txt" >&2
  fi

  # --- leftovers ------------------------------------------------------------
  local leftover_containers=0 leftover_vms=0
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    leftover_containers="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -c '^forge-' || true)"
    docker ps -a > "$proof_dir/docker-ps.txt" 2>&1
  fi
  if command -v tart >/dev/null 2>&1; then
    leftover_vms="$(tart list --quiet 2>/dev/null | grep -c '^forge-' || true)"
    tart list > "$proof_dir/tart-list.txt" 2>&1
  fi
  log "run $attempt: leftover containers=$leftover_containers vm clones=$leftover_vms" >&2

  # --- verdict --------------------------------------------------------------
  local green=1
  [[ "$conclusion" == "success" ]]   || { log "run $attempt: NOT GREEN — conclusion is $conclusion" >&2; green=0; }
  [[ -z "$bad_runners" ]]            || { log "run $attempt: NOT GREEN — these jobs did not run on a forge-* runner: $bad_runners" >&2; green=0; }
  [[ "$contract_ok" -eq 1 ]]         || { log "run $attempt: NOT GREEN — the artifact contract failed" >&2; green=0; }
  [[ "$reaper_exit" -eq 0 ]]         || { log "run $attempt: NOT GREEN — reaper exit $reaper_exit" >&2; green=0; }
  [[ "$leftover_containers" -eq 0 ]] || { log "run $attempt: NOT GREEN — $leftover_containers leftover container(s)" >&2; green=0; }
  [[ "$leftover_vms" -eq 0 ]]        || { log "run $attempt: NOT GREEN — $leftover_vms leftover VM clone(s)" >&2; green=0; }

  jq -n --argjson runId "$run_id" --arg conclusion "$conclusion" \
        --argjson duration "$duration" --argjson green "$green" \
        --argjson reaper "$reaper_exit" --arg badRunners "$bad_runners" \
        --argjson containers "$leftover_containers" --argjson vms "$leftover_vms" \
        '{runId:$runId, conclusion:$conclusion, durationSeconds:$duration, green:($green==1),
          reaperExitCode:$reaper, jobsNotOnForgeRunners:$badRunners,
          leftoverContainers:$containers, leftoverVmClones:$vms}' > "$proof_dir/result.json"

  printf '%s' "$run_id"
  [[ "$green" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# Stage C: `--runs` CONSECUTIVE green runs. Any failure restarts the count.
# ---------------------------------------------------------------------------
log "target: $RUNS consecutive green runs of $WORKFLOW in $REPO"
log "proof bundles: $PROOF_ROOT"
log "nothing is pre-warmed between runs — the caches have to warm themselves"

consecutive=0
attempt=0
declare -a GREEN_RUN_IDS=()

while (( consecutive < RUNS )); do
  attempt=$(( attempt + 1 ))
  if (( attempt > RUNS * 3 )); then
    log "giving up after $attempt attempts without $RUNS consecutive green runs"
    exit 1
  fi

  if run_id="$(run_once "$attempt")"; then
    consecutive=$(( consecutive + 1 ))
    GREEN_RUN_IDS+=("$run_id")
    log "GREEN ($consecutive/$RUNS) — run $run_id"
  else
    log "NOT GREEN — restarting the count from zero (2 of 3 is a failure, not a pass)"
    consecutive=0
    GREEN_RUN_IDS=()
  fi
done

log "achieved $RUNS consecutive green runs: ${GREEN_RUN_IDS[*]}"
log "durations (run 2 and 3 must be meaningfully faster than run 1, or the caching is broken):"
for run_id in "${GREEN_RUN_IDS[@]}"; do
  duration="$(jq -r '.durationSeconds' "$PROOF_ROOT/$run_id/result.json")"
  printf '    run %-12s %6ss\n' "$run_id" "$duration"
done

log "render the evidence table with: scripts/e2e-report.sh --proof-dir $PROOF_ROOT"
exit 0
