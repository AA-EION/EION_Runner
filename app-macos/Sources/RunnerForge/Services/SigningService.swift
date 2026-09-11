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

    /// Requirements for a mode, evaluated against this machine right now.
    public func requirements(for mode: SigningMode, config: ForgeConfig) async -> [SigningRequirement] {
        let hasAccount = !config.signing.paceAccount.isEmpty
        let hasPassword = await secretStore.has("pacePassword")
        let hasWcGuid = !config.signing.paceWcGuid.isEmpty
        let hasSignId = !config.signing.paceSignId.isEmpty
        let wraptool = ProcessRunner.isOnPath("wraptool")
        let driver = FileManager.default.fileExists(atPath: "/Library/Application Support/PACE")

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
                SigningRequirement(description: "paceWcGuid is set", satisfied: hasWcGuid,
                                   howToFix: "Enter the wrapping certificate GUID."),
                SigningRequirement(description: "paceSignId is set", satisfied: hasSignId,
                                   howToFix: "Enter the signing identifier."),
                SigningRequirement(description: "PACE Eden tools are available", satisfied: wraptool,
                                   howToFix: "Install Eden tools into the build image."),
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
                SigningRequirement(description: "paceWcGuid and paceSignId are set",
                                   satisfied: hasWcGuid && hasSignId,
                                   howToFix: "Enter both on the Signing page."),
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
                SigningRequirement(description: "wraptool on PATH", satisfied: wraptool,
                                   howToFix: "Install PACE Eden tools."),
                SigningRequirement(description: "PACE password is stored", satisfied: hasPassword,
                                   howToFix: "Enter it on the Credentials page."),
                SigningRequirement(description: "paceWcGuid and paceSignId are set",
                                   satisfied: hasWcGuid && hasSignId,
                                   howToFix: "Enter both on the Signing page."),
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
        guard let password = await secretStore.read("pacePassword"), !account.isEmpty else {
            await logBus.error("signing",
                "cannot sign: PACE_ACCOUNT and PACE_PASSWORD are required. They live in the Keychain and "
                + "are injected as environment variables; they never appear in forge.json.")
            return false
        }

        var arguments = [
            script,
            "--input", bundlePath,
            "--wcguid", config.signing.paceWcGuid,
            "--signid", config.signing.paceSignId,
        ]
        if dryRun { arguments.append("--dry-run") }

        let result = try await processRunner.run(
            "/bin/bash", arguments: arguments,
            environment: ["PACE_ACCOUNT": account, "PACE_PASSWORD": password],
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
