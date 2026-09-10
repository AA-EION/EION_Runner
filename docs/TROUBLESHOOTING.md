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

_More entries are added as failures are encountered. An entry is only added here once it
has actually been hit — this file is a log, not a list of things that might go wrong._
