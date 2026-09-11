# Signing

Three things get signed, and they are independent of one another:

1. **Windows binaries and the installer** — Authenticode, via Azure Trusted Signing.
2. **macOS binaries, the .pkg and the .dmg** — Apple Developer ID, then notarization
   and stapling.
3. **The AAX plugin** — PACE, via `wraptool`. This is the one with three modes.

## The two signatures on an AAX plugin

This trips people up constantly, so it goes first. **An AAX plugin carries two
independent signatures**, applied by the same `wraptool` invocation but checked
by different software for different reasons:

| | The PACE signature | The platform signature |
|---|---|---|
| What it is | PACE's digital signature, binding the plugin to PACE licensing | Apple `codesign` on macOS, Authenticode on Windows |
| Who checks it | **Pro Tools** | **Gatekeeper** / **SmartScreen** — the operating system |
| What it needs | your iLok signing certificate, or the Cloud Signing service | a platform certificate: Developer ID Application, or an Authenticode certificate from a Microsoft-approved CA |
| `wraptool` argument | `--wcguid`, or `--customernumber` + `--customername` | `--signid` |
| Without it | **Pro Tools refuses to load the plugin.** It reports "not valid 64 bit aax plugin" | the OS warns, blocks, or quarantines — but Pro Tools does not care |

The consequence is the whole reason the next section exists: **a self-signed
platform certificate does not stop a plugin loading in Pro Tools**, because
Pro Tools reads the PACE signature, not Apple's or Microsoft's. What it stops is
the plugin being *installable without friction* on someone else's machine.

## Who is signing: `--wcguid` or `--customernumber`

`wraptool` needs the publisher named, and takes it in one of two ways:

- **A Wrap Config GUID** — `signing.paceWcGuid`. Create it in PACE Central and
  choose **Signing Only** for the Customer Experience. This is the normal route.
- **A customer number and company name** — `signing.paceCustomerNumber` plus
  `signing.paceCustomerName`, both from **Company Details** in PACE Central's
  Admin menu.

They are alternatives, not a pair with a fallback, and **`wraptool` rejects a
customer number that arrives without the company name**. Runner Forge enforces
that in three places: the Signing page marks the requirement unmet, the signing
scripts refuse before they start, and the workflow templates emit a loud
`SET-A-WRAP-CONFIG-OR-CUSTOMER-NUMBER-ON-THE-SIGNING-PAGE` marker rather than an
empty argument. The alternative — emitting nothing — fails twenty minutes later
inside `wraptool`, with a message that never mentions the configuration.

## `--signid` is a NAME on macOS and a THUMBPRINT on Windows

Same argument, different content, and swapping them is the most common single
mistake in this whole document:

| Platform | `--signid` takes | Where to find it |
|---|---|---|
| macOS | the certificate's **common name**, quoted | `security find-identity -p codesigning` — the quoted name, **not** the hash beside it |
| Windows | the certificate's 40-character **SHA-1 thumbprint** | `certmgr` → Personal → Certificates → Details → Thumbprint, with the spaces removed |

Runner Forge's Signing page offers a **list of the certificates actually present
on the machine** and fills `paceSignId` in for you when you pick one. That is not
a convenience feature; it is there because retyping 40 hex characters, or
pasting a macOS hash where a name belongs, is how this step fails.

## No certificate yet? Use a self-signed one — for testing

PACE's own position, quoted rather than paraphrased:

> We only recommend self-signed certificates as a temporary step while learning
> how to use the PACE code-signing tools. PACE **does not recommend** that you
> use a self-signed certificate for your actual product.

Runner Forge agrees, and still makes it one button, because the alternative for
someone without a certificate is no signing at all — and therefore no way to
test the pipeline end to end.

**Signing page → No certificate yet? → Create self-signed certificate.**

Or from a terminal:

```bash
# macOS
scripts/make-signing-cert.sh --name "My Plugin Signing"
security find-identity -p codesigning          # confirm the name
```

```powershell
# Windows
.\scripts\make-signing-cert.ps1 -Subject "My Plugin Signing"
# prints the thumbprint to pass as --signid
```

Both generators apply exactly the settings PACE's Signing Resources page
specifies: 2048-bit RSA, Code Signing extended key usage, a self-signed root,
**no** Basic Constraints extension and **no** Subject Alternative Name. The macOS
generator uses an explicit OpenSSL extensions section because OpenSSL's stock
`v3_ca` section adds the very Basic Constraints extension the SDK says to leave
out, and it verifies the result before importing — if Basic Constraints somehow
appears, it aborts rather than importing a certificate that does not match the
documented shape.

### Where the private key goes, and where it must never go

You asked for the certificate to be "generated and stored with the plugin". The
certificate can be; **the private key must not be**, and Runner Forge will not do
it:

- The **private key** goes into the macOS login keychain or the Windows Personal
  certificate store. It never leaves that machine unless you explicitly ask for a
  `.p12`/`.pfx` backup, which is written mode-600 and whose password is read from
  the environment rather than the command line.
- The **certificate identity** — the name or the thumbprint — goes into
  `forge.json` as `signing.paceSignId`. That is a *reference to* a certificate,
  not a key, so it is safe there and safe in git.
- **Nothing goes inside the `.aaxplugin` bundle.** A signing key shipped with the
  artifact is a published key: anybody who downloads your plugin can then sign
  anything as you, including something you would never have signed. That is worse
  than not signing at all, because your name is on the result.

`.gitignore` already covers `*.p12`, `*.pfx`, `*.pem` and `*.key` at the top of
the file, so a backup written into the repository is ignored by default. Check
that before you write one somewhere else.

## Distributing a plugin signed with a self-signed certificate

This is the practical question, so here is the practical answer.

**It works in Pro Tools.** Pro Tools checks the PACE signature. As long as
`wraptool` applied that successfully — which requires a real iLok signing
certificate or Cloud Signing, and is *not* affected by which platform certificate
you used — the plugin loads and runs normally. `wraptool verify --verbose --in
<bundle>` is the check that matters, and Runner Forge runs it after every signing
operation rather than assuming.

**What breaks is installation, not operation**, and it breaks differently on each
platform.

### macOS

A self-signed certificate cannot be notarized — notarization requires a
Developer ID issued by Apple, and Apple will not notarize something signed by a
certificate it has never issued. So:

- Anything downloaded through a browser gets the quarantine flag, and Gatekeeper
  blocks it.
- Runner Forge's signing script therefore **omits `--dsigharden`** in self-signed
  mode. Those flags exist only to satisfy notarization, and adding them would
  imply a guarantee that is not there.

To distribute anyway, you have exactly three honest options:

1. **Ship an installer the user runs deliberately, and tell them how to open it.**
   The user gets one Gatekeeper dialog. Right-click → Open, or
   **System Settings → Privacy & Security → Open Anyway**, allows it once per
   artifact. Document this; do not let them discover it.
2. **Have the recipient strip quarantine explicitly**, which is an informed
   decision on their part and should be presented as one:
   ```bash
   xattr -dr com.apple.quarantine "/Library/Application Support/Avid/Audio/Plug-Ins/MyPlugin.aaxplugin"
   ```
3. **Install the certificate as a trusted root on each machine.** Honest, but it
   asks your users to extend trust to a certificate you control, for every future
   thing you sign with it. Reasonable inside one studio; not reasonable for public
   distribution.

Verify which situation you are in:

```bash
spctl -a -t exec -vv "/Library/Application Support/Avid/Audio/Plug-Ins/MyPlugin.aaxplugin"
# "accepted  source=Notarized Developer ID"  -> distributable
# "rejected"                                 -> self-signed, expect the above
```

### Windows

Authenticode with a self-signed certificate is untrusted everywhere it has not
been installed as a trusted root. Practically:

- SmartScreen warns on the installer. There is no way around this with a
  self-signed certificate, and an EV certificate is no longer an instant bypass
  either — since Microsoft's August 2024 Trusted Root Program update, OV and EV
  build SmartScreen reputation the same way, through clean download volume.
- The plugin itself still loads in Pro Tools. Pro Tools checks the PACE
  signature.

To distribute anyway: ship an installer, expect the "Windows protected your PC"
dialog, and tell users to click **More info → Run anyway**. Or install your
certificate into **Trusted Root Certification Authorities** on the target
machines — same trade-off as on macOS.

### Two Windows rules that bite regardless of certificate

Both come from PACE's AAX documentation and both produce the same unhelpful
Pro Tools error — *"not valid 64 bit aax plugin"* — so they are worth stating
plainly:

1. **`wraptool sign` operates IN PLACE on Windows.** `--in` and `--out` must be
   the same path. Copy the bundle to where it will live first, then sign it
   there. Runner Forge's script refuses a differing `-OutputPath` rather than
   producing something Pro Tools rejects.
2. **Never sign a renamed copy.** Renaming the outer `.aaxplugin` folder leaves
   the inner binary at `Contents\x64\<oldname>.aaxplugin`, and a folder whose name
   differs from its inner binary is a malformed plugin. Rename both, or neither.

And one macOS rule with the same symptom: **copy bundles with `ditto` or
`cp -R -H`**. An `.aaxplugin` is a directory full of symlinks, and an ordinary
copy flattens them, producing a bundle that signs but fails verification. The
emitted sign workflow uses `ditto` for exactly this reason.

## When you are ready to ship properly

Replace the self-signed certificate; nothing else changes.

- **macOS**: get a **Developer ID Application** certificate from your Apple
  Developer account — not a Mac App Store certificate and not a plain development
  certificate. Put it in the login keychain, pick it from the Signing page list,
  and untick self-signed. `wraptool` then gets `--dsigharden`, and notarization
  and stapling apply.
- **Windows**: get an Authenticode certificate from a Microsoft-approved CA.
  Since June 2023 the private key of any publicly trusted code-signing
  certificate must live on certified hardware, so a newly issued certificate
  arrives on a token and is used through the Windows Certificate Manager — refer
  to it by thumbprint. `--keyfile` with a PKCS#12 applies only to older
  software-key certificates and to private-trust certificates.

The signing configuration, the scripts, and the emitted workflows do not change
when you swap the certificate. Only `signing.paceSignId` and
`signing.paceSelfSigned` do.

## Credentials never reach a command line

`wraptool` reads its account credentials from the environment — `PF_ACCOUNT_ID`
and `PF_ACCOUNT_PASSWORD` — and every Runner Forge script uses that rather than
`--account` / `--password`. An argument list is readable from the process table
by any user on the machine; an environment is not.

There is exactly one exception, and it is documented rather than hidden:
`iloktool cloud --open` takes the password as an argument because PACE publishes
no environment equivalent for it. Runner Forge therefore makes opening a Cloud
session **opt-in** (`--open-session` / `-OpenSession`) instead of automatic, and
the better habit is to open the session once — by hand, or from iLok License
Manager's **File → Open Your Cloud Session** — because it persists until
explicitly closed. Routine runs then need neither the flag nor the password.

If you are signed in to iLok License Manager, the iLok signing path needs no
account or password at all: `wraptool` finds the account itself. Cloud signing
still needs both, because `--allowsigningservice` is documented as requiring them.

## AAX: pick one of three modes

`signing.mode` in `forge.json` selects the strategy. The Signing page shows a live
requirement checklist for whichever mode is selected, each item green or red.

### `cloud` — PACE Cloud 2 Cloud, no dongle anywhere

| Requirement | Checked by |
|---|---|
| PACE account name in config, password in the keystore | Credentials page `Test` |
| PACE Eden 5.0 tools present in the `win-build` image | image build |
| An **iLok Cloud enabled** Eden tools licence on the account | cloud-session probe |
| `signing.paceWcGuid` and `signing.paceSignId` set | config validation |

Signing happens **inside the build job**, in the `win-build` container. The flow opens
an iLok Cloud session, runs `wraptool sign` with `--allowsigningservice` appended, and
closes the session in a `finally` block so a failed build can never leak an open
session.

> Confirm with PACE that your entitlement includes the cloud signing service before
> relying on this mode. `--allowsigningservice` is the documented flag for it, but the
> flag is only half the story — the account has to be entitled. If it is not, `wraptool`
> fails at sign time with a licensing error, which `scripts/sign-aax-cloud.*` surfaces
> verbatim rather than swallowing.

### `windows-ilok` — the default

The dongle lives in the Windows PC, which runs 24/7.

| Requirement | Checked by |
|---|---|
| iLok driver installed on the Windows host | Preflight row 13 |
| Dongle physically detected | Preflight row 13 |
| `wraptool.exe` on `PATH` | Preflight row 13 |
| `win-ilok` runner enabled and online | Runners page |

The build splits into two jobs:

1. `win-build` (container) compiles and emits an **unsigned** `.aaxplugin`.
2. A second job on `runs-on: [self-hosted, windows, x64, ilok, forge]` downloads that
   artifact, signs it as a **host process**, and re-uploads it under the signed name.

**The `win-ilok` runner is deliberately not containerized, and deliberately has no
compiler.** A Windows container cannot see a USB device — there is no passthrough, no
flag, no workaround, and no plan for one. So the machine holding the dongle does
exactly one thing: it signs. Keeping a compiler off it means a compromised build cannot
turn into a compromised signing host.

### `macos-ilok`

Identical two-job split, targeting `[self-hosted, macos, arm64, ilok, forge]`. Use it
when the dongle lives in the Mac instead. `win-ilok` and `mac-ilok` are mutually
exclusive; both are disabled when the mode is `cloud`.

## Windows Authenticode — Azure Trusted Signing

`scripts/sign-windows-artifact.ps1`. A cloud HSM holds the key, so there is no
certificate file and no dongle, and it runs happily **inside** the container.

Config: `signing.windows.provider = "azure-trusted-signing"` plus `azureEndpoint`,
`azureAccount`, `azureProfile`. Credentials (`azureClientId`, `azureClientSecret`,
`azureTenantId`) live in the keystore and are injected as environment variables.

Set `provider = "none"` to skip Authenticode entirely; the artifacts are still produced,
just unsigned, and the workflow says so rather than pretending.

## macOS Developer ID — sign, notarize, staple

`scripts/sign-macos-artifact.sh` does all four steps in order:

1. **Ephemeral keychain.** Import the p12 into `runnerforge-ci-$$`, a keychain created
   for this job and deleted in a `trap`. The login keychain is never touched, so a
   parallel job cannot see this job's key and a crashed job cannot leave one unlocked.
2. **Sign inside-out.** `codesign --options runtime --timestamp`, innermost bundle
   first, outermost last.

   **Never `--deep`.** It is deprecated, and it mis-signs nested bundles — it applies
   the *outer* bundle's entitlements to inner code, which is wrong for a plugin that
   contains helper binaries. Signing inside-out is more typing and actually correct.
3. **`productsign`** the `.pkg` with the Developer ID **Installer** identity (a
   different certificate from the Application one).
4. **Notarize and staple.** `xcrun notarytool submit --wait` with the App Store Connect
   API key, then `xcrun stapler staple`.

   **Stapling is not optional.** Notarization records the result on Apple's servers;
   stapling writes the ticket into the artifact itself. Without it, a user who installs
   your plugin while offline — or behind a firewall that blocks Apple's OCSP responder —
   gets a Gatekeeper rejection for a plugin that *is* correctly notarized. Staple, then
   verify with `stapler validate`.

## Secrets used

None of these appear in `forge.json`. All live in the OS keystore.

| Key | Used by |
|---|---|
| `pacePassword` | all three AAX modes |
| `azureClientId`, `azureClientSecret`, `azureTenantId` | Windows Authenticode |
| `appleDevIdP12`, `appleDevIdP12Password` | macOS codesign / productsign |
| `appleAscIssuerId`, `appleAscKeyId`, `appleAscPrivateKey` | notarization |

When Runner Forge emits workflows on the Export page, it also emits a secrets checklist
naming every GitHub secret those workflows reference, what each one is, and where to get
it — and marks which ones it already holds locally.

## Every mode still produces the full artifact set

Whatever mode you pick, the §15 artifact contract holds. In `cloud` mode the signing
workflow is a passthrough, but it **still re-uploads** the artifact under the signed
name, so the artifact set is complete and identical in shape across all three modes. A
consumer of these artifacts never has to branch on signing mode.

If the AAX SDK is unavailable, the AAX artifacts are replaced by a `-aax-skipped`
marker artifact containing a one-line reason. The set is never silently short.
