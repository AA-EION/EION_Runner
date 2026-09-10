# escape=`
# ---------------------------------------------------------------------------
# Runner Forge — win-build runner image.
#
# Responsibilities of this class: CMake configure and build for x64 AND ARM64
# (ARM64 by CROSS-COMPILING with the MSVC ARM64 toolset — never emulation, never
# an arm64 container), run the tests, compile the Inno Setup installer, and emit
# UNSIGNED artifacts.
#
# This is a WINDOWS container and requires Docker Desktop in Windows containers
# mode with Hyper-V isolation, which means Windows 11 Pro or Enterprise. On Home
# it cannot run, and preflight blocks with an explanation rather than letting the
# user discover it three failed builds later.
#
# THIS DOCKERFILE NAMES NO TOOL AND NO VERSION. It installs whatever the
# [toolchain.windows] section of versions.toml declares, so the same image
# definition serves an audio plugin, a Rust project, or anything else. No ARG has
# a default, so a build that omits one fails immediately rather than silently
# installing something unpinned.
#
# THE AAX SDK IS NEVER COPIED IN. It is proprietary and cannot live in an image
# layer. It is mounted at C:\sdk\aax from a local named volume at run time.
#
# NO SECRET IS EVER PASSED TO THIS BUILD. --build-arg values are recorded in the
# image history and are readable by anyone who can pull the image.
# ---------------------------------------------------------------------------

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG VS_BUILDTOOLS_BOOTSTRAP_URL
ARG VS_BUILDTOOLS_CHANNEL_URL
ARG VS_COMPONENTS

# Newline-separated install manifest, one entry per line:
#     <name>|<url>|<sha256>|<kind>|<destination>
# The caller builds it from [toolchain.windows] in versions.toml. THIS FILE NAMES
# NO TOOL, so retargeting the runner means editing a list, not this Dockerfile.
ARG TOOL_MANIFEST

# Same format, single entry, for the Actions runner. Separate because it is not a
# build tool and is not placed on PATH.
ARG RUNNER_MANIFEST

ARG IMAGE_TAG

LABEL org.opencontainers.image.title="runnerforge/win-build" `
      org.opencontainers.image.description="Runner Forge ephemeral Windows runner. Toolchain contents are declared in versions.toml, not baked into this file." `
      org.opencontainers.image.version="${IMAGE_TAG}" `
      org.opencontainers.image.licenses="MIT" `
      dev.runnerforge.class="win-build"

# Every RUN below stops on the first error. Without $ErrorActionPreference='Stop'
# a failed download leaves a half-built image that appears to succeed.
SHELL ["powershell", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

# These name CACHE DIRECTORIES, not tools. They are the KEEP volumes the Sweeper
# protects. SCCACHE_DIR and FETCHCONTENT_BASE_DIR are the env-var contracts their
# respective tools read; setting them costs nothing when those tools are not part
# of the declared toolchain, and it means the volume mount points are stable
# regardless of what the toolchain list contains.
ENV RUNNER_HOME="C:\actions-runner" `
    FETCHCONTENT_BASE_DIR="C:\cache\fetchcontent" `
    SCCACHE_DIR="C:\cache\sccache" `
    TOOLS_DIR="C:\tools"

COPY install-buildtools.ps1 C:/install/install-buildtools.ps1

# One layer for the whole toolchain. Splitting it would not help: the Visual
# Studio installer is by far the largest step and never cache-hits anyway.
RUN C:\install\install-buildtools.ps1 `
      -VsBootstrapUrl  $env:VS_BUILDTOOLS_BOOTSTRAP_URL `
      -VsChannelUrl    $env:VS_BUILDTOOLS_CHANNEL_URL `
      -VsComponents    $env:VS_COMPONENTS `
      -ToolManifest    $env:TOOL_MANIFEST `
      -RunnerManifest  $env:RUNNER_MANIFEST `
      -RunnerHome      $env:RUNNER_HOME `
      -ToolsDir        $env:TOOLS_DIR; `
    Remove-Item -Recurse -Force C:\install

# --- caches -----------------------------------------------------------------
# These are the KEEP items. FETCHCONTENT_BASE_DIR is what stops every build
# re-cloning JUCE; sccache is what stops every build recompiling it. The Sweeper
# never touches either.
#
# C:\sdk\aax is declared but INTENTIONALLY EMPTY in the image. The Avid SDK is
# mounted here from a local named volume at run time and is never baked in.
VOLUME ["C:\\cache\\fetchcontent", "C:\\cache\\sccache", "C:\\sdk\\aax"]

WORKDIR C:\actions-runner

# The runner writes its listener process once configured from the JIT config.
# Its absence after start-up means the runner never came up.
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 `
    CMD powershell -Command "if (Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"

COPY entrypoint.ps1 C:/entrypoint.ps1

# stdin is how the JIT config arrives. Never argv: argv is readable from the
# host's process list by any user on the machine.
ENTRYPOINT ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\entrypoint.ps1"]
