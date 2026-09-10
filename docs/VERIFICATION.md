# Verification

Assertions in code are not proof. This document records what has actually been **run**,
on which runners, producing which artifacts, at which byte sizes — and it names, just as
plainly, what has **not** been run and why.

> **Status of this document:** the evidence table below is filled in from real workflow
> runs. Any stage that has not been executed says so explicitly and is not counted as
> passing. A stage with no run ID is a stage that did not happen.

## The definition of green

A **green run** is a workflow run where:

1. the run's `conclusion` is `success`, **and**
2. every artifact expected by the [§15.1 contract](#the-artifact-contract) exists, is
   non-empty, and passes its content assertion in the `verify-artifacts` job.

A run whose build jobs pass but whose `verify-artifacts` job fails is **not** green. That
job is the gate, not a report.

## The artifact contract

Every run of a build workflow — success or failure, hosted or self-hosted — must produce
a downloadable Windows artifact and a downloadable macOS artifact.

| Artifact | Produced by | Must contain (at minimum) |
|---|---|---|
| `{p}-windows-x64` | `win-build` | `*.vst3` bundle, `*.clap`, `*.exe` standalone |
| `{p}-windows-arm64` | `win-build` | `*.vst3`, `*.clap`, `*.exe` standalone |
| `{p}-windows-installer` | `win-build` | exactly one `*.exe` Inno Setup installer |
| `{p}-macos-universal` | `mac-build` | `*.vst3`, `*.component`, `*.clap`, `*.app` |
| `{p}-macos-installer` | `mac-build` | one `*.pkg` and one `*.dmg` |
| `{p}-aax-windows` | signing job | `*.aaxplugin` bundle |
| `{p}-aax-macos` | signing job | `*.aaxplugin` bundle |
| `{p}-logs-{os}` | every job | build logs, CMake cache, test output — uploaded on failure too |

Upload rules, applied without exception:

- `actions/upload-artifact@v4`
- `if: always()` on every upload — a failing test must not destroy the diagnostics
- **`if-no-files-found: error`** on every upload — never `ignore`, never `warn`
- unique artifact names within a run (v4 does not merge; it errors)
- `retention-days: 14`, `compression-level: 6`
- macOS bundles are `tar`red before upload and untarred before assertion, because the
  upload action flattens symlinks and would corrupt a `.component` or `.vst3` bundle

`scripts/verify-artifacts.sh` implements the assertions and prints a summary table:
artifact | present | bytes | files | verdict. It exits non-zero listing every missing or
empty artifact by name.

## The stages

| Stage | What it proves | Where it runs |
|---|---|---|
| **A** | the *workflow* is correct | GitHub-hosted runners |
| **B** | the *runners* are correct | Runner Forge self-hosted runners |
| **C** | the setup is *stable* and caches actually warm | self-hosted, `requiredGreenRuns` consecutive |
| **D** | a user can prove all this from the GUI | in-app self-test button |
| **E** | it works on the *real* repository | self-hosted, against RecRoll |
| **F** | the hosted fallback still works | GitHub-hosted, `use_hosted_runners: true` |

Stage A comes first on purpose. It separates "is my YAML correct?" from "is my runner
correct?" — and YAML is far cheaper to iterate on. If Stage A is red, the runners are
not the problem.

Stage B additionally requires proving the jobs *landed on* Runner Forge runners. A job
that silently ran on a hosted runner proves nothing, so every Stage B row records the
`runner_name` of each job, which must match `forge-*`.

## Reproducing every row

```bash
# Stage A — hosted runners, canary project
gh workflow run selftest-hosted.yml -f run_name_tag="$(uuidgen)" -f project_name=Canary
gh run list --workflow selftest-hosted.yml --limit 1
gh run watch <run-id>
gh run download <run-id> --dir proof-a
find proof-a -type f -printf '%s\t%p\n' | sort -rn | head -40

# Stage B — self-hosted runners, same contract
gh workflow run selftest-selfhosted.yml -f run_name_tag="$(uuidgen)" -f project_name=Canary
gh run view <run-id> --json jobs \
  | jq -r '.jobs[] | "\(.name)\t\(.runner_name)\t\(.conclusion)"'   # runner_name must be forge-*
gh run download <run-id> --dir proof-b
find proof-b -type f -printf '%s\t%p\n' | sort -rn | head -40

# after the run, on the runner host
scripts/reaper.sh --work-dir "$WORKDIR"; echo "reaper exit=$?"   # must be 0
docker ps -a
tart list

# Stages B and C automated end to end
scripts/e2e-verify.sh --repo <owner>/<repo> --runs 3 --workflow selftest-selfhosted.yml
scripts/e2e-report.sh --proof-dir "$WORKDIR/proof"
```

`scripts/e2e-verify.sh` is the driver for Stages B and C; `scripts/e2e-report.sh` renders
the evidence table below from the downloaded proof bundles.

## Cache warming

Stage C records wall-clock duration per run. Runs 2 and 3 must be meaningfully faster
than run 1 — that is the observable proof that the `forge-fetchcontent`, `forge-sccache`
and `forge-ccache` volumes are actually being reused rather than re-cloning JUCE on
every build. If they are not faster, the caching is broken, and no amount of passing
tests makes up for it.

Between runs, nothing is pre-warmed by hand. The caches have to warm themselves.

## Evidence

<!-- EVIDENCE-TABLE-START -->
_Not yet populated. See "Status" at the top of this document._
<!-- EVIDENCE-TABLE-END -->

## What could not be verified, and why

<!-- LIMITATIONS-START -->
_Not yet populated._
<!-- LIMITATIONS-END -->
