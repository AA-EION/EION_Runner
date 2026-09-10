# Signing

Three things get signed, and they are independent of one another:

1. **Windows binaries and the installer** — Authenticode, via Azure Trusted Signing.
2. **macOS binaries, the .pkg and the .dmg** — Apple Developer ID, then notarization
   and stapling.
3. **The AAX plugin** — PACE, via `wraptool`. This is the one with three modes.

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
