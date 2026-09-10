# Canary

A minimal but genuine JUCE 8 audio plugin whose only job is to prove that the
Runner Forge pipeline actually works.

It is a real plugin — real DSP, real parameters, a real editor, real tests, real
installers — because a build that only compiles a stub proves almost nothing. It is
also deliberately small, so a full four-platform verification run costs minutes rather
than an afternoon.

## Why it exists separately from the real project

End-to-end verification must not depend on:

- **the private RecRoll repository**, which not everyone can clone, or
- **the proprietary Avid AAX SDK**, which cannot be redistributed.

So the canary carries no AAX target at all. Everything else — VST3, CLAP, Standalone,
AU on macOS, the Inno Setup installer, the macOS `.pkg` and `.dmg` — is exercised in
full. When Runner Forge needs to prove the AAX path specifically, that is Stage E
against the real repository, and any skipped artifact is named and justified rather
than quietly dropped.

## What it does

A one-pole low-pass followed by a gain stage. Two parameters (`gain`, `cutoff`), an
`AudioProcessorValueTreeState`, and a two-slider editor. The editor exists on purpose:
the GUI modules are a large fraction of what has to compile and link on every platform,
and they are where cross-platform builds break first.

## Formats

| Format | Windows | macOS | Linux |
|---|---|---|---|
| VST3 | yes | yes | yes |
| CLAP | yes | yes | yes |
| Standalone | yes | yes | yes |
| AU | — | yes | — |
| AAX | deliberately absent — see above | | |

## Versions

The canary hardcodes no versions. `CMakeLists.txt` reads JUCE and
`clap-juce-extensions` out of **`versions.toml`**, the same single source of truth the
rest of Runner Forge uses, and fails loudly if it cannot find that file rather than
guessing a version.

If you publish the canary as a standalone repository, `versions.toml` must be copied
alongside it. `CMakeLists.txt` looks for it in this directory and in the parent
directory.

> `clap-juce-extensions` is pinned by **commit SHA**, not by tag. Its tags
> (`0.24.0`–`0.26.0`) track the CLAP *specification* version, and the newest of them is
> a commit from 2022 that does not build against JUCE 8. See the note in
> `versions.toml`.

## Building locally

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/tests/CanaryTests
```

On Linux you need the usual JUCE dependencies:

```bash
sudo apt-get install -y build-essential pkg-config libasound2-dev libjack-jackd2-dev \
  libfreetype6-dev libfontconfig1-dev libx11-dev libxcomposite-dev libxcursor-dev \
  libxext-dev libxinerama-dev libxrandr-dev libxrender-dev libglu1-mesa-dev \
  mesa-common-dev
```

To reuse a warm JUCE clone rather than re-cloning it, point `FETCHCONTENT_BASE_DIR` at
a persistent directory — which is exactly what the runner images do with the
`forge-fetchcontent` volume:

```bash
cmake -S . -B build -G Ninja -DFETCHCONTENT_BASE_DIR=/path/to/persistent/cache
```

## Tests

`Source/Tests.cpp` is a plain console runner rather than a test framework, so the CI
job needs nothing installed to run it. Exit code 0 means every check passed.

It makes 17 assertions across seven groups: the gain stage, DC pass-through, the
low-pass frequency response, filter state reset, channel independence, processor
identity and parameters, state save/restore round-trip, bus-layout negotiation, and
`processBlock` output sanity.

Several checks compare floats with `==` on purpose — a gain of zero must produce
bit-exact silence, not "small" — so `-Wfloat-equal` is suppressed around a single
documented helper rather than the checks being loosened to a tolerance that would let a
real bug through.

## Installers

- `installer/windows/Canary.iss` — Inno Setup. Every path is passed in with `/D` so one
  script serves both x64 and ARM64. It is compiled by the `ISCC.exe` that is baked into
  the `win-build` image; the workflow never installs Inno Setup at run time.
- `installer/macos/build_installer.sh` — `pkgbuild` + `productbuild` + `hdiutil`,
  producing exactly one `.pkg` and one `.dmg`. It deliberately does **not** sign or
  notarize; that is `scripts/sign-macos-artifact.sh`'s job, so an unsigned local build
  and a signed CI build produce identical package layouts.
