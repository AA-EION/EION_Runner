#!/usr/bin/env bash
#
# e2e-report.sh — render the evidence table from downloaded proof bundles.
#
# Reads the proof bundles e2e-verify.sh wrote and produces the Markdown table
# that docs/VERIFICATION.md carries, plus the artifact listings and the cache
# warming comparison.
#
# It reports what the bundles actually contain. If a stage was never run there
# is no bundle for it, and this script says so rather than inventing a row.
#
set -uo pipefail

PROOF_DIR=""
STAGE="B"
OUTPUT=""

usage() {
  cat >&2 <<'USAGE'
Usage: e2e-report.sh --proof-dir <path> [--stage <letter>] [--output <file.md>]

  --proof-dir  Directory of proof bundles written by e2e-verify.sh
               (one subdirectory per run id).
  --stage      Stage letter for the table's first column. Default B.
  --output     Write the Markdown here instead of stdout.

Exit codes: 0 ok, 2 usage, 3 no proof bundles found.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proof-dir) PROOF_DIR="${2:-}"; shift 2 ;;
    --stage)     STAGE="${2:-B}"; shift 2 ;;
    --output)    OUTPUT="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$PROOF_DIR" ]] || { echo "error: --proof-dir is required" >&2; usage; exit 2; }
[[ -d "$PROOF_DIR" ]] || { echo "error: proof dir does not exist: $PROOF_DIR" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 3; }

bundles=()
while IFS= read -r bundle; do
  [[ -f "$bundle/result.json" ]] && bundles+=("$bundle")
done < <(find "$PROOF_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

if [[ ${#bundles[@]} -eq 0 ]]; then
  echo "error: no proof bundles with a result.json under $PROOF_DIR" >&2
  echo "       Run scripts/e2e-verify.sh first. A stage with no bundle is a stage that did not happen." >&2
  exit 3
fi

emit() { if [[ -n "$OUTPUT" ]]; then printf '%s\n' "$*" >> "$OUTPUT"; else printf '%s\n' "$*"; fi; }

[[ -n "$OUTPUT" ]] && : > "$OUTPUT"

emit "| Stage | Run ID | Runner names | Conclusion | Artifacts (name / bytes) | Duration | Reaper | Leftovers |"
emit "|---|---|---|---|---|---|---|---|"

for bundle in "${bundles[@]}"; do
  run_id="$(jq -r '.runId' "$bundle/result.json")"
  conclusion="$(jq -r '.conclusion' "$bundle/result.json")"
  duration="$(jq -r '.durationSeconds' "$bundle/result.json")"
  reaper="$(jq -r '.reaperExitCode' "$bundle/result.json")"
  containers="$(jq -r '.leftoverContainers' "$bundle/result.json")"
  vms="$(jq -r '.leftoverVmClones' "$bundle/result.json")"
  green="$(jq -r '.green' "$bundle/result.json")"

  runners="unknown"
  if [[ -f "$bundle/jobs.json" ]]; then
    runners="$(jq -r '[.jobs[].runner_name // "unknown"] | unique | join(", ")' "$bundle/jobs.json")"
  fi

  artifacts="none"
  if [[ -f "$bundle/artifacts.json" ]]; then
    artifacts="$(jq -r '[.artifacts[] | "\(.name) / \(.size_in_bytes)"] | join("<br>")' "$bundle/artifacts.json")"
  fi

  leftovers="none"
  [[ "$containers" != "0" || "$vms" != "0" ]] && leftovers="containers: $containers, VM clones: $vms"

  verdict="$conclusion"
  [[ "$green" == "true" ]] || verdict="$conclusion (NOT GREEN)"

  emit "| $STAGE | [$run_id](../../actions/runs/$run_id) | \`$runners\` | **$verdict** | $artifacts | ${duration}s | $reaper | $leftovers |"
done

emit ""
emit "### Cache warming"
emit ""
emit "Runs 2 and onward must be meaningfully faster than run 1. That is the observable"
emit "proof that the persistent cache volumes are being reused rather than JUCE being"
emit "re-cloned every build. If they are not faster, the caching is broken."
emit ""
emit '```'

first_duration=""
index=0
for bundle in "${bundles[@]}"; do
  index=$(( index + 1 ))
  run_id="$(jq -r '.runId' "$bundle/result.json")"
  duration="$(jq -r '.durationSeconds' "$bundle/result.json")"
  if [[ -z "$first_duration" ]]; then
    first_duration="$duration"
    emit "$(printf 'run %-2s %-14s %6ss   (cold)' "$index" "$run_id" "$duration")"
  else
    if [[ "$first_duration" -gt 0 ]]; then
      delta=$(( 100 - (duration * 100 / first_duration) ))
      emit "$(printf 'run %-2s %-14s %6ss   %+d%% vs run 1' "$index" "$run_id" "$duration" "-$delta" | sed 's/+-/-/; s/--/+/')"
    else
      emit "$(printf 'run %-2s %-14s %6ss' "$index" "$run_id" "$duration")"
    fi
  fi
done

emit '```'
emit ""
emit "### Reproducing these rows"
emit ""
emit '```bash'
emit "export GITHUB_TOKEN=<a token with actions read/write>"
emit "scripts/e2e-verify.sh --repo <owner>/<repo> --runs ${#bundles[@]}"
emit "scripts/e2e-report.sh --proof-dir $PROOF_DIR"
emit '```'

[[ -n "$OUTPUT" ]] && echo "wrote $OUTPUT" >&2
exit 0
