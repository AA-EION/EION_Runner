# Architecture

## The shape of the thing

Runner Forge is a **control plane**, not a build system. It owns the lifecycle of
short-lived GitHub Actions runners and the disk they consume. The actual building is
done by ordinary GitHub Actions workflows that Runner Forge *emits* for you and that
live in your project repository.

```
        your repo (RecRoll)                 Runner Forge (this product)
  ┌──────────────────────────────┐     ┌──────────────────────────────────┐
  │ .github/workflows/build.yml  │     │  GUI (WPF / SwiftUI)             │
  │   runs-on: [self-hosted,     │     │    ├─ PreflightService           │
  │             windows, x64,    │     │    ├─ SecretStore  (OS keystore) │
  │             container, forge]│     │    ├─ GitHubAppService (JWT→JIT) │
  └──────────────┬───────────────┘     │    ├─ RunnerSupervisor           │
                 │                     │    ├─ ReaperService              │
     GitHub dispatches the job         │    ├─ SweeperService             │
                 │                     │    └─ GitHubActionsService       │
                 ▼                     └────────────┬─────────────────────┘
      ┌────────────────────┐                        │ starts / destroys
      │ ephemeral runner   │◀───────────────────────┘
      │ (container / VM)   │  one job, then it dies
      └────────────────────┘
```

The GUI never builds anything and never holds a compiler. It mints credentials, starts
containers, watches them, and cleans up after them.

## Why ephemeral + JIT, and not a persistent runner

A persistent self-hosted runner accumulates state: leftover `build/` trees, a poisoned
CMake cache, a half-written `FetchContent` clone, a `MSBuild.exe` still holding a file
lock. Worse, it holds a **long-lived registration token** on disk, which is a standing
credential on your repository.

Runner Forge does the opposite:

1. Sign a JWT with the GitHub App private key (RS256, `iat` −60s, `exp` +9 min).
2. `POST /app/installations/{id}/access_tokens` → an installation token, cached 50 min.
3. `POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig` → a base64 blob that
   *is* the runner's entire configuration, valid for exactly one job.
4. Start the container and hand it the blob **on stdin or through a RAM-backed env
   file** — never on the command line, where it would be visible in the process list.
5. `./run.sh --jitconfig <blob>` — there is no `config.sh` step. With a JIT config there
   is nothing to configure.
6. The job runs. The runner unregisters itself and exits. The container is destroyed.

If a runner never starts a second job, none of the accumulated-state failure modes can
happen, and there is no credential left on disk to steal.

## State and crash recovery

`RunnerSupervisor` keeps `{runnerName, classId, containerId|pid, startedAt}` both in
memory and in `paths.workDir/state.json`, written before the process is launched. On
startup the supervisor reads that file and, for every entry that is not alive:

- reaps the container or process,
- calls `DELETE /repos/{owner}/{repo}/actions/runners/{id}` for any offline `forge-*`
  registration left dangling on GitHub.

That way a hard power cut leaves nothing behind but a stale file that the next launch
cleans up.

## Backoff

Three non-zero exits from the same class within five minutes stops the class, marks the
card `Error`, and surfaces the last 50 log lines. A runner class that is broken — bad
image, wrong labels, revoked App key — must not hot-loop against the GitHub API.

## The two janitors

They are deliberately separate because they answer different questions.

**The Reaper** (`scripts/reaper.ps1`, `scripts/reaper.sh`) answers *"is anything still
running that shouldn't be?"*. It runs on container exit, on job completion, on app
close, and on a 30-second watchdog. It hunts for named processes (`Runner.Listener`,
`MSBuild.exe`, `cl.exe`, `xcodebuild`, `wraptool`, …), containers stuck in `running`
after their job ended, Tart VMs with no claimed job, and leftover `runnerforge-ci-*`
keychains. Exit codes are part of its contract: `0` clean, `10` strays found and
killed, `20` strays survived. On `20` the GUI shows a red banner and refuses to start
new runners until acknowledged.

**The Sweeper** (`scripts/sweeper.ps1`, `scripts/sweeper.sh`) answers *"what can I
delete without making the next run slow?"*. It works from two explicit lists — never a
heuristic — because erring in either direction is a bug:

- KEEP: tagged base images, Tart images, the `forge-fetchcontent` / `forge-sccache` /
  `forge-ccache` / `forge-aax-sdk` volumes, `forge.json`, keystore entries.
- PURGE: exited/created/dead containers, `forge-*` Tart *clones* (never images), job
  workspaces, dangling images and build cache, temp download dirs, ephemeral
  keychains, old logs, old proof bundles.

`docker system prune -a` is **never** used. It would delete the KEEP images and defeat
the entire design. Targeted `docker image prune -f` and `docker builder prune -f` only.

## Secret handling

Secrets are stored under these exact key names:

`githubAppPrivateKey`, `paceAccount`, `pacePassword`, `azureClientId`,
`azureClientSecret`, `azureTenantId`, `appleDevIdP12`, `appleDevIdP12Password`,
`appleAscIssuerId`, `appleAscKeyId`, `appleAscPrivateKey`.

- **Windows** — Credential Manager via P/Invoke (`CredWriteW` / `CredReadW` /
  `CredDeleteW`), target `RunnerForge:{keyName}`, `CRED_TYPE_GENERIC`,
  `CRED_PERSIST_LOCAL_MACHINE`.
- **macOS** — Keychain Services (`SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate`
  / `SecItemDelete`), `kSecClassGenericPassword`, service `com.runnerforge.secrets`,
  account = key name.

Injection into a container writes an env file to a RAM-backed path, passes
`--env-file`, then overwrites the file with random bytes and deletes it once the
container reports started. Into a Tart VM, secrets go over `tart exec` stdin. Never
`--build-arg`, never inline in compose, never in argv, never into an image layer.

Every log line passes `LogBus`'s redactor, which replaces known secret values with
`***` before the line reaches the UI, a file, or the clipboard.

## Why Windows ARM64 is cross-compiled

There is no supported Windows ARM64 container story, and emulation is slow and subtly
wrong for a plugin that ships DSP. Instead the amd64 Windows container carries the MSVC
ARM64 toolset (`Microsoft.VisualStudio.Component.VC.Tools.ARM64`), and the build
configures a second time with `-A ARM64`, reusing the JUCE source tree that
`FetchContent` already populated on the persistent cache volume. Same container, same
sources, two output trees.

## Why macOS builds never touch Windows

macOS cannot be virtualized on non-Apple hardware. Not in Docker, not in QEMU, not in
KVM, not in WSL. It is both technically impossible on this hardware and a violation of
Apple's software licence agreement. `mac-build` therefore exists only on the Mac, as a
Tart VM clone of an immutable base image, deleted in a `trap EXIT` whether the job
succeeds or fails.

## Configuration contract

One file, `forge.json`, read and written by both apps and consumed by every script:

- Windows: `%ProgramData%\RunnerForge\forge.json`
- macOS: `~/Library/Application Support/RunnerForge/forge.json`

It is validated on load against `config/forge.schema.json` (JSON Schema draft 2020-12).
A validation failure is reported as readable text naming the offending JSON pointer,
not a stack trace. **No secret may ever appear in this file** — only non-secret
identifiers such as app ids, installation ids, certificate common names, and Azure
endpoint names.

## Version pinning

`versions.toml` is the single source of truth. It carries:

- `[runner]`, `[windows_image]`, `[linux_image]`, `[macos_image]`, `[actions]`,
  `[host_minimums]`, `[project]` — the pinned versions,
- `[checksums]` — the SHA-256 of every binary the image builds download,
- `[urls]` — the exact download URLs, templated on `{v}`.

An image build that encounters a missing checksum entry **aborts**. It does not skip
verification, and it does not fall back to `latest`.
