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


---

## 8. A PowerShell script parameter named `-Input` silently arrives empty

**Symptom** — `sign-aax-ilok.ps1 -Input foo.aaxplugin` runs, prints no error, and then
behaves as if no input was given. `$Input` inside the script is empty, or contains
something that is not what you passed.

**Cause** — `$Input` is an **automatic variable** in PowerShell: it is the enumerator over
pipeline input. Declaring `param([string]$Input)` does not produce a parse error; the
binder simply cannot populate a variable the engine already owns, and you get an empty
string with no diagnostic at all.

**Fix** — never name a parameter `Input`. This project uses `-InputPath` and
`-OutputPath`, and the scripts carry a comment saying so, because "simplifying" them back
to `-Input` re-introduces a failure with no error message. The same applies to `$Args`,
`$Host`, `$Error` and `$Matches`.

---

## 9. PowerShell renders `"$Name:"` as an empty string

**Symptom** — a log line meant to read `paceAccount: stored` comes out as ` stored`, with
the name gone.

**Cause** — `$Name:` is parsed as a **scope or provider qualifier**, exactly like
`$env:PATH` or `$script:count`. PowerShell reads `Name` as the namespace and looks for a
variable whose name is empty.

**Fix** — brace the variable: `"${Name}:"`. Anywhere a `$variable` is immediately followed
by a colon inside a double-quoted string, the braces are mandatory.

---

## 10. `dotnet test` on Linux: "No frameworks were found"

**Symptom** — the WPF project *builds* on a Linux development machine, but the tests will
not run:

```
You must install or update .NET to run this application.
Framework: 'Microsoft.WindowsDesktop.App', version '9.0.0' (x64)
No frameworks were found.
```

**Cause** — `<EnableWindowsTargeting>true</EnableWindowsTargeting>` makes the Windows
targeting *packs* restorable on any OS, so the compiler can check the code. It does not
ship a Windows desktop *runtime*, and there is none for Linux: WPF is Windows-only at
runtime, by construction.

**Fix** — this is not a bug to work around, and adding `--framework net9.0` or a
`RuntimeIdentifier` will not help. Compile on Linux to catch C# errors cheaply, and run
the tests on Windows. `.github/workflows/ci-windows-app.yml` exists for exactly that,
which is why its `Test` step is not optional and not `continue-on-error`.

---

## 11. `CryptoKit` has no RSA, so the GitHub App JWT will not sign on macOS

**Symptom** — the obvious implementation does not compile:

```
error: cannot find 'RSA' in scope
```

…and searching finds `P256`, `P384`, `P521`, `Curve25519` and nothing else.

**Cause** — CryptoKit deliberately exposes no RSA on Apple platforms. It is not an
omission that a newer SDK fixes. GitHub App JWTs are `RS256`, so ECDSA is not a
substitute.

**Fix** — use the Security framework, which is the supported RSA path:

```swift
let key = try Self.secKey(fromPem: privateKeyPem)
guard let signature = SecKeyCreateSignature(
    key, .rsaSignatureMessagePKCS1v15SHA256, Data(signingInput.utf8) as CFData, &error
) as Data? else { throw GitHubError.signingFailed }
```

One trap inside that: `SecKeyCreateWithData` wants a **PKCS#1** key. A `.pem` that begins
`-----BEGIN PRIVATE KEY-----` is PKCS#8 and carries a 26-byte header that must be stripped
first; one beginning `-----BEGIN RSA PRIVATE KEY-----` is already PKCS#1. Feeding PKCS#8
straight in fails with an opaque `-50` (`errSecParam`).

---

## 12. `windows-latest` cannot find Visual Studio 2022

**Symptom** — a Windows build job dies in under 20 seconds:

```
CMake Error at CMakeLists.txt: Generator
  Visual Studio 17 2022
could not find any instance of Visual Studio.
```

**Cause** — `windows-latest` is a moving label. It now resolves to Windows Server 2025
with **Visual Studio 2026** (generator `Visual Studio 18 2026`), so the 2022 generator
matches nothing on the image.

**Fix** — pin the image: `runs-on: windows-2022`. This is also correct on principle here,
because the `win-build` container image pins `servercore:ltsc2022` with VS Build Tools
17.12, and the hosted stage is supposed to mirror the real toolchain rather than drift
ahead of it. `ubuntu-latest` is pinned to `ubuntu-24.04` for the same reason.

---

## 13. The ARM64 configure fails with "generator platform does not match"

**Symptom** — the x64 build succeeds, then the cross-compiled ARM64 configure fails:

```
CMake Error: Error: generator platform: ARM64
Does not match the platform used previously: x64
... CMake step for juce failed: 1
```

**Cause** — `FETCHCONTENT_BASE_DIR` holds more than the fetched sources. It also holds
FetchContent's per-dependency **sub-build** trees, and a sub-build's own CMake cache
records a generator platform. Sharing that directory between an x64 and an ARM64 configure
is what collides — sharing the *sources* is fine and is the whole point of the cache.

**Fix** — point each dependency at the tree the first configure already populated, using
CMake's documented "this dependency is already present" mechanism:

```
-DFETCHCONTENT_SOURCE_DIR_JUCE="$juce_src"
-DFETCHCONTENT_SOURCE_DIR_CLAP-JUCE-EXTENSIONS="$clap_src"
```

ARM64 then gets its own sub-build scaffolding while JUCE is cloned exactly once and both
architectures compile identical sources. Fail the step explicitly if those source trees are
absent, rather than letting CMake silently re-clone.

---

## 14. A macOS artifact check passes on Windows and fails on macOS

**Symptom** — `test -f "$plugin"` reports the `.clap` missing on macOS, although it is
plainly there in the listing.

**Cause** — on macOS **every plugin format is a bundle directory**. The Mach-O lives at
`<bundle>/Contents/MacOS/<name>`, so `-f` applied to the `.vst3`, `.component` or `.clap`
path can never be true.

**Fix** — walk `Contents/MacOS/` and assert on the binaries inside, which is a stronger
check than the one it replaces. Write it for **bash 3.2**: that is still what `/bin/bash`
is on macOS, and `mapfile`/`readarray` do not exist there.

The same fact drives the artifact contract: `actions/upload-artifact` flattens symlinks,
and a bundle without its symlinks is no longer a valid bundle, so macOS bundles are
**tarred** before upload and untarred before assertion.

---

## 15. A gate passes an artifact it should have failed

**Symptom** — an artifact whose manifest entry says `"required": false` is reported as
required, and the gate's verdict is wrong in a way that is easy to miss.

**Cause** — jq's alternative operator. `.required // true` looks like "default to true",
but `//` treats `false` **and** `null` as empty, so an explicit `false` is promoted to
`true`.

**Fix** — ask whether the key exists, never whether its value is falsy:

```bash
required="$(jq -r ".artifacts[$i] | if has(\"required\") then .required else true end" "$MANIFEST")"
```

This bug was in the gate itself, which is the worst place for it: a broken gate reports
success.

---

## 16. `'v26' is unavailable` in Package.swift on a Swift 6.3 toolchain

**Symptom** — `swift build` fails in seconds on a machine with Xcode 26 and Swift 6.3:

```
Package.swift:19:17: error: 'v26' is unavailable
note: 'v26' was introduced in PackageDescription 6.2
```

**Cause** — SwiftPM compiles the manifest against the `PackageDescription` library
matching the **declared tools version**, not the installed toolchain. The build log shows
`-package-description-version 6.0.0`. A `// swift-tools-version: 6.0` manifest therefore
cannot name a platform that 6.2 added, however new the compiler is.

**Fix** — raise the first line to `// swift-tools-version: 6.2`. This is independent of
`.swiftLanguageMode(.v6)`, which selects the language mode and has nothing to do with which
manifest API is available.

---

## 17. `packer validate` cannot run on Linux for the macOS image

**Symptom** — `packer init` fails to install the plugin:

```
error: no compatible binary for linux_amd64
```

**Cause** — `cirruslabs/tart` builds macOS VMs through Apple's Virtualization framework.
The plugin ships **darwin-only** binaries, because there is no Linux implementation to
ship. Compare the release assets: `darwin_arm64` returns 206, `linux_amd64` returns 404.

**Fix** — there is none on Linux, and this is not a defect to route around. The macOS
image template is syntax-checked on Linux and genuinely validated on the Apple Silicon
Mac. Any claim that the macOS image is "verified" must come from that machine.

---

## 18. SwiftUI: "unable to type-check this expression in reasonable time"

**Symptom** — the macOS app compiles on the Mac runner until one view, and then:

```
SigningView.swift:247:33: error: the compiler is unable to type-check this
expression in reasonable time; try breaking up the expression into distinct
sub-expressions
```

The named line is usually innocuous. Here it was two ternaries inside a `ForEach`
inside a `GroupBox`:

```swift
Image(systemName: identity.name == model.signId ? "largecircle.fill.circle" : "circle")
    .foregroundStyle(identity.name == model.signId ? .accentColor : .secondary)
```

**Cause** — SwiftUI view builders are deeply generic, and every `.foregroundStyle(...)`
with a leading-dot argument makes the solver consider every conforming type. Each
ternary multiplies the candidate set, and the cost is exponential in the nesting, not
linear in the line count. The compiler is not wrong about the code; it has given up
searching.

**Fix** — extract the row into its own `View` with **concrete** parameter types, and
hoist the conditions into typed properties:

```swift
private struct IdentityRow: View {
    let identity: SigningService.SigningIdentity
    let isSelected: Bool
    private var symbolName: String { isSelected ? "largecircle.fill.circle" : "circle" }
    private var symbolTint: Color { isSelected ? Color.accentColor : Color.secondary }
    ...
}
```

Naming `Color` explicitly instead of `.accentColor` is the part that actually does the
work: it removes the type variable the solver was searching over. Splitting the file
alone does not help if the sub-expressions stay equally inferred.

Note that `swiftc -parse` cannot catch this — it is a type-checking failure, not a
syntax one — so on a Linux development machine it only ever appears in CI.

---

## 19. The Windows app launches and no window appears

**Symptom** — `RunnerForge.exe` runs. Task Manager shows the process. Nothing is on
screen, there is no error, and nothing is written to the event log. Installing from the
MSI behaves identically.

**Cause** — nothing in the process ever constructed the window. `App.xaml` had no
`StartupUri`, and `App.OnStartup` built the service container, logged
`Runner Forge started` and returned. WPF then had an application with zero windows and
`ShutdownMode="OnMainWindowClose"`, so it neither showed anything nor exited.

The reason this survived so long is worth more than the fix: **every check in CI asked
whether the artifact was correct, and none asked whether the program did anything.**
The build was clean, the tests passed, the publish really was a single 62 MB
self-contained file, and the MSI's `File` table really did carry all 24 program files.
All of that was true of an executable that opened nothing.

**Fix** — create and show the window explicitly at the end of `OnStartup`:

```csharp
Services = new AppServices();
base.OnStartup(e);

var window = new MainWindow();
MainWindow = window;
window.Show();
```

Explicitly, and **not** via `StartupUri`, because `MainWindow`'s constructor reads
`((App)Application.Current).Services` and that must be assigned first. One ordered code
path beats two that can disagree.

Two things were added alongside it so the next startup failure is not silent either: a
`DispatcherUnhandledException` handler that reports and keeps the app alive, and a
`try/catch` around window creation that shows the error instead of leaving a running
process with nothing on screen.

**Prevention** — `ci-windows-app.yml` now launches the published executable and waits
for a real top-level window, failing if the process exits or stays alive for 60 seconds
with no window handle. `ci-macos-app.yml` runs the binary directly — not `open`, which
returns immediately and would report success for a crash — and asserts it is still alive
ten seconds later. SwiftUI's `WindowGroup` makes the exact WPF failure structurally
impossible on macOS, but a crash during launch is not.

---

## 20. The WPF app crashes on startup with 0xC00000FD, and nothing ever renders

**Symptom** — the window never appears. The process lives for ten to thirty seconds and
dies. The Windows Application event log says:

```
Faulting application name: RunnerForge.exe
Faulting module name: MSCTF.dll
Exception code: 0xc00000fd
```

`0xC00000FD` is `STATUS_STACK_OVERFLOW`. Earlier attempts surfaced as `0xC0000005`
instead, depending on where the stack happened to run out. **Both codes, and the
faulting module, are noise.** See "the wrong diagnosis" below.

**Cause** — `InvariantGlobalization`. The app's Release publish settings had:

```xml
<InvariantGlobalization>true</InvariantGlobalization>
```

which writes `System.Globalization.Invariant: true` and
`System.Globalization.PredefinedCulturesOnly: true` into `RunnerForge.runtimeconfig.json`.
It looks like a free size win on a self-contained publish. **It breaks every data binding
in a WPF app.**

Every `FrameworkElement` has a `Language` property that defaults to the `XmlLanguage`
`en-US`. Every `BindingExpression` that transfers a value asks that `XmlLanguage` for a
specific `CultureInfo`. With globalization invariant there is no non-neutral culture to
find, so the lookup throws:

```
System.InvalidOperationException: Cannot find non-neutral culture related to 'en-us'.
   at System.Windows.Markup.XmlLanguage.GetSpecificCulture()
   at System.Windows.Data.BindingExpressionBase.GetCulture()
   at System.Windows.Data.BindingExpression.TransferValue(...)
```

Once per binding. Forever. **WPF requires ICU** — this setting is for console and service
apps, not for anything with a visual tree.

**Fix** — set it to `false` (and leave a comment saying why, because the next person to
look for publish-size savings will find it again):

```xml
<InvariantGlobalization>false</InvariantGlobalization>
```

On `win-x64` this costs essentially nothing in size: .NET uses the ICU that ships with
Windows rather than bundling its own.

**The second bug, which the first one exposed** — the crash was not the exception. It was
the error *reporting*. `App.OnStartup` installed a `DispatcherUnhandledException` handler
that logged, showed a `MessageBox`, and set `e.Handled = true`.

`MessageBox.Show` pumps a nested message loop. That loop runs the same dispatcher work
that threw — the binding engine, the layout pass — on top of the stack frames already
there. A recurring exception therefore stacks a dialog on a dialog on a dialog until the
thread runs out of stack. The log shows 33 reports and then the process is gone.

So an unhandled-exception handler must never re-enter:

```csharp
if (_reportingError) return;                 // a report is already on screen
if (!_reportedErrors.Add(e.Exception.Message)) return;   // already shown once
```

Logging stays unconditional — the *count* is diagnostic. Only the modal dialog is
suppressed.

**The wrong diagnosis, recorded deliberately.** The first read of this was a WPF layout
feedback loop: the stack really did show

```
VirtualizingStackPanel.<InitializeViewport>b__0()
ContextLayoutManager.UpdateLayout()
Window.MeasureOverride ... Grid.MeasureCell ... DockPanel.MeasureOverride
```

and there really were wrapping `TextBlock`s bounded only by `MaxWidth` inside
virtualizing `ListView`s. It is a plausible mechanism, it fits the stack, and it was
wrong. Those frames were where the *nested message loop* happened to be standing, not the
cause. The "fix" — fixed `Width` instead of `MaxWidth`, `IsVirtualizing="False"` on six
lists — changed nothing, and the fixed widths were a regression in their own right, since
GridView columns are user-resizable and a fixed-width cell will not reflow. It was
reverted.

**What actually found it** was reading the app's own log instead of the stack trace. The
log had the real exception, in plain words, at the top — it just hadn't been looked at,
because a stack trace with a recognisable pattern in it is more persuasive than it
deserves to be. A stack trace tells you where a process died. It does not necessarily
tell you what went wrong.

**Why no earlier check caught it.** The Release-only `PropertyGroup` means Debug builds
are fine, so nothing local reproduces it. The 73 unit tests pass, because the failure
needs a live visual tree. The publish is genuinely one self-contained file and the MSI
genuinely contains all its program files. Every check asked whether the artifact was
correct; none asked whether the program worked. The smoke test now also reads the
startup log and fails on any `[Error]` line, because **an open window is not proof the
app works** — one fewer broken binding and this would have opened a window with nothing
in it and passed.


## 21. The app starts, no window appears, and there is no error anywhere

**Symptom** — no UI, no dialog, no crash. Possibly no log either. Reported twice
on a real machine after the CI smoke test was already proving a window opens.

**First: which build is it?** The log's first line now says. If there is no such
line, the build predates this entry and the answer is "not the fixed one":

```
Runner Forge 1.0.0 starting — Microsoft Windows NT 10.0.26100.0, 64-bit, session 1, user you
exe:    C:\Program Files\Runner Forge\RunnerForge.exe
log:    C:\Users\you\AppData\Local\RunnerForge\runnerforge.log
config: C:\ProgramData\RunnerForge\forge.json
```

The log is at `%LOCALAPPDATA%\RunnerForge\runnerforge.log`. **Where it stops is
the diagnosis** — that is what the breadcrumbs are for:

| Last line | Meaning |
| --- | --- |
| nothing at all | The process never reached `OnStartup`. Wrong exe, or it was blocked from running (SmartScreen, AV quarantine). |
| `config: …` then nothing | A handler was attached but building the services died. The next line says why. |
| `cannot write …falling back` | `%ProgramData%\RunnerForge` is not writable by you. The app now carries on with a per-user config; this is a warning, not a stop. |
| `another Runner Forge already holds…` | A previous copy is STILL RUNNING with no window. End `RunnerForge.exe` in Task Manager and start again. |
| `services ready` then nothing | `MainWindow`'s constructor threw. The error follows it. |
| `the main window is open` | The window genuinely exists. If you cannot see it, it is behind something or on a disconnected monitor — the line reports its size and position. |

**Causes found, in the order they were found:**

1. Nothing ever constructed `MainWindow` — TROUBLESHOOTING #19.
2. `InvariantGlobalization` broke every binding — TROUBLESHOOTING #20.
3. **The service container was built before the exception handlers were
   attached.** `App.OnStartup` did `Services = new AppServices()` first, with no
   `try`/`catch` and with `DispatcherUnhandledException` hooked up afterwards.
   Building services writes `%ProgramData%\RunnerForge\forge.json`, so it can
   fail on a real desktop in ways a CI runner never sees — an ACL on that folder
   left by an elevated run being the obvious one. When it did, the exception
   escaped `OnStartup` with no handler anywhere and the process died before a
   window, a dialog, or a single further log line existed.

**Fix** — the startup order is now: identify the build in the log, attach BOTH
`DispatcherUnhandledException` and `AppDomain.CurrentDomain.UnhandledException`,
and only then do anything that can fail — each step inside a `try`/`catch` that
reports. An unwritable machine-wide config falls back to a per-user one with a
logged warning rather than stopping: **failing to start is worse than a per-user
config.**

The general rule, which this file has now paid for three times: *any work done
before the error handlers are installed can only fail silently.* Put the
handlers first.


## 22. "forge.json is not valid: /github/owner must not be empty" on a fresh install

**Symptom** — the app opens a dialog on startup listing the GitHub fields as
invalid, and refuses to start:

```
Runner Forge could not start.

forge.json is not valid:
  /github/owner : must not be empty
  /github/appId : must not be empty
  /github/installationId : must not be empty
  /github/repos : at least one repository is required
```

**Cause — a bootstrap paradox.** On first run the app finds no config, writes a
default one, and opens. On the **second** run it reads that file back, validates
it, and rejects it — because `Validate` treated the four GitHub fields as
required. So the app refused to load the very file it had just written, and
there was no way out: **the only way to fill those fields in is the window that
will not open.**

Worse, on Windows two of the four — `appId` and `installationId` — **had no
editor anywhere in the app**. Even reaching the window would not have helped.
The product could not be configured through its own GUI.

**Fix — separate "invalid" from "not configured yet".** They are different
things and only one of them may block:

| | Blocks loading | Where it surfaces |
| --- | --- | --- |
| Malformed JSON, wrong `schemaVersion`, unknown runner class, replicas out of range, **a secret stored in forge.json** | **Yes** | Startup dialog |
| Empty `owner`, `appId`, `installationId`, `repos`; no runner classes | **No** | Setup banner in the window |

`ConfigStore.Validate` now covers only the first row — the things a text box
cannot fix. `ConfigStore.DescribeSetupGaps` covers the second and returns, for
each gap, **the page that fixes it** and where the value comes from. The window
shows them in a banner whose buttons navigate straight there, and the banner
disappears on its own once the last one is filled in.

Starting a runner is gated on the same list, and says which fields are missing.
Without that the start proceeds, fails minting a JIT config, and reports a
GitHub API error that never mentions the empty App ID that actually caused it.

`appId` and `installationId` now have editors on the **Credentials** page in
both apps, in a "GitHub App" group beside the private key they belong to.
Neither is a secret — both are shown openly in the GitHub UI — and that is
where the macOS app already put them, so the two apps still teach the same
layout.

**The general rule.** A GUI application's config file has two populations of
field: ones the program writes and ones the person writes. Validating the second
population at load time turns first-run into a dead end. Validate what the
program produced; *report* what the person has not yet supplied.


## 23. Preflight reports a hard block on a machine that is demonstrably working

**Symptom** — on a Windows 11 machine actively running Hyper-V, WSL2 with two
distributions and a Docker daemon that answers, Preflight said:

```
Fail   Hardware virtualization   Virtualization is disabled in firmware.
                                 Hyper-V cannot start without it.
```

marked as a **hard block** whose fix "cannot be changed from Windows". On the
same screen: `Windows feature: Microsoft-Hyper-V  enabled`, `WSL2 with a
distribution  2 distribution(s) installed`, `Docker daemon reachable  the
daemon is answering`. All three are impossible without virtualization.

**Cause** — `Win32_Processor.VirtualizationFirmwareEnabled` reports **False once
a hypervisor is running.** Hyper-V has already claimed VT-x, and the host OS no
longer sees the firmware flag. The property answers "can the host turn
virtualization on", not "is virtualization available" — and once Hyper-V owns
it, the answer is legitimately no.

So the check was most likely to fail on exactly the machines that were most
ready, and it delivered the most discouraging message the app has: a hard block
requiring a UEFI trip that was not needed.

**Fix** — ask whether a hypervisor is running *before* asking the CPU:

```sql
SELECT HypervisorPresent FROM Win32_ComputerSystem
```

If it is present, virtualization is working by definition and by demonstration;
report Pass. Only when no hypervisor is present do the firmware flags mean what
they appear to mean, and only then is the block real.

**The same screen carried a second false negative.** `wraptool on PATH` reported
`wraptool.exe is not on PATH` while `iLok driver: PACE support files present`
and `iLok dongle detected` both passed. The PACE installer does not add itself
to PATH — it installs under
`PACEAntiPiracy\Eden\Fusion\Versions\<version>\bin` — so PATH is the wrong
question. The Signing page already knew this and used `SigningService
.FindWraptool()` (WRAPTOOL override → PATH → versioned SDK path); Preflight was
still asking PATH, so the two pages disagreed about whether the same tool
existed. Both now call the same discovery, and the check is named "wraptool
available" rather than "wraptool on PATH", because the old name encoded the
wrong expectation.

**The general rule.** A readiness check must ask a question whose *false* answer
actually means "not ready". `VirtualizationFirmwareEnabled == false` and
`not on PATH` both have a common, healthy cause, so neither is that question. A
check that fires on working machines is worse than no check: it sends people to
fix things that are not broken, and it teaches them to ignore the page.


## 24. "Docker in Windows containers mode" blocked win-build — and its Fix broke linux-util

**Symptom** — Preflight failed with:

```
Fail   Docker in Windows containers mode
       OSType=linux. win-build is a Windows container and cannot run on the
       Linux engine.                                              [Fix]
```

and the Fix ran `DockerCli.exe -SwitchWindowsEngine`.

**Why this was wrong.** Runner Forge declares **both** `win-build`
(`WindowsContainer`) and `linux-util` (`LinuxContainer`) as `RunsOnWindows`, so
one PC is meant to host both. But the check demanded a single machine-wide mode,
and its own Fix switched the whole machine to the engine that `linux-util`
cannot use. **The app's remedy for one class broke the other.**

**What is actually true about Docker Desktop.** It runs two daemons — the
Windows container engine, and the Linux one in WSL2 — but the CLI endpoint
(`npipe:////./pipe/docker_engine`) points at exactly one at a time. There is no
supported way to address both through one endpoint; LCOW, which once allowed
it, was experimental and has been removed.

The fact the original design missed:

> **Switching engines does not stop running containers.**

Containers started under one engine keep running while the CLI is pointed at the
other. So a machine genuinely *can* host `win-build` and `linux-util`
simultaneously. What it cannot do is **start or inspect** both through one
endpoint at one moment.

**Fix — the engine is a per-operation concern, not a mode the user sets up
front.**

- `DockerService.EnsureEngineAsync(engine)` selects an engine, switching only
  when needed and waiting for the daemon to answer again (the switch restarts
  the endpoint, so the first command after it can otherwise fail spuriously).
- `RunnerSupervisor.StartClassAsync` selects the engine that class needs at the
  moment it starts it. Starting `linux-util` after `win-build` leaves
  `win-build` running.
- The Preflight check no longer reports a mode. It reports whether **both**
  engines are usable, and only Fails when `DockerCli.exe` is absent — because
  then the endpoint genuinely cannot move and the class needing the other engine
  genuinely is blocked.

**The consequence that is easy to miss.** A single `docker ps` sees only the
selected engine. A reap performed while Windows containers are selected would
report "clean" while a Linux container held a live runner still registered with
GitHub — exactly the stray state the Reaper exists to prevent. So `Stray` now
records which engine holds each container; the scan visits both; and removal is
grouped by engine, because `docker rm` against the wrong daemon reports
"No such container" and leaves it running.

Scanning the second engine costs a switch, so it is only done when the machine
is configured to run containers of both kinds.

**The general rule.** When a tool has a global mode, check whether the thing you
actually need is *the mode* or *an operation performed under it*. Requiring the
mode makes it a prerequisite the user must satisfy, forever, for everything —
and if two features need opposite modes, the requirement is not merely annoying,
it is unsatisfiable.


## 25. Three bugs from one real log

A log sent from a Spanish-locale Windows 11 machine, with the app running
correctly, contained three separate defects. Recorded together because they
share a shape: **assuming a value is stable when Windows varies it per machine.**

### 25a. "the generated certificate has no Code Signing EKU (found: Firma de c¢digo)"

```
[Info   ] signing  [make-signing-cert] generating a code-signing certificate for CN=EION Studios
[Info   ] signing  error: the generated certificate has no Code Signing EKU (found: Firma de c¢digo)
```

**The certificate was correct.** `make-signing-cert.ps1` verified it by comparing
`EnhancedKeyUsageList.FriendlyName` against the English string `'Code Signing'`.
That name is **localised by Windows** — "Firma de código" in Spanish,
"Codesignatur" in German — so the script worked on English Windows and refused
its own valid output everywhere else.

Fix: compare the OID, `1.3.6.1.5.5.7.3.3` (`id-kp-codeSigning`), which is the
same in every locale. The name is a label for humans; the OID is the identifier.

The C# `SigningService` already did this correctly, which made it worse: the
Signing page would list a certificate the generator had just declared invalid.

### 25b. `c¢digo` instead of `código`

The same line shows the second bug. `ProcessRunner` did not set
`StandardOutputEncoding`, so child output was decoded with the console's OEM
code page (CP850) instead of UTF-8. **A log that corrupts the message is worse
than one that omits it**, because the reader cannot tell which happened. Now
UTF-8 on both streams, and the scripts set `[Console]::OutputEncoding` so their
own output survives capture.

### 25c. The Copy button on the Logs page crashed

```
System.Runtime.InteropServices.COMException (0x800401D0): OpenClipboard failed
   at System.Windows.Clipboard.Flush()
   at RunnerForge.Views.LogsPage.OnCopyClick(...)
```

The Windows clipboard is a single system-wide resource opened exclusively. Any
other process holding it — a clipboard manager, a remote desktop client, Office,
a screenshot tool — makes `SetText` throw `CLIPBRD_E_CANT_OPEN`. It is transient
and common.

Copy now retries briefly, uses `SetDataObject(text, copy: true)` so the content
survives the app exiting, and on failure says so beside the button and suggests
Save to file. **An unhandled throw here is absurd on its face:** an error dialog
about failing to copy the error log, raised from the page people are on
*because* something already went wrong.

Save has the same treatment, for the same reason.

### 25d. The log did not say which build produced it

The log began at `services ready`. The build-identity breadcrumbs were written
by `LogBus.WriteBootstrap`, which goes **straight to the file** and bypasses the
in-memory ring buffer the Logs page reads — so the one channel people actually
use to send a log omitted the first thing anyone needs from it. The identity is
now repeated through the LogBus once it exists, and includes the current culture,
which is what would have made 25a obvious on sight.

**The general rule.** Anything Windows shows a human — an EKU name, an error
string, a folder name — is presentation, and varies by locale. Match on the
identifier underneath it: an OID, an HRESULT, a GUID, a known folder ID. And a
diagnostic path must be the most defensive code in the product, not the least:
it runs when things are already broken.

_More entries are added as failures are encountered. An entry is only added here
once it has actually been hit — this file is a log, not a list of things that
might go wrong._
