# Troubleshooting

Every entry here is a failure that was actually hit while building or running this
project, not a hypothetical. Each says what you see, what it means, and what to do.

---

## 1. `innosetup-6.3.3.exe` returns HTTP 404 from `files.jrsoftware.org`

**Symptom** — the Windows image build aborts with:

```
FAILING URL: https://files.jrsoftware.org/is/6/innosetup-6.3.3.exe -> HTTP 404
```

**Cause** — jrsoftware stopped serving 6.x binaries from that path. The directory listing
still shows `innosetup-6.3.3.exe.issig` signature files, which makes it look like the
`.exe` should be there, but every `.exe` under `/is/6/` now 404s. `jrsoftware.org/isdl.php`
links to GitHub releases instead.

**Fix** — the pinned **version is unchanged**; only the host moved. `versions.toml`
`[urls].innosetup_win` points at
`https://github.com/jrsoftware/issrc/releases/download/is-6_3_3/innosetup-6.3.3.exe`.
If that ever 404s too, probe which tags exist before changing the version:

```bash
for tag in is-6_3_3 is-6_4_3 is-6_7_3; do
  v=${tag#is-}; v=${v//_/.}
  printf '%-8s ' "$v"
  curl -sSL -o /dev/null -w '%{http_code}\n' -r 0-0 \
    "https://github.com/jrsoftware/issrc/releases/download/$tag/innosetup-$v.exe"
done
```

Do **not** switch to an unpinned "latest" download to make the error go away.

---

## 2. `docker` commands fail with "Is the docker daemon running?"

**Symptom**

```
failed to connect to the docker API at unix:///var/run/docker.sock;
check if the path is correct and if the daemon is running
```

**Cause** — the Docker *CLI* is installed but the daemon is not up. On a Windows host
this usually means Docker Desktop has not finished starting, or has crashed after a
Windows update. In a Linux container environment it means `dockerd` was never launched.

**Fix** — on Windows, start Docker Desktop and wait for the whale icon to stop animating;
Preflight row 6 ("Docker daemon reachable") turns green when the API answers. If it never
does, `Restart Docker Desktop` from the tray, then check
`%LOCALAPPDATA%\Docker\log.txt`. Note that Preflight distinguishes "Docker Desktop
installed" (row 5) from "daemon reachable" (row 6) precisely because these fail
independently and have different fixes.

---

## 3. GitHub API returns 403 for a repository you can see in a browser

**Symptom**

```
HTTP 403 {"message":"GitHub access to this repository is not enabled for this session."}
```

…even for public repositories like `actions/runner`.

**Cause** — the API call is going through an access-scoped proxy that only permits the
repositories attached to the current session. This is a *policy* 403, not an
authentication failure, and it looks identical to a permissions problem.

**Fix** — attach the repository to the session, or avoid the API entirely where you can.
Release **asset downloads** from `github.com/<owner>/<repo>/releases/download/...` are
plain file fetches and are not subject to the API scoping, which is why
`versions.toml`'s checksums were computed by downloading the assets directly rather than
by reading hashes out of the release JSON.

A quick way to tell a policy 403 from a permissions 403: a permissions 403 mentions
rate limits or scopes; a policy 403 names the proxy and tells you how to grant access.

---

## 4. Docker directory listing shows a file that 404s when downloaded

**Symptom** — `curl` on a directory index lists `foo.exe.issig` but `foo.exe` 404s.

**Cause** — a signature or metadata sidecar is published while the payload is not. It is
easy to conclude the whole host is blocked, or that your proxy strips `.exe`.

**Fix** — control-test with a *different* host before blaming the network. Downloading
some other `.exe` (7-Zip's, for example) succeeding proves the transport is fine and the
404 is the origin server's. Runner Forge's own checksum bootstrap does exactly this
before reporting a pinned URL as dead.

---

---

## 5. `juce_LinuxMessageThread.h: No such file or directory` when building CLAP

**Symptom** — the `Canary_CLAP` target fails while every other format compiles:

```
clap-juce-wrapper.cpp:37:10: fatal error:
  juce_audio_plugin_client/utility/juce_LinuxMessageThread.h: No such file or directory
```

**Cause** — a version mismatch that is easy to misread as a missing dependency. JUCE
moved that header from `utility/` to `detail/` in 7.0.6. The pinned
`clap-juce-extensions` predates the move.

The trap is that `clap-juce-extensions`'s git tags (`0.24.0`, `0.25.0`, `0.26.0`) look
like project versions but track the **CLAP specification** version. The newest of them
is a commit from **2022-05-31**; `main` is years ahead and has carried the
`JUCE_VERSION`-guarded include since "Updates for JUCE 7.0.6". Picking "the newest tag"
therefore picks four-year-old code.

**Fix** — pin by **commit SHA**, which `versions.toml` now does, with the reason
recorded inline. A SHA is a stronger pin than a tag anyway. Note that `GIT_SHALLOW` must
be `FALSE` for a SHA pin: a shallow clone can only check out a branch or tag tip, not an
arbitrary commit.

Verify a candidate SHA carries the guard before pinning it:

```bash
git clone --depth 60 https://github.com/free-audio/clap-juce-extensions.git probe
sed -n '64,76p' probe/src/wrapper/clap-juce-wrapper.cpp   # expect a JUCE_VERSION guard
```

---

## 6. `-Wfloat-equal` on a test that is *supposed* to compare exactly

**Symptom** — JUCE's recommended warning flags turn `==` on floats into a warning, and
the offending line is a test asserting that a gain of zero produces silence.

**Cause** — the warning is right in general and wrong here. Bit-exact silence is the
property under test; a tolerance would let a real bug through.

**Fix** — suppress the warning around a single documented helper rather than loosening
the assertion:

```cpp
JUCE_BEGIN_IGNORE_WARNINGS_GCC_LIKE ("-Wfloat-equal")
bool isExactlyZero (float value) noexcept { return value == 0.0f; }
JUCE_END_IGNORE_WARNINGS_GCC_LIKE
```

The macro is a no-op on MSVC, which has no equivalent warning. Do not reach for
`-Wno-float-equal` project-wide: that hides the accidental comparisons too.

---

## 7. Linking a test executable to a JUCE plugin target: headers not found

**Symptom**

```
Tests.cpp:11:10: fatal error: juce_audio_processors/juce_audio_processors.h: No such file
```

…even though the test target links the plugin's `_SharedCode` library and the
`JucePlugin_*` definitions clearly arrived (they show up on the compiler command line).

**Cause** — `juce_add_plugin` links the JUCE modules into `<Target>_SharedCode`
**PRIVATE**, so the static library's interface carries no include directories. The
definitions propagate; the include paths do not.

**Fix** — link the plugin's main target *and* the module target:

```cmake
target_link_libraries(CanaryTests PRIVATE Canary juce::juce_audio_utils ...)
```

A related trap: building the test with `juce_add_console_app` defines
`JUCE_STANDALONE_APPLICATION=1` while the plugin target defines it as
`JucePlugin_Build_Standalone`, producing a "redefined" warning on every translation
unit. A plain `add_executable` avoids the collision.


_More entries are added as failures are encountered. An entry is only added here once it
has actually been hit — this file is a log, not a list of things that might go wrong._
