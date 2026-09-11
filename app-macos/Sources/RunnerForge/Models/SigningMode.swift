import Foundation

/// The three AAX signing strategies.
public enum SigningMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// PACE Cloud 2 Cloud. No dongle anywhere; signs inside the build job.
    case cloud

    /// Physical dongle in the Windows PC. The default: that machine runs 24/7.
    case windowsIlok = "windows-ilok"

    /// Physical dongle in the Mac.
    case macosIlok = "macos-ilok"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cloud: "Cloud (PACE Cloud 2 Cloud)"
        case .windowsIlok: "Windows iLok (this machine)"
        case .macosIlok: "macOS iLok (the Mac)"
        }
    }
}

/// Authenticode provider for Windows binaries. Independent of AAX signing.
public enum WindowsSigningProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Do not Authenticode-sign. Artifacts are still produced, just unsigned.
    case none

    /// Azure Trusted Signing. A cloud HSM holds the key, so this runs in the container.
    case azureTrustedSigning = "azure-trusted-signing"

    public var id: String { rawValue }
}

/// One item in a signing mode's live requirement checklist.
public struct SigningRequirement: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let description: String
    public let satisfied: Bool
    public let howToFix: String?

    public init(description: String, satisfied: Bool, howToFix: String? = nil) {
        self.description = description
        self.satisfied = satisfied
        self.howToFix = howToFix
    }
}
