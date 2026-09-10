# Setup — Windows host

This host runs three runner classes: `win-build` (Windows container), `linux-util`
(Linux container via WSL2), and optionally `win-ilok` (a host process that signs AAX
and compiles nothing).

## Requirements

| Requirement | Why | Preflight behaviour |
|---|---|---|
| Windows 11 **Pro or Enterprise** | Windows containers need Hyper-V isolation | **Blocks** on Home — no workaround exists |
| Build number ≥ 22000 | `ltsc2022` container compatibility | Blocks |
| Hardware virtualization enabled in firmware | Hyper-V | Blocks, with a link to your firmware settings |
| `Microsoft-Hyper-V` + `Containers` features | Windows containers | Auto-fixable via DISM, then reboot |
| Docker Desktop ≥ the pinned minimum in `versions.toml` | container runtime | Blocks; install manually |
| Docker in **Windows containers** mode | `win-build` is a Windows container | Auto-fixable (`DockerCli.exe -SwitchWindowsEngine`) |
| WSL2 with a distro | `linux-util` | Warns; only `linux-util` is affected |
| Free disk ≥ `limits.maxDiskGb` | images + caches are large | Blocks |
| Sleep on AC disabled | a sleeping PC drops in-flight jobs | Auto-fixable (`powercfg /change standby-timeout-ac 0`) |
| Outbound HTTPS to `github.com`, `api.github.com`, `ghcr.io`, `mcr.microsoft.com` | pulling images and minting tokens | Blocks |

**Windows Home is a hard stop.** Windows containers require Hyper-V isolation, which
Home does not provide. Runner Forge tells you this on the Preflight page instead of
letting you discover it three failed builds later. There is no supported workaround —
not WSL, not process isolation, not a third-party shim.

## Install order

1. Enable virtualization in firmware if Preflight reports it off.
2. Enable the Windows features (Preflight's `Fix` button runs DISM), then reboot.
3. Install Docker Desktop at or above the pinned minimum.
4. Switch Docker to Windows containers — Preflight can do it for you.
5. Install Runner Forge and open it.
6. Work the Preflight page top to bottom until every row is Pass or an accepted Warn.

Nothing else gets installed on this machine. No Visual Studio, no CMake, no Git for
Windows, no Python. Those live inside the container image.

## Building the images

The Runners page has a `Rebuild image` button per class that streams `docker build`
output into the Logs page. From a terminal the equivalent is:

```powershell
docker build -t runnerforge/win-build:1.0.0   -f images\windows\Dockerfile images\windows
docker build -t runnerforge/linux-util:1.0.0  -f images\linux\Dockerfile   images\linux
```

The Windows image is large — a first build pulls `servercore:ltsc2022` and installs the
MSVC x64 **and** ARM64 toolsets — so expect tens of minutes and several GB. It is built
once and kept; the Sweeper never deletes it.

## The named volumes

Four volumes carry everything that makes the second build fast:

| Volume | Contents |
|---|---|
| `forge-fetchcontent` | JUCE and `clap-juce-extensions` clones (`FETCHCONTENT_BASE_DIR`) |
| `forge-sccache` | compiler cache for the Windows builds |
| `forge-ccache` | compiler cache for the Linux builds |
| `forge-aax-sdk` | the proprietary Avid AAX SDK, if you have one |

Create them once:

```powershell
docker volume create forge-fetchcontent
docker volume create forge-sccache
docker volume create forge-ccache
docker volume create forge-aax-sdk
```

The AAX SDK is **never** copied into an image layer. Point `paths.aaxSdkSource` at a
local zip or a private git URL and Runner Forge unpacks it into `forge-aax-sdk` on the
host. If you have no SDK, leave it empty: the workflow then emits a `-aax-skipped`
marker artifact naming the reason, so the artifact set is never silently short.

## The iLok runner

`win-ilok` is a **host process**, not a container, because a Windows container cannot
see a USB device. This is not a limitation Runner Forge can engineer around; USB
passthrough into Windows containers does not exist.

If you choose `windows-ilok` signing mode you additionally install, on this host only:

- the iLok driver (PACE License Support), and
- PACE Eden tools, so `wraptool.exe` is on `PATH`.

That is the complete list of host installs for this machine. `win-ilok` downloads an
unsigned AAX artifact, signs it, and uploads the signed one. It never compiles.

## Verifying the host is clean

After a job, the Reaper should report nothing:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\reaper.ps1 -WorkDir "$env:ProgramData\RunnerForge\work"
echo $LASTEXITCODE   # 0 = clean, 10 = strays killed, 20 = strays survived
docker ps -a
```

A `20` means something survived SIGKILL. The GUI will refuse to start new runners until
you acknowledge it; investigate before overriding.
