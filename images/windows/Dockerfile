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
# NO VERSION OR URL IS HARDCODED HERE. Everything arrives as a build argument
# read from versions.toml, and no ARG has a default, so a build that omits one
# fails immediately rather than silently installing something unpinned.
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
ARG CMAKE_URL
ARG CMAKE_SHA256
ARG NINJA_URL
ARG NINJA_SHA256
ARG GIT_URL
ARG GIT_SHA256
ARG INNOSETUP_URL
ARG INNOSETUP_SHA256
ARG SEVENZIP_URL
ARG SEVENZIP_SHA256
ARG SCCACHE_URL
ARG SCCACHE_SHA256
ARG PYTHON_URL
ARG PYTHON_SHA256
ARG RUNNER_URL
ARG RUNNER_SHA256
ARG IMAGE_TAG

LABEL org.opencontainers.image.title="runnerforge/win-build" `
      org.opencontainers.image.description="Runner Forge ephemeral Windows runner: MSVC x64 + ARM64 cross toolset, CMake, Ninja, Inno Setup" `
      org.opencontainers.image.version="${IMAGE_TAG}" `
      org.opencontainers.image.licenses="MIT" `
      dev.runnerforge.class="win-build"

# Every RUN below stops on the first error. Without $ErrorActionPreference='Stop'
# a failed download leaves a half-built image that appears to succeed.
SHELL ["powershell", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

ENV RUNNER_HOME="C:\actions-runner" `
    FETCHCONTENT_BASE_DIR="C:\cache\fetchcontent" `
    SCCACHE_DIR="C:\cache\sccache" `
    TOOLS_DIR="C:\tools"

COPY install-buildtools.ps1 C:/install/install-buildtools.ps1

# One layer for the whole toolchain. Splitting it would not help: the Visual
# Studio installer is by far the largest step and never cache-hits anyway.
RUN C:\install\install-buildtools.ps1 `
      -VsBootstrapUrl   $env:VS_BUILDTOOLS_BOOTSTRAP_URL `
      -VsChannelUrl     $env:VS_BUILDTOOLS_CHANNEL_URL `
      -VsComponents     $env:VS_COMPONENTS `
      -CMakeUrl         $env:CMAKE_URL      -CMakeSha256     $env:CMAKE_SHA256 `
      -NinjaUrl         $env:NINJA_URL      -NinjaSha256     $env:NINJA_SHA256 `
      -GitUrl           $env:GIT_URL        -GitSha256       $env:GIT_SHA256 `
      -InnoSetupUrl     $env:INNOSETUP_URL  -InnoSetupSha256 $env:INNOSETUP_SHA256 `
      -SevenZipUrl      $env:SEVENZIP_URL   -SevenZipSha256  $env:SEVENZIP_SHA256 `
      -SccacheUrl       $env:SCCACHE_URL    -SccacheSha256   $env:SCCACHE_SHA256 `
      -PythonUrl        $env:PYTHON_URL     -PythonSha256    $env:PYTHON_SHA256 `
      -RunnerUrl        $env:RUNNER_URL     -RunnerSha256    $env:RUNNER_SHA256 `
      -RunnerHome       $env:RUNNER_HOME `
      -ToolsDir         $env:TOOLS_DIR; `
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
