import Foundation

/// The live requirement checklist behind the Signing page, and the entry points
/// that invoke the signing scripts.
///
/// Selecting a mode whose requirements are unmet is ALLOWED — people configure
/// before they install — but it raises a persistent warning and disables Export,
/// because emitting a workflow that cannot sign is worse than refusing to emit
/// one.
public struct SigningService: Sendable {
    private let logBus: LogBus
    private let processRunner: ProcessRunner
    private let secretStore: SecretStore

    public init(logBus: LogBus, processRunner: ProcessRunner, secretStore: SecretStore) {
        self.logBus = logBus
        self.processRunner = processRunner
        self.secretStore = secretStore
    }

    // -----------------------------------------------------------------------
    // Finding wraptool
    //
    // The Fusion SDK installs wraptool at a VERSIONED path that is not on PATH,
    // so `command -v wraptool` answers "no" on a machine where it is installed
    // and working. Checking PATH alone is how a correctly configured Mac ends
    // up staring at a red requirement row it cannot clear.
    // -----------------------------------------------------------------------
    public static let sdkVersionsDirectory = "/Applications/PACEAntiPiracy/Eden/Fusion/Versions"

    /// The path to wraptool, or nil. Honours a WRAPTOOL override first so an
    /// unusual install can be pointed at without editing anything.
    public static func findWraptool() -> String? {
        if let override = ProcessInfo.processInfo.environment["WRAPTOOL"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        if let onPath = ProcessRunner.resolveOnPath("wraptool") { return onPath }

        let manager = FileManager.default
        guard let versions = try? manager.contentsOfDirectory(atPath: sdkVersionsDirectory) else {
            return nil
        }
        // Newest major version first: "10" must sort above "6".
        let sorted = versions.sorted { (Int($0) ?? -1) > (Int($1) ?? -1) }
        for version in sorted {
            let candidate = "\(sdkVersionsDirectory)/\(version)/bin/wraptool"
            if manager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `iloktool` opens iLok Cloud sessions. It ships with iLok License Manager,
    /// NOT with the Fusion SDK, which is why it is looked up separately.
    public static func findIloktool() -> String? {
        if let override = ProcessInfo.processInfo.environment["ILOKTOOL"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        return ProcessRunner.resolveOnPath("iloktool")
    }

    /// One row in the signing-identity picker.
    public struct SigningIdentity: Sendable, Identifiable, Hashable {
        /// The quoted name from `security find-identity`. This exact string is
        /// what wraptool takes as --signid on macOS — not the hash beside it.
        public let name: String
        public let hash: String

        /// True when macOS reports the certificate as untrusted, which is what a
        /// self-signed root looks like until it is explicitly trusted.
        public let untrusted: Bool

        public var id: String { hash }

        public init(name: String, hash: String, untrusted: Bool) {
            self.name = name
            self.hash = hash
            self.untrusted = untrusted
        }
    }

    /// Every code-signing identity this user can sign with, newest first.
    ///
    /// Offering a list instead of a text field removes the single most common
    /// mistake here: pasting the 40-character hash into --signid, which on macOS
    /// wants the NAME.
    public func listSigningIdentities() async -> [SigningIdentity] {
        guard let result = try? await processRunner.run(
            "/usr/bin/security", arguments: ["find-identity", "-p", "codesigning"],
            logSource: "signing", streamOutput: false)
        else { return [] }

        var identities: [SigningIdentity] = []
        for line in result.standardOutput.split(separator: "\n") {
            // Lines look like:  1) <40 hex> "Name Here" (CSSMERR_TP_NOT_TRUSTED)
            let text = String(line)
            guard let firstQuote = text.firstIndex(of: "\""),
                  let lastQuote = text.lastIndex(of: "\""),
                  firstQuote < lastQuote else { continue }

            let name = String(text[text.index(after: firstQuote)..<lastQuote])
            let prefix = text[text.startIndex..<firstQuote]
            let hash = prefix.split(separator: " ").last.map(String.init) ?? ""
            guard !name.isEmpty, !hash.isEmpty else { continue }

            identities.append(SigningIdentity(
                name: name, hash: hash,
                untrusted: text.contains("NOT_TRUSTED")))
        }
        return identities
    }

    /// Creates a self-signed code-signing certificate by running the shipped
    /// generator, which applies exactly the settings PACE's Signing Resources
    /// page specifies.
    ///
    /// The private key lands in the login keychain. It is never written beside
    /// the plugin and never shipped inside the bundle: a signing key that
    /// travels with the artifact is a published key.
    @discardableResult
    public func generateSelfSignedCertificate(
        name: String, scriptsDirectory: String
    ) async -> Bool {
        let script = (scriptsDirectory as NSString).appendingPathComponent("make-signing-cert.sh")
        guard FileManager.default.fileExists(atPath: script) else {
            await logBus.error("signing", "certificate generator not found: \(script)")
            return false
        }

        await logBus.warning("signing",
            "Creating a SELF-SIGNED certificate. PACE recommends these only while learning the "
            + "signing tools. A plugin signed with one still loads in Pro Tools — the PACE signature "
            + "is what Pro Tools checks — but it cannot be notarized, so Gatekeeper blocks it on "
            + "every Mac except ones told to trust the certificate. See docs/SIGNING.md.")

        let result = try? await processRunner.run(
            "/bin/bash", arguments: [script, "--name", name],
            logSource: "signing")

        return result?.succeeded == true
    }

    /// Requirements for a mode, evaluated against this machine right now.
    public func requirements(for mode: SigningMode, config: ForgeConfig) async -> [SigningRequirement] {
        let hasAccount = !config.signing.paceAccount.isEmpty
        let hasPassword = await secretStore.has("pacePassword")
        let hasPublisher = config.signing.hasPublisherIdentity
        let wraptoolPath = Self.findWraptool()
        let wraptool = wraptoolPath != nil
        let driver = FileManager.default.fileExists(atPath: "/Library/Application Support/PACE")

        // On macOS --signid is an identity NAME, so "set" is not enough: the
        // identity has to actually exist in a keychain this user can read.
        let identities = await listSigningIdentities()
        let configuredId = config.signing.paceSignId.trimmingCharacters(in: .whitespaces)
        let identity = identities.first { $0.name == configuredId }
        let hasSignId = identity != nil

        let signIdFix: String = {
            if configuredId.isEmpty {
                return identities.isEmpty
                    ? "No code-signing identity exists on this Mac. Use Create self-signed "
                    + "certificate on the Signing page, or install a Developer ID Application "
                    + "certificate from your Apple Developer account."
                    : "Pick one from the list on the Signing page."
            }
            return "No identity named \"\(configuredId)\" is in your keychain. "
                 + "On macOS --signid takes the NAME, not the 40-character hash."
        }()

        let publisherFix =
            "Set a Wrap Config GUID, or a customer number AND company name — wraptool needs "
            + "one or the other, and rejects a customer number on its own."

        let wraptoolFix =
            "Install the PACE Fusion SDK. Runner Forge looks on PATH and under "
            + "\(Self.sdkVersionsDirectory)/*/bin/wraptool, so it finds a normal SDK install "
            + "even though the SDK does not add itself to PATH."

        func classEnabled(_ classId: String) -> Bool {
            config.runners.first { $0.classId == classId }?.enabled ?? false
        }

        switch mode {
        case .cloud:
            return [
                SigningRequirement(description: "PACE account name is set", satisfied: hasAccount,
                                   howToFix: "Enter it on the Signing page."),
                SigningRequirement(description: "PACE password is stored", satisfied: hasPassword,
                                   howToFix: "Enter it on the Credentials page."),
                SigningRequirement(description: "Publisher identified (Wrap Config, or customer number + name)",
                                   satisfied: hasPublisher, howToFix: publisherFix),
                SigningRequirement(description: "Signing identity exists in a keychain",
                                   satisfied: hasSignId, howToFix: signIdFix),
                SigningRequirement(description: "wraptool found", satisfied: wraptool,
                                   howToFix: wraptoolFix),
                SigningRequirement(
                    description: "iloktool found (opens the iLok Cloud session)",
                    satisfied: Self.findIloktool() != nil,
                    howToFix: "Install iLok License Manager from ilok.com — iloktool ships with it, "
                            + "not with the Fusion SDK. Or open the Cloud session by hand from "
                            + "iLok License Manager: File > Open Your Cloud Session."),
                SigningRequirement(
                    description: "The account is entitled to iLok Cloud (Cloud 2 Cloud)",
                    satisfied: false,
                    howToFix: "CONFIRM THIS WITH PACE. --allowsigningservice is the documented flag, but "
                            + "the flag is only half the story: the ACCOUNT has to be entitled. Runner "
                            + "Forge cannot verify this for you, so it stays unmet until you have checked."),
            ]

        case .windowsIlok:
            return [
                SigningRequirement(description: "The dongle is in the Windows PC, not this Mac",
                                   satisfied: true,
                                   howToFix: "windows-ilok signs on the PC. This Mac only needs the configuration."),
                SigningRequirement(description: "PACE password is stored", satisfied: hasPassword,
                                   howToFix: "Enter it on the Credentials page."),
                SigningRequirement(description: "Publisher identified (Wrap Config, or customer number + name)",
                                   satisfied: hasPublisher, howToFix: publisherFix),
                SigningRequirement(description: "win-ilok runner enabled",
                                   satisfied: classEnabled("win-ilok"),
                                   howToFix: "Enable it on the Windows machine."),
                SigningRequirement(description: "mac-ilok is disabled",
                                   satisfied: !classEnabled("mac-ilok"),
                                   howToFix: "The two iLok classes are mutually exclusive: the dongle is in "
                                           + "one machine or the other."),
            ]

        case .macosIlok:
            return [
                SigningRequirement(description: "iLok driver installed on this Mac", satisfied: driver,
                                   howToFix: "Install iLok License Manager."),
                SigningRequirement(
                    description: "Dongle detected", satisfied: false,
                    howToFix: "Plug the dongle into this Mac. Preflight reports the live state; a container "
                            + "can never see a USB device, which is why mac-ilok is a host process."),
                SigningRequirement(description: "wraptool found", satisfied: wraptool,
                                   howToFix: wraptoolFix),
                SigningRequirement(description: "PACE password is stored", satisfied: hasPassword,
                                   howToFix: "Enter it on the Credentials page (optional if iLok "
                                           + "License Manager is signed in — wraptool finds the "
                                           + "account itself)."),
                SigningRequirement(description: "Publisher identified (Wrap Config, or customer number + name)",
                                   satisfied: hasPublisher, howToFix: publisherFix),
                SigningRequirement(description: "Signing identity exists in a keychain",
                                   satisfied: hasSignId, howToFix: signIdFix),
                SigningRequirement(
                    description: identity?.untrusted == true || config.signing.paceSelfSigned
                        ? "Identity is SELF-SIGNED — testing only"
                        : "Identity is trusted by this Mac",
                    satisfied: !(identity?.untrusted ?? false),
                    howToFix: "macOS reports this certificate as untrusted, which is what a "
                            + "self-signed root looks like. The plugin will still load in Pro "
                            + "Tools — Pro Tools checks the PACE signature, not Apple's — but it "
                            + "cannot be notarized and Gatekeeper blocks it elsewhere. "
                            + "See docs/SIGNING.md before distributing it."),
                SigningRequirement(description: "mac-ilok runner enabled",
                                   satisfied: classEnabled("mac-ilok"),
                                   howToFix: "Enable it on the Runners page."),
            ]
        }
    }

    /// True when every requirement is met and Export may proceed.
    public func isSatisfied(mode: SigningMode, config: ForgeConfig) async -> Bool {
        await requirements(for: mode, config: config).allSatisfy(\.satisfied)
    }

    /// Runs the AAX signing script for the configured mode.
    ///
    /// Credentials go into the child's ENVIRONMENT, never its arguments: an
    /// argument list is readable from the process list by any user on the machine.
    public func signAax(
        config: ForgeConfig, scriptsDirectory: String, bundlePath: String, dryRun: Bool
    ) async throws -> Bool {
        let script = (scriptsDirectory as NSString)
            .appendingPathComponent(config.signing.modeValue == .cloud
                                    ? "sign-aax-cloud.sh" : "sign-aax-ilok.sh")

        guard FileManager.default.fileExists(atPath: script) else {
            await logBus.error("signing", "signing script not found: \(script)")
            return false
        }

        let account = await secretStore.read("paceAccount") ?? config.signing.paceAccount
        let password = await secretStore.read("pacePassword")

        // Cloud signing REQUIRES both: PACE documents --allowsigningservice as
        // needing an account and a password. The iLok path does not — wraptool
        // finds the account itself when iLok License Manager is signed in — so
        // demanding them there would block a setup that already works.
        if config.signing.modeValue == .cloud, account.isEmpty || (password ?? "").isEmpty {
            await logBus.error("signing",
                "cannot cloud-sign: PACE_ACCOUNT and PACE_PASSWORD are both required, because "
                + "--allowsigningservice is documented as needing them. They live in the Keychain "
                + "and are injected as environment variables; they never appear in forge.json.")
            return false
        }

        guard config.signing.hasPublisherIdentity else {
            await logBus.error("signing",
                "cannot sign: wraptool needs the publisher named, by a Wrap Config GUID or by a "
                + "customer number AND company name. It rejects a customer number on its own.")
            return false
        }

        var arguments = [script, "--input", bundlePath, "--signid", config.signing.paceSignId]

        // EITHER a Wrap Config GUID OR the customer number paired with the
        // company name. wraptool rejects the number without the name.
        let guid = config.signing.paceWcGuid.trimmingCharacters(in: .whitespaces)
        if !guid.isEmpty {
            arguments += ["--wcguid", guid]
        } else {
            arguments += [
                "--customernumber", config.signing.paceCustomerNumber,
                "--customername", config.signing.paceCustomerName,
            ]
        }

        // A self-signed certificate cannot be notarized, so the hardening flags
        // that exist to satisfy notarization are left off rather than implying a
        // guarantee that is not there.
        if config.signing.paceSelfSigned { arguments.append("--self-signed") }

        // Cloud signing needs an open iLok Cloud session. Opening one is the
        // only documented call that puts the password on a command line, so it
        // is requested explicitly rather than assumed.
        if config.signing.modeValue == .cloud { arguments.append("--open-session") }

        if dryRun { arguments.append("--dry-run") }

        var environment: [String: String] = [:]
        if !account.isEmpty { environment["PACE_ACCOUNT"] = account }
        if let password, !password.isEmpty { environment["PACE_PASSWORD"] = password }

        let result = try await processRunner.run(
            "/bin/bash", arguments: arguments,
            environment: environment,
            logSource: "signing")

        return result.succeeded
    }

    /// Signs, notarizes and staples the macOS artifacts.
    public func signMacosArtifacts(
        config: ForgeConfig, scriptsDirectory: String, artifactDirectory: String,
        pkgPath: String?, dmgPath: String?, dryRun: Bool
    ) async throws -> Bool {
        let script = (scriptsDirectory as NSString).appendingPathComponent("sign-macos-artifact.sh")

        guard FileManager.default.fileExists(atPath: script) else {
            await logBus.error("signing", "signing script not found: \(script)")
            return false
        }

        var environment: [String: String] = [:]
        let required = [
            "appleDevIdP12": "APPLE_DEV_ID_P12",
            "appleDevIdP12Password": "APPLE_DEV_ID_P12_PASSWORD",
        ]

        for (key, variable) in required {
            guard let value = await secretStore.read(key) else {
                await logBus.error("signing",
                    "cannot sign: '\(key)' is not stored. Add it on the Credentials page.")
                return false
            }
            environment[variable] = value
        }

        if config.signing.macos.notarize {
            let notarization = [
                "appleAscIssuerId": "APPLE_ASC_ISSUER_ID",
                "appleAscKeyId": "APPLE_ASC_KEY_ID",
                "appleAscPrivateKey": "APPLE_ASC_PRIVATE_KEY",
            ]
            for (key, variable) in notarization {
                guard let value = await secretStore.read(key) else {
                    await logBus.error("signing",
                        "cannot notarize: '\(key)' is not stored. Without notarization and stapling the "
                        + "artifact fails Gatekeeper on any machine but this one.")
                    return false
                }
                environment[variable] = value
            }
        }

        var arguments = [
            script,
            "--artifact-dir", artifactDirectory,
            "--app-identity", config.signing.macos.devIdAppIdentity,
            "--installer-identity", config.signing.macos.devIdInstallerIdentity,
            "--team-id", config.signing.macos.teamId,
        ]

        if let pkgPath { arguments += ["--pkg", pkgPath] }
        if let dmgPath { arguments += ["--dmg", dmgPath] }
        if !config.signing.macos.notarize { arguments.append("--no-notarize") }
        if dryRun { arguments.append("--dry-run") }

        let result = try await processRunner.run(
            "/bin/bash", arguments: arguments, environment: environment, logSource: "signing")

        return result.succeeded
    }
}
