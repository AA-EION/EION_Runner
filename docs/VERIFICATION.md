# Verification

Assertions in code are not proof. This document records what has actually been **run**,
on which runners, producing which artifacts, at which byte sizes — and it names, just as
plainly, what has **not** been run and why.

> **Status of this document:** the evidence table below is filled in from real workflow
> runs. Any stage that has not been executed says so explicitly and is not counted as
> passing. A stage with no run ID is a stage that did not happen.
>
> **Stage A is green.** Stages B–E require the user's physical Windows PC and Apple
> Silicon Mac and have not been executed; see "What could not be verified" at the
> bottom, which names each one and why.

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

### Stage A — the artifact contract on GitHub-hosted runners

| Stage | Run ID | Runner names | Conclusion | Duration | Reaper | Leftovers |
|---|---|---|---|---|---|---|
| **A** | [34513859729](https://github.com/AA-EION/EION_Runner/actions/runs/34513859729) | `GitHub Actions 1000001656` (windows-2022), `…657` (macos-14), `…658` / `…660` (ubuntu-24.04) | **success** | 666 s | n/a — hosted runners are destroyed by GitHub | n/a |

Per-job timings for that run:

```
build-windows      success     654s
build-macos        success     323s
aax-marker         success       5s
verify-artifacts   success       6s
```

**Artifacts produced (all 8, none empty):**

| Artifact | Bytes |
|---|---|
| `Canary-macos-installer` | 48,723,597 |
| `Canary-macos-universal` | 33,735,600 |
| `Canary-windows-arm64` | 16,193,617 |
| `Canary-windows-x64` | 16,043,627 |
| `Canary-windows-installer` | 4,841,229 |
| `Canary-logs-windows` | 13,410 |
| `Canary-logs-macos` | 8,729 |
| `Canary-aax-skipped` | 269 |

**Downloaded artifact tree** (largest first, abridged):

```
97191936  Canary-macos-universal/macos-bundles.tar
42275862  Canary-windows-arm64/Canary_SharedCode.lib
38673368  Canary-windows-x64/Canary_SharedCode.lib
24599427  Canary-macos-installer/Canary-1.0.0-macos.dmg
24229067  Canary-macos-installer/Canary-1.0.0-macos.pkg
 7428096  Canary-windows-arm64/Standalone/Canary.exe
 7170560  Canary-windows-x64/Standalone/Canary.exe
 6428672  Canary-windows-arm64/VST3/Canary.vst3/Contents/arm64-win/Canary.vst3
 6182400  Canary-windows-arm64/CLAP/Canary.clap
 6133248  Canary-windows-x64/VST3/Canary.vst3/Contents/x86_64-win/Canary.vst3
 5878784  Canary-windows-x64/CLAP/Canary.clap
 5392840  Canary-windows-installer/Canary-1.0.0-windows-x64.exe
```

Windows total 125,576,126 bytes across 3 artifacts; macOS total 146,020,430 bytes across
2 artifacts. **Both platforms produced non-empty artifacts.**

**The ARM64 output really is ARM64.** The path
`Canary-windows-arm64/VST3/Canary.vst3/Contents/arm64-win/Canary.vst3` is JUCE's ARM64
bundle layout, and the workflow additionally reads the PE header and requires machine
`0xAA64` — a cross-compile that silently emitted x64 would pass every other check in the
run, so this is asserted rather than assumed.

**The macOS output really is universal2.** `lipo` output captured on the runner:

```
VST3/Canary.vst3/Contents/MacOS/Canary        are: x86_64 arm64
Standalone/Canary.app/Contents/MacOS/Canary   are: x86_64 arm64
CLAP/Canary.clap/Contents/MacOS/Canary        are: x86_64 arm64
AU/Canary.component/Contents/MacOS/Canary     are: x86_64 arm64
```

**Independently re-verified after download.** The same `verify-artifacts.sh` was re-run
locally against the downloaded tree, untarring the macOS bundles and asserting
`Contents/MacOS/` and `Contents/Info.plist` survived:

```
ARTIFACT                           PRESENT           BYTES   FILES  VERDICT
Canary-windows-x64                 yes            57862802       9  pass
Canary-windows-arm64               yes            62320484       8  pass
Canary-windows-installer           yes             5392840       1  pass
Canary-macos-universal             yes            97191936       1  pass
Canary-macos-installer             yes            48828494       2  pass
Canary-aax-windows                 no                    0       0  skip
Canary-aax-macos                   no                    0       0  skip
Canary-aax-skipped                 yes                 171       1  pass
Canary-logs-windows                yes               56198       8  pass
Canary-logs-macos                  yes               43795       7  pass

ARTIFACT CONTRACT SATISFIED
```

`Canary-aax-windows` and `Canary-aax-macos` are legitimately absent: the canary has no
AAX target, and the run emits `Canary-aax-skipped` naming that reason, so the artifact
set is short by design and never silently.

**It took three attempts to get here, and each failure was a real defect:**

1. `windows-latest` no longer means Server 2022 — it resolves to Server 2025 with Visual
   Studio 2026, so the `Visual Studio 17 2022` generator found nothing. Pinned to
   `windows-2022`.
2. On macOS every plugin format is a bundle *directory*, so testing the `.clap` path with
   `-f` could never succeed. The check now walks every `Contents/MacOS/` binary.
3. Sharing `FETCHCONTENT_BASE_DIR` between the x64 and ARM64 configures collided on
   FetchContent's *sub-build* cache, which records a generator platform.

That is exactly what Stage A is for: each of those would have been attributed to the
self-hosted runners had it been discovered in Stage B.


### Stage F — the hosted-runner fallback (§18.8)

The escape hatch for the day a laptop is offline. An untested fallback is not a
fallback, so it was actually dispatched.

| Stage | Run ID | Runner names | Conclusion | Duration | Notes |
|---|---|---|---|---|---|
| **F** | [34517038256](https://github.com/AA-EION/EION_Runner/actions/runs/34517038256) | `GitHub Actions 1000001661` / `…662` (hosted) | **success** | 477 s | `use_hosted_runners: true` |

This run used the **emitted build workflow** — `templates/workflow-build.yml.tmpl`
rendered for the canary — not the self-test workflow, so it also serves as the
P9 gate. Its `run-name` reads `Canary stage-f-hosted-fallback-0001 [hosted
fallback]`, confirming the `use_hosted_runners` flip took effect.

Artifacts, all 8 present and non-empty:

```
Canary-macos-installer       48723783
Canary-macos-universal       33735624
Canary-windows-arm64         16193591
Canary-windows-x64           16043643
Canary-windows-installer      4840972
Canary-logs-windows             13427
Canary-logs-macos                8687
Canary-aax-skipped                285
```

Job outcomes, including the reusable signing workflow:

```
build-windows                            success
build-macos                              success
sign-aax / sign-aax (cloud passthrough)  success
sign-aax / sign-aax (macOS iLok)         skipped
sign-aax / sign-aax (windows iLok)       skipped
verify-artifacts                         success
```

The two iLok jobs correctly **skipped** rather than hanging: they are gated on
`signing_mode` and their `runs-on` is never flipped to a hosted runner, because
a hosted runner has no dongle and producing an unsigned artifact under a signed
name would be worse than failing.

The run was located by matching the unique `run_name_tag` echoed into
`run-name`, never by taking "the newest run".

The dispatched workflow was added to `.github/workflows/` only for the duration
of this test and removed afterwards, so the repository tree matches the
specified layout. It is reproducible by rendering
`templates/workflow-build.yml.tmpl` and dispatching the result.

<!-- EVIDENCE-TABLE-END -->

## What could not be verified, and why

<!-- LIMITATIONS-START -->
_Not yet populated._
<!-- LIMITATIONS-END -->
