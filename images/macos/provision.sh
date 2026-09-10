#!/usr/bin/env bash
#
# Runner Forge — mac-build Tart image provisioner.
#
# Runs INSIDE the VM during `packer build`. Installs the CI toolchain into the
# image so that nothing has to be downloaded at job time: a job that fetches its
# own toolchain is a job that fails the day the download does.
#
# Every version and URL arrives in the environment from versions.toml by way of
# the Packer template. Nothing is hardcoded here, and every download is verified
# against its recorded SHA-256. There is no flag to skip verification.
#
set -euo pipefail

log() { printf '[provision] %s\n' "$*"; }

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "[provision] error: $name is not set. It must come from versions.toml via the Packer template." >&2
    exit 2
  fi
}

for required in CMAKE_URL CMAKE_SHA256 NINJA_URL NINJA_SHA256 RUNNER_URL RUNNER_SHA256; do
  require_env "$required"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/runnerforge-provision.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# macOS ships shasum rather than sha256sum.
verify_sha256() {
  local file="$1" expected="$2" name="$3"
  if [[ -z "$expected" ]]; then
    echo "[provision] error: no SHA-256 recorded for $name; verification is never skipped." >&2
    exit 1
  fi
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "[provision] CHECKSUM MISMATCH for $name" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
  log "$name sha256 ok"
}

download() {
  local url="$1" dest="$2" name="$3"
  log "downloading $name"
  log "  $url"
  if ! curl -fsSL --retry 3 --retry-delay 3 "$url" -o "$dest"; then
    echo "[provision] FAILED TO DOWNLOAD $name" >&2
    echo "  URL: $url" >&2
    echo "  The pinned artifact is unavailable. Update versions.toml deliberately; do not fall back to an unpinned version." >&2
    exit 1
  fi
}

# --- CMake -----------------------------------------------------------------
download "$CMAKE_URL" "$WORK/cmake.tar.gz" 'CMake'
verify_sha256 "$WORK/cmake.tar.gz" "$CMAKE_SHA256" 'CMake'
sudo mkdir -p /opt/cmake
sudo tar -xzf "$WORK/cmake.tar.gz" -C /opt/cmake --strip-components=1
# The macOS tarball is an .app bundle layout, so the binaries sit under Contents.
CMAKE_BIN="/opt/cmake/CMake.app/Contents/bin"
[[ -d "$CMAKE_BIN" ]] || CMAKE_BIN="/opt/cmake/bin"
sudo ln -sf "$CMAKE_BIN/cmake" /usr/local/bin/cmake
sudo ln -sf "$CMAKE_BIN/ctest" /usr/local/bin/ctest
log "cmake: $(/usr/local/bin/cmake --version | head -1)"

# --- Ninja -----------------------------------------------------------------
download "$NINJA_URL" "$WORK/ninja.zip" 'Ninja'
verify_sha256 "$WORK/ninja.zip" "$NINJA_SHA256" 'Ninja'
unzip -qo "$WORK/ninja.zip" -d "$WORK/ninja"
sudo install -m 0755 "$WORK/ninja/ninja" /usr/local/bin/ninja
log "ninja: $(/usr/local/bin/ninja --version)"

# --- ccache ----------------------------------------------------------------
# Homebrew is already present in the cirruslabs base image.
if ! command -v ccache >/dev/null 2>&1; then
  log 'installing ccache via Homebrew'
  brew install ccache
fi
log "ccache: $(ccache --version | head -1)"

# --- the Actions runner ----------------------------------------------------
RUNNER_HOME="$HOME/actions-runner"
download "$RUNNER_URL" "$WORK/runner.tar.gz" 'Actions runner'
verify_sha256 "$WORK/runner.tar.gz" "$RUNNER_SHA256" 'Actions runner'
mkdir -p "$RUNNER_HOME"
tar -xzf "$WORK/runner.tar.gz" -C "$RUNNER_HOME"
[[ -x "$RUNNER_HOME/run.sh" ]] || { echo '[provision] the Actions runner did not extract correctly' >&2; exit 1; }
log "actions runner installed at $RUNNER_HOME"

# --- caches ----------------------------------------------------------------
# These directories are bind-mounted from the host's persistent cache at job
# time. Creating them here means the mount target always exists.
mkdir -p "$HOME/cache/fetchcontent" "$HOME/cache/ccache"

# --- keep the VM awake -----------------------------------------------------
# A VM that sleeps mid-job drops the job. The host also holds its own caffeinate
# assertion; this is belt and braces inside the guest.
sudo systemsetup -setsleep Never >/dev/null 2>&1 || log 'could not disable sleep inside the guest (non-fatal)'

log 'provisioning complete'
