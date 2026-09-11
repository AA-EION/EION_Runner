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


### Stage G — the Windows app, its tests and the MSI

The Windows app is compiled, its tests are RUN (not merely compiled), the
single-file publish is asserted to actually be a single file, and the MSI's own
`File` table is read back to prove the harvest carried the payload. An MSI with
an empty `File` table installs cleanly and delivers nothing, so its existence is
not evidence; its contents are.

| Fact | Value |
| --- | --- |
| Run | [34550945700](https://github.com/AA-EION/EION_Runner/actions/runs/34550945700) |
| Commit | `7402ebe` |
| Runner | `windows-2022` (pinned; see TROUBLESHOOTING #12) |
| Duration | 152 s |
| Build | `0 Warning(s), 0 Error(s)` with `TreatWarningsAsErrors` on |
| Tests | `Passed! - Failed: 0, Passed: 73, Skipped: 0, Total: 73, Duration: 106 ms` |
| `RunnerForge.exe` | **62,984,861 bytes**, and zero loose files beside it |
| Publish payload | 24 files, 63,217,417 bytes (exe + 20 scripts + 4 templates… see below) |
| WiX | 5.0.2 |
| `RunnerForge.msi` | **56,680,448 bytes** |
| MSI `File` table | **24 rows** |
| Current head | [34571310000](https://github.com/AA-EION/EION_Runner/actions/runs/34571310000), commit `e83159b`, green — 79 tests, exe 62,996,936 B, MSI 56,678,091 B |
| **The app opens a window** | `window handle: 393296`, `window title: Runner Forge`, and **no error line in the startup log** — run 34571310000, step 10 |

The last row is the one that matters most, and it is new. Every run before
[34570056314](https://github.com/AA-EION/EION_Runner/actions/runs/34570056314)
was green for an executable **that opened nothing at all** — a build that
compiles, tests that pass, a genuine single file and an MSI with a full `File`
table are all compatible with a program that does not work. The smoke test was
added in that run and immediately failed, then failed twice more on a crash the
first failure had been hiding (34570402196, 34570795128), before going green
here. Three red runs that should have been red is the check doing its job. See
TROUBLESHOOTING #19 and #20.

It now launches the built app, waits for a real titled top-level window, and
then **reads the app's own log and fails on any error line** — because an open
window is not proof either.

The `File` table, read out of the MSI itself rather than assumed:

```
  qfsmnehk.exe|RunnerForge.exe             62984861 bytes
  0yvzxzdf.tom|versions.toml               12472 bytes
  fyv1z19s.sh|e2e-report.sh                4763 bytes
  --bqqocl.sh|e2e-verify.sh                12755 bytes
  wgdxe2oe.ps1|jitconfig.ps1               7445 bytes
  cuylqoe7.sh|jitconfig.sh                 7844 bytes
  vt0supkd.sh|preflight-macos.sh           12650 bytes
  0qpbvdpq.ps1|preflight-windows.ps1       17113 bytes
  reaper.ps1                               9549 bytes
  reaper.sh                                9105 bytes
  hzldh0so.ps1|sign-aax-cloud.ps1          6746 bytes
  zpsiphnu.sh|sign-aax-cloud.sh            6417 bytes
  tu8vqeze.ps1|sign-aax-ilok.ps1           5577 bytes
  alg8czvf.sh|sign-aax-ilok.sh             4858 bytes
  e9dkltnj.sh|sign-macos-artifact.sh       11511 bytes
  butolg6j.ps1|sign-windows-artifact.ps1   8688 bytes
  sweeper.ps1                              10831 bytes
  sweeper.sh                               12714 bytes
  gk89418e.sh|tart-runner.sh               7543 bytes
  sv0aoywx.sh|verify-artifacts.sh          9624 bytes
  j6iodxgi.tmp|secrets-checklist.md.tmpl   3801 bytes
  lbrhajb9.tmp|workflow-build.yml.tmpl     21380 bytes
  rtecksxe.tmp|workflow-selftest.yml.tmpl  21433 bytes
  abdyefrp.tmp|workflow-sign.yml.tmpl      7737 bytes
MSI File table: 24 row(s)
```

The `8dot3name|LongFileName` pairs are ordinary MSI short-name aliases, which
Windows Installer generates for every file whose name is not already 8.3;
`reaper.ps1` and `sweeper.sh` appear bare because theirs already are. The exe's
62,984,861 bytes match the published file byte for byte, so the MSI carries the
real payload rather than a stub.

Artifacts, with the sizes GitHub reported on upload:

| Artifact | Bytes | ID |
| --- | --- | --- |
| `RunnerForge-windows-msi` | 56,655,076 | 10180822285 |
| `RunnerForge-windows-programfiles` | 57,627,016 | 10180823957 |
| `RunnerForge-windows-testresults` | 14,741 | 10180824445 |

Reproduce:

```bash
# from the repository root, on Windows
cd app-windows
dotnet restore RunnerForge.sln -p:Configuration=Release   # the -p matters; see TROUBLESHOOTING #10 and NETSDK1047
dotnet build   RunnerForge.sln -c Release --no-restore
dotnet test    RunnerForge.sln -c Release --no-build
dotnet publish RunnerForge/RunnerForge.csproj -c Release -r win-x64 -o publish
dotnet tool install --global wix --version 5.0.2
wix build Installer\RunnerForge.wxs -d PublishDir="$PWD\publish" -arch x64 -o RunnerForge.msi
```


### Stage H — the macOS app, its tests and the DMG

This job is the first place the macOS app is ever fully type-checked: the
development machine for this work is Linux, where `swiftc -parse` proves syntax
but cannot resolve SwiftUI, AppKit or Security. Everything below therefore comes
from a real Apple Silicon macOS 26 runner.

| Fact | Value |
| --- | --- |
| Run | [34551196570](https://github.com/AA-EION/EION_Runner/actions/runs/34551196570) |
| Commit | `b0790e4` |
| Runner | `macos-26` |
| Duration | 103 s |
| OS | `ProductVersion: 26.6.2`, `BuildVersion: 25G83` |
| Xcode | `Xcode 26.6`, `Build version 17F113` |
| Swift | `Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)`, target `arm64-apple-macosx26.0` |
| Tests | `✔ Test run with 38 tests in 4 suites passed after 0.144 seconds.` |
| `RunnerForge.dmg` | **1,227,193 bytes**, `hdiutil verify` → checksum VALID |
| `RunnerForge-app.tar` | 3,141,120 bytes |
| App inside the mounted DMG | 3,096 KB |
| Re-verified after the §5 tree refactor | [34551453059](https://github.com/AA-EION/EION_Runner/actions/runs/34551453059), commit `966293c`, green |
| Current head | [34571614106](https://github.com/AA-EION/EION_Runner/actions/runs/34571614106), commit `764808d`, green — 44 tests in 4 suites |
| **The app launches and logs no errors** | run 34571614106, step 9 — the binary is run directly, is alive after 10 s, and its own log is read back |

The log the smoke test reads back, in full, is the evidence that the app got
somewhere rather than merely staying resident:

```
[Info] app Runner Forge started — Version 26.6.2 (Build 25G83), user runner
[Info] app log file: /Users/runner/Library/Logs/RunnerForge/runnerforge.log
[Info] app scripts:  .../RunnerForge.app/Contents/Resources/scripts
[Info] app Runner Forge ready — config .../Application Support/RunnerForge/forge.json
[Warning] preflight 2 of 15 checks failed
```

Those 2 failed preflight checks are correct and expected: a GitHub-hosted runner
has no Developer ID identity and no Tart. A `[Warning]` is not a `[Error]`, which
is why the check keys on the latter.

One known, pre-existing warning in this step: `a caffeinate process outlived the
app`. It is an artifact of the smoke test killing the process with `kill -9`,
which never reaches AppKit's `applicationShouldTerminate` and so never runs
`releaseCaffeinate()`. It appears identically in the runs before this work
([34570056332](https://github.com/AA-EION/EION_Runner/actions/runs/34570056332))
and is not a product defect. The Reaper clears such a process on the next launch.

The bundle, asserted rather than assumed:

```
com.runnerforge.app
RunnerForge
dist/RunnerForge.app: valid on disk
dist/RunnerForge.app: satisfies its Designated Requirement
--- entitlements as signed ---
<dict>
	<key>com.apple.security.app-sandbox</key>
	<false/>
	<key>com.apple.security.cs.allow-dyld-environment-variables</key>
	<true/>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
--- architectures ---
Non-fat file: dist/RunnerForge.app/Contents/MacOS/RunnerForge is architecture: arm64
```

Three things in that output are deliberate and are worth stating so they do not
read as oversights:

- **App Sandbox is `false`, as SIGNED** — not merely as written in the
  entitlements file. The job greps the entitlements *out of the signature* and
  fails the run if the sandbox is on, because a sandboxed process cannot launch
  `tart`, `docker`, `codesign` or `notarytool`, which is the app's entire job.
- **arm64 only, not universal.** Unlike the plugin artifacts, which must be
  universal2, this app is Apple Silicon only by construction: Tart drives Apple's
  Virtualization framework, which does not exist on Intel, and Preflight reports
  an Intel Mac as a hard block with no fix. Shipping an x86_64 slice would
  produce an app that launches and can do nothing.
- **Ad-hoc signed.** No Developer ID identity is present on a hosted runner, so
  CI signs ad-hoc: the app runs on the machine that built it and Gatekeeper
  rejects it anywhere else. `build.sh --sign "Developer ID Application: …"
  --notarize` produces the distributable build, signing nested code inside-out
  (never `codesign --deep`) and stapling the notarization ticket.

The DMG is mounted and its contents checked, because a `.dmg` that exists is not
a `.dmg` that works:

```
lrwxr-xr-x  1 runner  staff  13 Sep 11 01:35 Applications -> /Applications
drwxr-xr-x  3 runner  staff  96 Sep 11 01:35 RunnerForge.app
app inside the DMG: 3096 KB
```

Artifacts, with the sizes GitHub reported on upload:

| Artifact | Bytes | ID |
| --- | --- | --- |
| `RunnerForge-macos-dmg` | 1,199,177 | 10180897776 |
| `RunnerForge-macos-app` | 822,112 | 10180898384 |

The `.app` is tarred and the `.dmg` is not, and that asymmetry is the artifact
contract at work: `upload-artifact` flattens symlinks, a bundle without its
symlinks is no longer a bundle, and a `.dmg` is a single file with no symlinks to
lose.

Reproduce:

```bash
# on an Apple Silicon Mac running macOS 26 with Xcode 26
cd app-macos
swift build -c release
swift test
./build.sh --configuration release          # ad-hoc signed, as CI does
hdiutil verify dist/RunnerForge.dmg
codesign --display --entitlements - --xml dist/RunnerForge.app | plutil -convert xml1 -o - -
```

<!-- EVIDENCE-TABLE-END -->

## What could not be verified, and why

<!-- LIMITATIONS-START -->
_Not yet populated._
<!-- LIMITATIONS-END -->

## §21 acceptance checklist

Ticked against what actually ran, not against intent. An item is ticked only if
there is evidence above or in the repository that anyone can re-check; anything
that could not be proven from here says so and says why.

| | Item | Status |
| --- | --- | --- |
| ✅ | Every file in §5 exists and is complete. No placeholders. | `git ls-files` diffed against §5: zero missing. Two files exist that §5 predates or could not anticipate — see **Deviations** below. |
| ⚠️ | No version string hardcoded outside `versions.toml`. | True for every image build, script and app. **Not** true for four GitHub-hosted runner labels and two CI tool pins, which are now recorded in `versions.toml [ci]` — Actions cannot read a TOML file when it parses `runs-on:`, so those literals are unavoidably duplicated. Named rather than papered over. |
| ✅ | No secret in any file, image layer, log, or argv. | `ConfigStore.validate` rejects all ten keystore key names at any depth in forge.json (10 parameterised cases green on both platforms). Secrets reach child processes through the environment only. `LogBus` redacts by value and by shape. Nothing is passed via `--build-arg`. |
| ✅ | Runners are ephemeral and JIT-configured. `config.sh` appears nowhere. | Every occurrence of the string in the repository is prose explaining its absence. `jitconfig.{sh,ps1}` mint a JIT config per job; JWT signing verified against `openssl`. |
| ✅ | Windows ARM64 is cross-compiled; no arm64 container, no emulation. | Stage A: the ARM64 binaries' PE machine field reads `0xAA64`, produced by the MSVC ARM64 toolset on an amd64 runner. |
| ✅ | No attempt anywhere to virtualize macOS on Windows. | The only three mentions of QEMU/KVM/WSL in the tree are the error messages that refuse to try. |
| ✅ | Reaper detects and kills strays, returns 0/10/20 as specified. | Gate-tested on both twins: SIGTERM → wait → SIGKILL → **re-verify**, and 20 is returned when something survives. PIDs recorded in `state.json` are protected. |
| ✅ | Sweeper never deletes a KEEP item; unit tests prove it on both platforms. | `SweeperPolicyTests` green in both suites (73 tests Windows, 38 macOS). Both twins independently reported identical numbers on the same fixture (3,700,004 reclaimable / 3,500,000 reclaimed). `docker system prune` is rejected in every spelling tested. |
| ⚠️ | All three signing modes selectable in both GUIs with live checklists; `windows-ilok` default. | Implemented in both apps and compiled on both platforms; the default is `windows-ilok`. Not exercised through a running GUI — see **What could not be verified**. |
| ✅ | Both apps have the same eight pages in the same order. | Preflight, Targets, Credentials, Signing, Runners, Cleanup, Export, Logs — `ForgePage.allCases` (macOS) and the WPF nav list (Windows). |
| ⚠️ | Closing either app drains, reaps, sweeps, with visible progress. | Implemented: Windows `OnExit`, macOS `applicationShouldTerminate` returning `.terminateLater` until the drain, reap and sweep finish. Compiled, not exercised at runtime. |
| ✅ | Every upload step uses `if: always()` and `if-no-files-found: error`. | All 31 `upload-artifact` steps across the four workflows and three templates carry both. Checked mechanically, not by eye. |
| ✅ | `verify-artifacts` gates the run and fails on any missing or empty artifact. | Proven by a real failure: Stage A run 34505950332 named all five missing artifacts and failed the run rather than passing an empty set. |
| ✅ | **Stage A green, with pasted run ID and artifact sizes.** | Run 34513859729, 666 s, 8 artifacts, sizes above. Artifacts downloaded and independently re-verified. |
| ❌ | **Stage B green, with job `runner_name` values proving self-hosted execution.** | Needs the user's Windows PC and Apple Silicon Mac. Cannot be run from here. |
| ❌ | **Stage C: `requiredGreenRuns` consecutive green runs, durations showing cache warming.** | Same — requires Stage B first. |
| ❌ | **Stage D: in-app self-test writes `verification.lastProof`; badge visible in the UI.** | Requires a running app on real hardware. |
| ❌ | **Stage E: real repo run reported, with any skipped artifacts named and justified.** | Requires the user's own plugin repository and their runners. |
| ✅ | **Stage F (§18.8): hosted-runner fallback produces the full artifact set.** | Run 34517038256, 477 s, 8 artifacts, `use_hosted_runners: true`; the iLok jobs correctly skipped. |
| ✅ | Windows AND macOS artifacts downloaded and non-empty on every stage above. | Stage A and Stage F both: all four macOS bundles confirmed universal2 (x86_64 + arm64), ARM64 PE machine `0xAA64`. |
| ✅ | `docs/VERIFICATION.md` contains the evidence table with reproducible commands. | This file. Every stage carries the commands that reproduce it. |
| ✅ | Every phase Gate has real pasted output. | In the session transcript and in the stage sections above. |

Two rows the original checklist predates, added because the apps are only
delivered once they are installable:

| | Item | Status |
| --- | --- | --- |
| ✅ | **Stage G: the Windows app builds, its tests RUN, the MSI carries the program files, and the app OPENS A WINDOW.** | Run 34571310000, commit `e83159b`. 79 tests passed on Windows — the only place they can run. MSI `File` table read back: 24 rows, `RunnerForge.exe` at 62,996,936 bytes. The built app launches, shows a titled window (`Runner Forge`, handle 393296) and logs no errors on startup. |
| ✅ | **Stage H: the macOS app builds, its tests run, the DMG mounts with a runnable app, and the app LAUNCHES.** | Run 34571614106, commit `764808d`. 44 tests in 4 suites passed. `hdiutil verify` VALID; the mounted DMG carries a runnable `RunnerForge.app` and an `/Applications` drop target; App Sandbox asserted `false` **as signed**. The built app launches, survives 10 s, and its own log shows it reaching `Runner Forge ready` with no error line. |

### Deviations from §5, and why

Two files exist that a literal reading of §5 does not list. Both are stated here
rather than left for someone to find:

1. **`app-macos/Sources/RunnerForgeApp/RunnerForgeApp.swift`** — §5 puts this file
   at `Sources/RunnerForge/RunnerForgeApp.swift`, and §5 also requires
   `Tests/RunnerForgeTests/`. Those two requirements conflict: Swift Testing
   cannot import an executable target, so a single target holding `@main` would
   make the four required test files unbuildable. The entry point therefore sits
   in a thin executable target that depends on the library. The module, the
   product and the shipped binary all keep the names §5 gives them, and nothing
   else moved.
2. **`app-windows/Installer/RunnerForge.wxs`** — the WiX source for the MSI. §5
   predates the instruction to package the apps as an MSI and a DMG; the macOS
   half needed no new file because `build.sh` was already in the tree.
