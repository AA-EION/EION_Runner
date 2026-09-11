import Foundation

/// The contract between the GUI and every script: forge.json.
///
/// NO SECRET MAY EVER APPEAR IN THIS TYPE. It carries only non-secret
/// identifiers — app ids, installation ids, certificate common names, Azure
/// endpoint names. Every actual credential lives in the Keychain. A property
/// here that holds a password is a bug, not a feature.
public struct ForgeConfig: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var github: GitHubConfig
    public var runners: [RunnerConfig]
    public var signing: SigningConfig
    public var paths: PathsConfig
    public var retention: RetentionConfig
    public var limits: LimitsConfig
    public var verification: VerificationConfig

    /// Runner Forge sends no telemetry. The property exists so the absence is
    /// explicit and auditable rather than merely unmentioned.
    public var telemetry: Bool

    public init(
        schemaVersion: Int = 1,
        github: GitHubConfig = GitHubConfig(),
        runners: [RunnerConfig] = [],
        signing: SigningConfig = SigningConfig(),
        paths: PathsConfig = PathsConfig(),
        retention: RetentionConfig = RetentionConfig(),
        limits: LimitsConfig = LimitsConfig(),
        verification: VerificationConfig = VerificationConfig(),
        telemetry: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.github = github
        self.runners = runners
        self.signing = signing
        self.paths = paths
        self.retention = retention
        self.limits = limits
        self.verification = verification
        self.telemetry = telemetry
    }

    /// A config with every default filled in, for a first run.
    public static func makeDefault(workDir: String) -> ForgeConfig {
        ForgeConfig(
            runners: RunnerClass.all.map(RunnerConfig.init(forClass:)),
            paths: PathsConfig(workDir: workDir, aaxSdkSource: "")
        )
    }
}

public struct GitHubConfig: Codable, Sendable, Equatable {
    public var owner: String
    public var repos: [String]

    /// GitHub App id. NOT a secret; the private key lives in the Keychain.
    public var appId: String

    /// Installation id of the App on the owner account. NOT a secret.
    public var installationId: String

    public init(owner: String = "", repos: [String] = [], appId: String = "", installationId: String = "") {
        self.owner = owner
        self.repos = repos
        self.appId = appId
        self.installationId = installationId
    }
}

public struct RunnerConfig: Codable, Sendable, Equatable, Identifiable {
    public var classId: String
    public var enabled: Bool
    public var replicas: Int
    public var labels: [String]
    public var jobTimeoutMinutes: Int

    public var id: String { classId }

    public init(classId: String, enabled: Bool, replicas: Int, labels: [String], jobTimeoutMinutes: Int) {
        self.classId = classId
        self.enabled = enabled
        self.replicas = replicas
        self.labels = labels
        self.jobTimeoutMinutes = jobTimeoutMinutes
    }

    public init(forClass runnerClass: RunnerClass) {
        self.init(
            classId: runnerClass.classId,
            enabled: false,
            replicas: runnerClass.defaultReplicas,
            labels: runnerClass.labels,
            jobTimeoutMinutes: 60
        )
    }
}

public struct SigningConfig: Codable, Sendable, Equatable {
    /// Default is windows-ilok: the user's Windows PC runs 24/7.
    public var mode: String
    public var paceAccount: String

    /// Wrap Config GUID. The normal way to tell wraptool which publisher is
    /// signing. Either this OR the customer number/name pair is required.
    public var paceWcGuid: String

    /// PACE-issued customer number, the alternative to a Wrap Config. wraptool
    /// rejects it without the company name alongside, so the two travel
    /// together.
    public var paceCustomerNumber: String
    public var paceCustomerName: String

    /// The PLATFORM signing identity — an Apple certificate common name on
    /// macOS, a 40-character SHA-1 thumbprint on Windows. Not a secret: it
    /// names a certificate, it is not the key.
    public var paceSignId: String

    /// True when paceSignId names a SELF-SIGNED certificate. It changes what
    /// the signing scripts do (no notarization hardening, which cannot help a
    /// certificate Apple has never seen) and what the UI promises.
    public var paceSelfSigned: Bool

    /// Append --allowsigningservice to wraptool in cloud mode.
    public var allowSigningService: Bool
    public var windows: WindowsSigningConfig
    public var macos: MacosSigningConfig

    /// Explicit CodingKeys plus a decoder with defaults, so a forge.json
    /// written before these fields existed still loads instead of throwing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? SigningMode.windowsIlok.rawValue
        paceAccount = try container.decodeIfPresent(String.self, forKey: .paceAccount) ?? ""
        paceWcGuid = try container.decodeIfPresent(String.self, forKey: .paceWcGuid) ?? ""
        paceCustomerNumber = try container.decodeIfPresent(String.self, forKey: .paceCustomerNumber) ?? ""
        paceCustomerName = try container.decodeIfPresent(String.self, forKey: .paceCustomerName) ?? ""
        paceSignId = try container.decodeIfPresent(String.self, forKey: .paceSignId) ?? ""
        paceSelfSigned = try container.decodeIfPresent(Bool.self, forKey: .paceSelfSigned) ?? false
        allowSigningService = try container.decodeIfPresent(Bool.self, forKey: .allowSigningService) ?? true
        windows = try container.decodeIfPresent(WindowsSigningConfig.self, forKey: .windows) ?? WindowsSigningConfig()
        macos = try container.decodeIfPresent(MacosSigningConfig.self, forKey: .macos) ?? MacosSigningConfig()
    }

    /// True when wraptool has everything it needs to name the publisher.
    public var hasPublisherIdentity: Bool {
        !paceWcGuid.trimmingCharacters(in: .whitespaces).isEmpty
            || (!paceCustomerNumber.trimmingCharacters(in: .whitespaces).isEmpty
                && !paceCustomerName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    public var modeValue: SigningMode {
        get { SigningMode(rawValue: mode) ?? .windowsIlok }
        set { mode = newValue.rawValue }
    }

    public init(
        mode: String = SigningMode.windowsIlok.rawValue,
        paceAccount: String = "",
        paceWcGuid: String = "",
        paceCustomerNumber: String = "",
        paceCustomerName: String = "",
        paceSignId: String = "",
        paceSelfSigned: Bool = false,
        allowSigningService: Bool = true,
        windows: WindowsSigningConfig = WindowsSigningConfig(),
        macos: MacosSigningConfig = MacosSigningConfig()
    ) {
        self.mode = mode
        self.paceAccount = paceAccount
        self.paceWcGuid = paceWcGuid
        self.paceCustomerNumber = paceCustomerNumber
        self.paceCustomerName = paceCustomerName
        self.paceSignId = paceSignId
        self.paceSelfSigned = paceSelfSigned
        self.allowSigningService = allowSigningService
        self.windows = windows
        self.macos = macos
    }
}

public struct WindowsSigningConfig: Codable, Sendable, Equatable {
    public var provider: String
    public var azureEndpoint: String
    public var azureAccount: String
    public var azureProfile: String

    public init(
        provider: String = WindowsSigningProvider.azureTrustedSigning.rawValue,
        azureEndpoint: String = "",
        azureAccount: String = "",
        azureProfile: String = ""
    ) {
        self.provider = provider
        self.azureEndpoint = azureEndpoint
        self.azureAccount = azureAccount
        self.azureProfile = azureProfile
    }
}

public struct MacosSigningConfig: Codable, Sendable, Equatable {
    public var teamId: String

    /// A certificate common name, not a key. Safe to store here.
    public var devIdAppIdentity: String
    public var devIdInstallerIdentity: String

    /// Stapling follows notarization. Turning this off means the artifact fails
    /// Gatekeeper on any machine but the one that built it.
    public var notarize: Bool

    public init(
        teamId: String = "",
        devIdAppIdentity: String = "",
        devIdInstallerIdentity: String = "",
        notarize: Bool = true
    ) {
        self.teamId = teamId
        self.devIdAppIdentity = devIdAppIdentity
        self.devIdInstallerIdentity = devIdInstallerIdentity
        self.notarize = notarize
    }
}

public struct PathsConfig: Codable, Sendable, Equatable {
    public var workDir: String

    /// Local zip path or private git URL for the Avid AAX SDK. NEVER baked into
    /// an image; mounted from a local volume at build time. Empty means AAX
    /// targets are skipped and the workflow emits a marker naming the reason.
    public var aaxSdkSource: String

    public init(workDir: String = "", aaxSdkSource: String = "") {
        self.workDir = workDir
        self.aaxSdkSource = aaxSdkSource
    }
}

public struct RetentionConfig: Codable, Sendable, Equatable {
    /// Always true. Rebuilding base images costs tens of minutes.
    public var keepBaseImages: Bool

    /// Always true. Only per-job VM clones are ever deleted.
    public var keepTartImages: Bool

    public var keepCaches: Bool
    public var purgeOnExit: Bool
    public var logRetentionDays: Int

    public init(
        keepBaseImages: Bool = true,
        keepTartImages: Bool = true,
        keepCaches: Bool = true,
        purgeOnExit: Bool = true,
        logRetentionDays: Int = 7
    ) {
        self.keepBaseImages = keepBaseImages
        self.keepTartImages = keepTartImages
        self.keepCaches = keepCaches
        self.purgeOnExit = purgeOnExit
        self.logRetentionDays = logRetentionDays
    }
}

public struct LimitsConfig: Codable, Sendable, Equatable {
    public var maxDiskGb: Int
    public init(maxDiskGb: Int = 120) { self.maxDiskGb = maxDiskGb }
}

public struct VerificationConfig: Codable, Sendable, Equatable {
    public var canaryRepo: String

    /// Consecutive green runs required before the setup counts as stable.
    public var requiredGreenRuns: Int

    /// Written by SelfTestService. Nil until the first self-test.
    public var lastProof: SelfTestResult?

    public init(canaryRepo: String = "", requiredGreenRuns: Int = 3, lastProof: SelfTestResult? = nil) {
        self.canaryRepo = canaryRepo
        self.requiredGreenRuns = requiredGreenRuns
        self.lastProof = lastProof
    }
}
