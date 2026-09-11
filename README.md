# Runner Forge

Turn a Windows PC and an Apple Silicon Mac into clean, containerized, self-hosted
GitHub Actions runners for audio-plugin CI — without installing a single compiler
on either host.

Runner Forge is **two native desktop applications that are functional twins**:

| | |
|---|---|
| `RunnerForge.exe` | Windows amd64 — .NET 9 + WPF, self-contained single file, no runtime install |
| `RunnerForge.app` | macOS Apple Silicon — Swift 6 + SwiftUI, deployment target macOS 26 (Tahoe) |

It does not live inside the project it builds. You install it once per machine and
point it at one or more GitHub repositories.

---

## Why it exists

Building an audio plugin properly means building it four ways — Windows x64,
Windows ARM64, macOS universal2, and a Linux verification pass — then signing the
result three different ways (Authenticode, Apple Developer ID + notarization, and
Avid AAX via PACE). GitHub-hosted runners can do it, slowly and expensively.
Self-hosted runners can do it fast, but the usual approach leaves a compiler
toolchain smeared across your daily-driver machine and a pile of half-dead runner
processes behind every failed job.

Runner Forge takes the other approach:

- **Nothing is installed on the host.** Compilers live only in container images and
  a Tart VM image. The only host installs are Docker Desktop, Tart, Runner Forge
  itself, and — in iLok mode only — the PACE tools and the iLok driver.
- **Every runner is ephemeral.** One job, then the container or VM clone is
  destroyed. Registration uses a just-in-time config minted from a GitHub App
  private key seconds before the runner starts. There are no long-lived
  registration tokens and no `config.sh` step anywhere in this repository.
- **Nothing is left running.** The Reaper verifies after every job that no compiler,
  runner listener, or orphaned container survived. The Sweeper purges on close,
  keeping only the caches and base images that make the next run fast.
- **Secrets never touch disk.** They live in Windows Credential Manager or the macOS
  Keychain, are injected through a RAM-backed env file or stdin, and are redacted
  by pattern from every log line.

## The eight pages

Both apps present the same eight pages in the same order, so a person who knows one
knows the other:

1. **Preflight** — says exactly what is missing on this machine, and fixes what it can.
2. **Credentials** — secrets collected once, into the OS keystore, never a file.
3. **Targets** — which GitHub repositories the runners serve.
4. **Runners** — start ephemeral runners, watch per-replica status live.
5. **Signing** — pick one of three plugin-signing strategies, with a live checklist.
6. **Export** — writes ready-to-paste GitHub config: workflow YAML plus a secrets checklist.
7. **Logs** — live, filtered, redacted output.
8. **Cleanup** — disk split into KEEP and PURGE, with real byte counts.

## Runner classes

| classId | Host | Isolation | Labels |
|---|---|---|---|
| `win-build` | Windows amd64 | Windows container, Hyper-V isolation | `self-hosted,windows,x64,container,forge` |
| `linux-util` | Windows / WSL2 | Linux container | `self-hosted,linux,x64,container,forge` |
| `mac-build` | macOS Apple Silicon | Tart VM clone | `self-hosted,macos,arm64,tart,forge` |
| `win-ilok` | Windows amd64 | **host process** — no container | `self-hosted,windows,x64,ilok,forge` |
| `mac-ilok` | macOS Apple Silicon | **host process** — no VM | `self-hosted,macos,arm64,ilok,forge` |

The two iLok classes are deliberately not containerized and deliberately have no
compiler: a Windows container cannot see a USB device, so the machine holding the
dongle signs and nothing else. See [docs/SIGNING.md](docs/SIGNING.md).

## What it will not do

- It will **not** run macOS in a VM on Windows. That is impossible on this hardware
  and against Apple's licence. The UI says so and refuses rather than improvising.
- It will **not** pass a USB dongle into a Windows container. Unsupported, full stop.
- It will **not** run on Windows Home. Windows containers need Pro or Enterprise plus
  Hyper-V; preflight blocks with an explanation instead of failing later and vaguely.
- It will **not** emulate ARM64. Windows ARM64 output is cross-compiled with the MSVC
  ARM64 toolset inside an amd64 container.

## Getting started

1. [docs/SETUP-WINDOWS.md](docs/SETUP-WINDOWS.md) — Windows host, Docker Desktop, the
   `win-build` / `linux-util` / `win-ilok` classes.
2. [docs/SETUP-MACOS.md](docs/SETUP-MACOS.md) — Apple Silicon host, Tart, the
   `mac-build` / `mac-ilok` classes.
3. [docs/SIGNING.md](docs/SIGNING.md) — choose one of the three signing modes.
4. [docs/VERIFICATION.md](docs/VERIFICATION.md) — how the end-to-end proof works, what
   has actually been proven, and how to re-run it yourself.
5. [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — the failure modes we hit, and
   what each one actually meant.

## Repository layout

```
versions.toml     single source of truth for every pinned version and checksum
config/           the JSON Schema contract shared by both apps and every script
images/           Windows + Linux container images, macOS Packer/Tart image
compose/          docker-compose definition for the container classes
scripts/          JIT config, reaper, sweeper, preflight, signing, E2E drivers
templates/        the workflow YAML Runner Forge emits for your repository
canary/           a minimal JUCE 8 plugin used to prove the pipeline end to end
app-windows/      RunnerForge.exe  (.NET 9 + WPF), with the WiX source for the MSI
app-macos/        RunnerForge.app  (Swift 6 + SwiftUI), with build.sh for the DMG
docs/             architecture, setup, signing, verification, troubleshooting
```

## Installing the apps

Both apps are built and packaged by CI, and every push uploads them as artifacts:

| Artifact | What it is |
| --- | --- |
| `RunnerForge-windows-msi` | `RunnerForge.msi` — the app plus its scripts and templates, installed to `Program Files\Runner Forge` |
| `RunnerForge-windows-programfiles` | the same payload unpacked, if you would rather not run an installer |
| `RunnerForge-macos-dmg` | `RunnerForge.dmg` — drag `RunnerForge.app` to Applications |
| `RunnerForge-macos-app` | the `.app` as a tarball; macOS bundles are tarred because `upload-artifact` flattens symlinks and a bundle without its symlinks is no longer a bundle |

The DMG CI produces is **ad-hoc signed**, which means it runs on the machine that
built it and Gatekeeper rejects it anywhere else. That is deliberate: a distributable
build needs a Developer ID identity and notarization, which
`app-macos/build.sh --sign "Developer ID Application: …" --notarize` does on a machine
that has them.

## Versioning

Every version this project depends on — base images, CMake, Ninja, Git, Inno Setup,
7-Zip, sccache, Python, the Actions runner, Tart, Packer — is pinned in
[`versions.toml`](versions.toml), together with the SHA-256 of every binary the image
builds download. No version string is hardcoded anywhere else, and no image build
ever accepts a download whose hash is unknown.

## Licence

MIT. See [LICENSE](LICENSE).
