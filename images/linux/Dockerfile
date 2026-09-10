# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Runner Forge — linux-util runner image.
#
# THIS DOCKERFILE NAMES NO TOOL AND NO PACKAGE. It installs whatever the
# [toolchain.linux] section of versions.toml tells it to, so the same image
# definition serves an audio plugin, a Rust project, or anything else. Retarget
# the runner by editing a list, not this file.
#
# Everything arrives as a build argument, and no ARG has a default, so a build
# that forgets one fails immediately rather than quietly installing something
# unpinned. Every download is verified against a recorded SHA-256; there is no
# flag to skip verification.
#
# NO SECRET IS EVER PASSED TO THIS BUILD. --build-arg values are recorded in the
# image history and readable by anyone who can pull the image. Credentials reach
# a RUNNING container through --env-file on a RAM-backed path.
# ---------------------------------------------------------------------------

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Space-separated apt packages. The caller concatenates apt_base and
# apt_workload from versions.toml.
ARG APT_PACKAGES

# Newline-separated install manifest. One entry per line:
#     <name>|<url>|<sha256>|<kind>|<destination>
# kind is one of: tar-strip1, tar-flat, zip-flat.
ARG TOOL_MANIFEST

# Same format, single entry, for the Actions runner. Kept separate because it is
# not a build tool and is not placed on PATH.
ARG RUNNER_MANIFEST

ARG IMAGE_TAG

# Optional. PEM contents of an extra trusted CA, for networks that terminate and
# re-sign TLS. Empty by default. A certificate is public by nature, so unlike a
# credential it is safe to pass as a build argument.
ARG EXTRA_CA_PEM=""

LABEL org.opencontainers.image.title="runnerforge/linux-util" \
      org.opencontainers.image.description="Runner Forge ephemeral Linux runner. Toolchain contents are declared in versions.toml, not baked into this file." \
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
# why individual .deb versions are not pinned.
RUN set -euo pipefail; \
    if [ -z "${APT_PACKAGES}" ]; then \
        echo "APT_PACKAGES is empty. It must come from [toolchain.linux] in versions.toml." >&2; \
        exit 2; \
    fi; \
    apt-get update; \
    # Deliberately unquoted: APT_PACKAGES is a space-separated list.
    apt-get install -y --no-install-recommends ${APT_PACKAGES}; \
    rm -rf /var/lib/apt/lists/*

# --- optional extra CA ------------------------------------------------------
# After ca-certificates is installed and before anything is downloaded, or the
# downloads below fail TLS verification on a re-signing network. Skipping
# verification is never an option, so the trust store is fixed instead.
RUN set -euo pipefail; \
    if [ -n "${EXTRA_CA_PEM}" ]; then \
        printf '%s\n' "${EXTRA_CA_PEM}" > /usr/local/share/ca-certificates/runnerforge-extra.crt; \
        update-ca-certificates; \
        echo "installed an extra trusted CA"; \
    else \
        echo "no extra CA supplied; using the system trust store only"; \
    fi

# --- the declared toolchain -------------------------------------------------
# One generic loop over the manifest. Adding a tool means adding a line to
# versions.toml, never editing this Dockerfile.
RUN set -euo pipefail; \
    if [ -z "${TOOL_MANIFEST}" ]; then \
        echo "TOOL_MANIFEST is empty. It must come from [toolchain.linux].tools in versions.toml." >&2; \
        exit 2; \
    fi; \
    printf '%s\n' "${TOOL_MANIFEST}" | while IFS='|' read -r name url sha kind dest; do \
        [ -n "${name}" ] || continue; \
        if [ -z "${sha}" ]; then \
            echo "no SHA-256 recorded for ${name}; verification is never skipped." >&2; exit 1; \
        fi; \
        echo "==> ${name} -> ${dest} (${kind})"; \
        echo "    ${url}"; \
        if ! curl -fsSL --retry 3 --retry-delay 3 "${url}" -o /tmp/dl.bin; then \
            echo "FAILED TO DOWNLOAD ${name}" >&2; \
            echo "  URL: ${url}" >&2; \
            echo "  The pinned artifact is unavailable. Update versions.toml deliberately; do not fall back to an unpinned version." >&2; \
            exit 1; \
        fi; \
        echo "${sha}  /tmp/dl.bin" | sha256sum -c - >/dev/null || { \
            echo "CHECKSUM MISMATCH for ${name}: the file at ${url} is not the file that was pinned." >&2; exit 1; }; \
        echo "    sha256 ok"; \
        mkdir -p "${dest}"; \
        case "${kind}" in \
            tar-strip1) tar -xzf /tmp/dl.bin -C "${dest}" --strip-components=1 ;; \
            tar-flat)   tar -xzf /tmp/dl.bin -C "${dest}" ;; \
            zip-flat)   unzip -qo /tmp/dl.bin -d "${dest}" ;; \
            *) echo "unknown install kind '${kind}' for ${name}" >&2; exit 1 ;; \
        esac; \
        rm -f /tmp/dl.bin; \
        find "${dest}" -maxdepth 2 -type f -perm -u+x -exec chmod 0755 {} + 2>/dev/null || true; \
    done

# Put every installed executable on PATH by symlinking it into /usr/local/bin,
# which is already on PATH. This handles both layouts — a tool that ships bin/
# and a tool that is a bare binary — WITHOUT this file naming either one, so
# PATH does not have to be edited when the toolchain list changes.
RUN set -euo pipefail; \
    printf '%s\n' "${TOOL_MANIFEST}" | while IFS='|' read -r name url sha kind dest; do \
        [ -n "${dest}" ] || continue; \
        bindir="${dest}/bin"; \
        [ -d "${bindir}" ] || bindir="${dest}"; \
        find "${bindir}" -maxdepth 1 -type f -perm -u+x -exec ln -sf {} /usr/local/bin/ \; ; \
    done; \
    echo "==> executables now on PATH:"; \
    ls -1 /usr/local/bin

# --- the runner account -----------------------------------------------------
# The runner never runs as root. A job that escapes into the container should
# not also arrive with uid 0.
RUN set -euo pipefail; \
    if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi; \
    useradd --create-home --shell /bin/bash --uid 1000 runner; \
    mkdir -p /cache/fetchcontent /cache/ccache "${RUNNER_HOME}"; \
    chown -R runner:runner /cache "${RUNNER_HOME}"

USER runner
WORKDIR ${RUNNER_HOME}

RUN set -euo pipefail; \
    printf '%s\n' "${RUNNER_MANIFEST}" | { IFS='|' read -r name url sha kind dest; \
        [ -n "${sha}" ] || { echo "no SHA-256 recorded for ${name}" >&2; exit 1; }; \
        echo "==> ${name}"; \
        curl -fsSL --retry 3 --retry-delay 3 "${url}" -o /tmp/runner.bin || { \
            echo "FAILED TO DOWNLOAD ${name} from ${url}" >&2; exit 1; }; \
        echo "${sha}  /tmp/runner.bin" | sha256sum -c - >/dev/null || { \
            echo "CHECKSUM MISMATCH for ${name}" >&2; exit 1; }; \
        case "${kind}" in \
            tar-flat) tar -xzf /tmp/runner.bin -C "${RUNNER_HOME}" ;; \
            zip-flat) unzip -qo /tmp/runner.bin -d "${RUNNER_HOME}" ;; \
            *) echo "unknown runner install kind '${kind}'" >&2; exit 1 ;; \
        esac; \
        rm -f /tmp/runner.bin; }; \
    test -x "${RUNNER_HOME}/run.sh"

# Cache volumes. These are the KEEP items: deleting them is what makes the next
# build slow, so the Sweeper never touches them.
VOLUME ["/cache/fetchcontent", "/cache/ccache"]

COPY --chown=runner:runner entrypoint.sh /usr/local/bin/entrypoint.sh

USER root
RUN chmod 0755 /usr/local/bin/entrypoint.sh
USER runner

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD pgrep -f Runner.Listener > /dev/null || exit 1

# stdin is how the JIT config arrives. Never argv: argv is world-readable in the
# process list.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
