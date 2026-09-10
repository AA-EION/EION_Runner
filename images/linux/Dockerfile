# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Runner Forge — linux-util runner image.
#
# Responsibilities of this class: release assembly, artifact collection,
# artifact verification, GitHub Release creation, and a Linux verification build
# of the plugin.
#
# NO VERSION OR URL IS HARDCODED HERE. Every one arrives as a build argument
# read from versions.toml by the caller. None of the ARGs below has a default,
# so a build that forgets one fails immediately and loudly rather than quietly
# installing something unpinned.
#
# NO SECRET IS EVER PASSED TO THIS BUILD. Credentials reach a running container
# through --env-file pointing at a RAM-backed path, never through --build-arg
# (which is recorded in the image history) and never baked into a layer.
# ---------------------------------------------------------------------------

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG RUNNER_URL
ARG RUNNER_SHA256
ARG CMAKE_URL
ARG CMAKE_SHA256
ARG NINJA_URL
ARG NINJA_SHA256
ARG IMAGE_TAG

LABEL org.opencontainers.image.title="runnerforge/linux-util" \
      org.opencontainers.image.description="Runner Forge ephemeral Linux runner: release assembly, artifact verification, Linux verification build" \
      org.opencontainers.image.version="${IMAGE_TAG}" \
      org.opencontainers.image.licenses="MIT" \
      dev.runnerforge.class="linux-util"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    RUNNER_HOME=/home/runner/actions-runner \
    FETCHCONTENT_BASE_DIR=/cache/fetchcontent \
    CCACHE_DIR=/cache/ccache

# --- system packages --------------------------------------------------------
# Package versions come from the digest-pinned base image; see versions.toml for
# why individual .deb versions are not pinned here.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        git \
        ca-certificates \
        curl \
        jq \
        zip \
        unzip \
        tar \
        ccache \
        libicu74 \
        liblttng-ust1 \
        libssl3 \
        libasound2-dev \
        libjack-jackd2-dev \
        libfreetype6-dev \
        libfontconfig1-dev \
        libx11-dev \
        libxcomposite-dev \
        libxcursor-dev \
        libxext-dev \
        libxinerama-dev \
        libxrandr-dev \
        libxrender-dev \
        libglu1-mesa-dev \
        mesa-common-dev && \
    rm -rf /var/lib/apt/lists/*

# --- CMake ------------------------------------------------------------------
# Every download is verified against the SHA-256 recorded in versions.toml. A
# mismatch aborts the build; verification is never skipped.
RUN set -euo pipefail; \
    curl -fsSL "${CMAKE_URL}" -o /tmp/cmake.tar.gz; \
    echo "${CMAKE_SHA256}  /tmp/cmake.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/cmake; \
    tar -xzf /tmp/cmake.tar.gz -C /opt/cmake --strip-components=1; \
    rm -f /tmp/cmake.tar.gz; \
    ln -s /opt/cmake/bin/cmake /usr/local/bin/cmake; \
    ln -s /opt/cmake/bin/ctest /usr/local/bin/ctest; \
    cmake --version

# --- Ninja ------------------------------------------------------------------
RUN set -euo pipefail; \
    curl -fsSL "${NINJA_URL}" -o /tmp/ninja.zip; \
    echo "${NINJA_SHA256}  /tmp/ninja.zip" | sha256sum -c -; \
    unzip -q /tmp/ninja.zip -d /usr/local/bin; \
    rm -f /tmp/ninja.zip; \
    chmod +x /usr/local/bin/ninja; \
    ninja --version

# --- the runner account -----------------------------------------------------
# The runner never runs as root. A job that escapes into the container should
# not also arrive with uid 0.
RUN set -euo pipefail; \
    if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi; \
    useradd --create-home --shell /bin/bash --uid 1000 runner; \
    mkdir -p /cache/fetchcontent /cache/ccache "${RUNNER_HOME}"; \
    chown -R runner:runner /cache "${RUNNER_HOME}"

# --- the Actions runner -----------------------------------------------------
USER runner
WORKDIR ${RUNNER_HOME}

RUN set -euo pipefail; \
    curl -fsSL "${RUNNER_URL}" -o /tmp/runner.tar.gz; \
    echo "${RUNNER_SHA256}  /tmp/runner.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/runner.tar.gz -C "${RUNNER_HOME}"; \
    rm -f /tmp/runner.tar.gz; \
    test -x "${RUNNER_HOME}/run.sh"

# Cache volumes. These are the KEEP items: deleting them is what makes the next
# build slow, so the Sweeper never touches them.
VOLUME ["/cache/fetchcontent", "/cache/ccache"]

COPY --chown=runner:runner entrypoint.sh /usr/local/bin/entrypoint.sh

USER root
RUN chmod 0755 /usr/local/bin/entrypoint.sh
USER runner

# The runner writes .runner once it has configured itself from the JIT config.
# Its absence after start-up means the runner never came up.
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD pgrep -f Runner.Listener > /dev/null || exit 1

# stdin is how the JIT config arrives. Never argv: argv is world-readable in the
# process list.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
