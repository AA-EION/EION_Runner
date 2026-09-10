# ---------------------------------------------------------------------------
# Runner Forge — mac-build Tart image.
#
# Provisions the pinned cirruslabs base macOS image into runnerforge-macos:<tag>
# by installing CMake, Ninja, ccache and the Actions runner inside the VM.
#
# This image is a KEEP item. It is built once, takes a long time, and is cloned
# per job. `tart delete` is only ever applied to CLONES (named forge-*), never to
# this image.
#
# NO VERSION IS HARDCODED HERE. Every variable below is declared without a
# default, so `packer build` fails immediately unless the caller supplies the
# values from versions.toml. That is deliberate: a default would be a second
# source of truth.
#
# macOS IS ONLY EVER BUILT ON APPLE HARDWARE. Tart uses Apple's Virtualization
# framework, which exists only on macOS on Apple Silicon. There is no Windows,
# Linux, QEMU or KVM path to a macOS runner — it is both technically impossible
# on that hardware and a violation of Apple's licence.
# ---------------------------------------------------------------------------

packer {
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "base_image" {
  type        = string
  description = "Pinned base Tart image, from [macos_image].base_image in versions.toml."
}

variable "image_tag" {
  type        = string
  description = "Tag applied to the produced image, from [macos_image].tag in versions.toml."
}

variable "cmake_url" {
  type        = string
  description = "CMake macOS universal tarball URL, templated from [urls] in versions.toml."
}

variable "cmake_sha256" {
  type        = string
  description = "SHA-256 of the CMake tarball, from [checksums] in versions.toml."
}

variable "ninja_url" {
  type        = string
  description = "Ninja macOS zip URL, templated from [urls] in versions.toml."
}

variable "ninja_sha256" {
  type        = string
  description = "SHA-256 of the Ninja zip, from [checksums] in versions.toml."
}

variable "runner_url" {
  type        = string
  description = "Actions runner osx-arm64 tarball URL, templated from [urls] in versions.toml."
}

variable "runner_sha256" {
  type        = string
  description = "SHA-256 of the Actions runner tarball, from [checksums] in versions.toml."
}

variable "ssh_username" {
  type        = string
  description = "SSH user inside the base image."
  default     = "admin"
}

variable "ssh_password" {
  type        = string
  description = "SSH password inside the base image. This is the cirruslabs base image's well-known default credential, not a secret of yours — no Runner Forge credential is ever passed to a Packer build."
  default     = "admin"
  sensitive   = true
}

variable "cpu_count" {
  type        = number
  description = "vCPUs given to the build VM."
  default     = 4
}

variable "memory_gb" {
  type        = number
  description = "Memory in GB given to the build VM."
  default     = 8
}

variable "disk_size_gb" {
  type        = number
  description = "Disk size in GB for the produced image. A macOS image plus Xcode plus caches is large."
  default     = 120
}

source "tart-cli" "runnerforge" {
  vm_base_name = var.base_image
  vm_name      = "runnerforge-macos:${var.image_tag}"

  cpu_count    = var.cpu_count
  memory_gb    = var.memory_gb
  disk_size_gb = var.disk_size_gb

  headless = true

  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "300s"
}

build {
  name    = "runnerforge-macos"
  sources = ["source.tart-cli.runnerforge"]

  # Versions and checksums are handed to the provisioner as environment
  # variables so provision.sh contains no version literal either.
  provisioner "shell" {
    environment_vars = [
      "CMAKE_URL=${var.cmake_url}",
      "CMAKE_SHA256=${var.cmake_sha256}",
      "NINJA_URL=${var.ninja_url}",
      "NINJA_SHA256=${var.ninja_sha256}",
      "RUNNER_URL=${var.runner_url}",
      "RUNNER_SHA256=${var.runner_sha256}",
    ]
    script          = "${path.root}/../provision.sh"
    execute_command = "chmod +x {{ .Path }}; env {{ .Vars }} {{ .Path }}"
  }

  # Prove the toolchain landed before the image is committed. An image that is
  # missing a compiler only reveals itself much later, as a confusing CI failure.
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "echo '==> verifying the provisioned toolchain'",
      "/usr/local/bin/cmake --version",
      "/usr/local/bin/ninja --version",
      "ccache --version | head -1",
      "test -x \"$HOME/actions-runner/run.sh\" || { echo 'the Actions runner is missing' >&2; exit 1; }",
      "xcodebuild -version",
      "echo '==> toolchain verified'",
    ]
  }
}
