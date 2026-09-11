# Setup — macOS host

This host runs `mac-build` (a Tart VM clone) and optionally `mac-ilok` (a host process
that signs AAX and compiles nothing).

## Requirements

| Requirement | Why | Preflight behaviour |
|---|---|---|
| **Apple Silicon** (`arm64`) | Tart is Apple-Virtualization-framework only | **Blocks** on Intel |
| macOS ≥ the pinned minimum in `versions.toml` | deployment target of the app and the VM image | Blocks |
| Tart ≥ the pinned minimum | VM lifecycle | Auto-fixable (`brew install cirruslabs/cli/tart`) |
| Xcode installed, `xcode-select -p` valid, licence accepted | the VM image builds with the real toolchain | Blocks |
| Rosetta 2 | universal2 builds and some Intel-only tooling | Auto-fixable (`softwareupdate --install-rosetta --agree-to-license`) |
| Free disk ≥ `limits.maxDiskGb` | a macOS VM image is tens of GB | Blocks |
| Sleep disabled while runners are active | a sleeping Mac drops in-flight jobs | The app holds its own `caffeinate` assertion and reports it |
| Outbound HTTPS to `github.com`, `api.github.com`, `ghcr.io` | pulling images and minting tokens | Blocks |
| Developer ID Application + Installer identities in the keychain | signing the plugin | Warns; only signing is affected |
| `xcrun notarytool` available, ASC credentials valid | notarization | Warns |

**There is no macOS runner on Windows.** macOS cannot legally or technically be
virtualized on non-Apple hardware — not in Docker, not in QEMU, not in KVM, not in WSL.
The Windows app shows the macOS classes greyed out with "runs on the Mac host" and
refuses to improvise.

## Install order

1. Install Xcode from the App Store and open it once to accept the licence.
2. `brew install cirruslabs/cli/tart` (or use Preflight's `Fix`).
3. Install Runner Forge — see **Installing Runner Forge** below — and open it.
4. Work the Preflight page top to bottom.

No compiler is installed *for CI use* on this host — the CI toolchain lives in the Tart
image. Xcode is required on the host because the image build provisions from it and
because notarization uses `xcrun`.

## Installing Runner Forge

Every push builds and packages the app, so take the artifact from the latest green
`ci-macos-app` run on the Actions tab:

| Artifact | What it is |
| --- | --- |
| `RunnerForge-macos-dmg` | `RunnerForge.dmg`. Open it and drag `RunnerForge.app` onto the Applications alias inside. |
| `RunnerForge-macos-app` | the `.app` as a tarball, for scripted installs: `tar -xpf RunnerForge-app.tar`. Use `-p`, or the bundle's symlinks are not restored. |

**The DMG that CI produces is ad-hoc signed, and Gatekeeper will refuse it.** That is
not a bug to work around: a hosted runner has no Developer ID identity, so there is
nothing to sign with. It runs only on the machine that built it. To produce a build
that opens on any Mac, run the packaging step somewhere that has the certificate:

```bash
cd app-macos
./build.sh --sign "Developer ID Application: Your Name (TEAMID)" --notarize
```

with `APPLE_ASC_ISSUER_ID`, `APPLE_ASC_KEY_ID` and `APPLE_ASC_PRIVATE_KEY` in the
environment. That path signs nested code inside-out (never `codesign --deep`, which
re-signs nested code with the outer bundle's entitlements), submits to `notarytool`,
and **staples** the ticket into the DMG. Stapling is not optional: without the ticket
inside the artifact, every machine but the build machine has to ask Apple at launch
and fails closed when it cannot.

Runner Forge runs with **Hardened Runtime on and App Sandbox off**, and the CI job
asserts that from the signature rather than from the entitlements file. The reason is
in `Sources/RunnerForge/Resources/RunnerForge.entitlements`: the app's whole job is to
launch `tart`, `docker`, `codesign`, `notarytool` and `wraptool`, and a sandboxed
process cannot launch any of them.

The app is **arm64 only**, deliberately. Tart drives Apple's Virtualization framework,
which does not exist on Intel; Preflight reports an Intel Mac as a hard block with no
fix, so an x86_64 slice would only produce an app that launches and can do nothing.

## Building the Tart image

The base image is pinned in `versions.toml` under `[macos_image].base_image`. Packer
provisions it into `runnerforge-macos:<tag>`:

```bash
export PACKER_PLUGIN_PATH="$HOME/.packer.d/plugins"
packer init  images/macos/packer/runnerforge-macos.pkr.hcl
packer validate images/macos/packer/runnerforge-macos.pkr.hcl
packer build    images/macos/packer/runnerforge-macos.pkr.hcl
tart list
```

`images/macos/provision.sh` installs CMake, Ninja, ccache and the Actions runner *inside
the VM*, verifying every download against the SHA-256 in `versions.toml`.

## How a mac-build job runs

`scripts/tart-runner.sh` is the whole lifecycle:

1. `tart clone runnerforge-macos:<tag> forge-mac-<uuid>` — a copy-on-write clone, cheap.
2. `tart run` the clone headless, wait for SSH.
3. Inject the JIT config over `tart exec` **stdin** — never argv.
4. `./run.sh --jitconfig <blob>` — one job, then the runner unregisters itself.
5. `trap EXIT` → `tart delete forge-mac-<uuid>`, **always**, success or failure.

The base image is never modified. Only clones are created and destroyed, so a poisoned
build environment cannot persist to the next job.

## Caches

macOS caches live under `paths.workDir/cache/` on the host and are mounted into the VM
clone:

- `cache/fetchcontent` — JUCE and `clap-juce-extensions` clones
- `cache/ccache` — compiler cache

These are KEEP items. The Sweeper never deletes them; deleting them is what makes the
next build slow.

## The iLok runner

`mac-ilok` is a host process for the same reason `win-ilok` is: the dongle is a USB
device and the signing tool is a host tool. If you choose `macos-ilok` mode, install the
iLok driver and PACE Eden tools on this host so `wraptool` is on `PATH`. `mac-ilok` and
`win-ilok` are mutually exclusive — the dongle is in one machine or the other.

## Verifying the host is clean

```bash
scripts/reaper.sh --work-dir "$HOME/Library/Application Support/RunnerForge/work"
echo $?          # 0 = clean, 10 = strays killed, 20 = strays survived
tart list
security list-keychains | grep runnerforge-ci- || echo "no ephemeral keychains left"
```

A leftover `runnerforge-ci-*` keychain means a signing script died before its `trap`
ran. The Sweeper removes them on close, but a `20` from the Reaper is worth
investigating rather than clearing.
