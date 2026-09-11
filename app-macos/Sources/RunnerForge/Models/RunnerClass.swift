import Foundation

/// The five runner shapes Runner Forge knows how to host.
///
/// The raw values are the `classId` written to forge.json and consumed by every
/// script, so they are part of the on-disk contract and must not be renamed
/// casually.
public enum RunnerClassId: String, Codable, Sendable, CaseIterable {
    case winBuild = "win-build"
    case linuxUtil = "linux-util"
    case macBuild = "mac-build"
    case winIlok = "win-ilok"
    case macIlok = "mac-ilok"
}

/// Where a runner of a given class actually executes.
public enum RunnerIsolation: String, Sendable {
    case windowsContainer
    case linuxContainer
    case tartVmClone

    /// A plain host process. Used only by the iLok classes, because a container
    /// cannot see a USB device and there is no passthrough that changes that.
    case hostProcess
}

/// The immutable facts about a runner class. Everything here is fixed by the
/// design, not by configuration.
public struct RunnerClass: Sendable, Identifiable, Hashable {
    public let id: RunnerClassId
    public let displayName: String
    public let isolation: RunnerIsolation
    public let labels: [String]
    public let minReplicas: Int
    public let maxReplicas: Int
    public let defaultReplicas: Int

    /// True when this class runs on the Apple Silicon host.
    public let runsOnMac: Bool

    /// Why this class is not containerized, or nil when it is. Shown in the UI so
    /// the design decision is visible rather than looking like an oversight.
    public let notContainerizedReason: String?

    public var classId: String { id.rawValue }

    public var isIlok: Bool { id == .winIlok || id == .macIlok }

    /// Replicas are fixed at 1 for the iLok classes: there is one dongle.
    public var replicasAreFixed: Bool { isIlok }

    // -----------------------------------------------------------------------
    // The canonical catalogue. These label sets are the contract with every
    // workflow's runs-on; changing one here without changing the workflow means
    // jobs queue forever against a runner that never appears.
    // -----------------------------------------------------------------------
    public static let winBuild = RunnerClass(
        id: .winBuild,
        displayName: "Windows build",
        isolation: .windowsContainer,
        labels: ["self-hosted", "windows", "x64", "container", "forge"],
        minReplicas: 1, maxReplicas: 4, defaultReplicas: 2,
        runsOnMac: false,
        notContainerizedReason: nil
    )

    public static let linuxUtil = RunnerClass(
        id: .linuxUtil,
        displayName: "Linux utility",
        isolation: .linuxContainer,
        labels: ["self-hosted", "linux", "x64", "container", "forge"],
        minReplicas: 1, maxReplicas: 4, defaultReplicas: 1,
        runsOnMac: false,
        notContainerizedReason: nil
    )

    public static let macBuild = RunnerClass(
        id: .macBuild,
        displayName: "macOS build",
        isolation: .tartVmClone,
        labels: ["self-hosted", "macos", "arm64", "tart", "forge"],
        minReplicas: 1, maxReplicas: 2, defaultReplicas: 1,
        runsOnMac: true,
        notContainerizedReason: nil
    )

    public static let winIlok = RunnerClass(
        id: .winIlok,
        displayName: "Windows iLok signing",
        isolation: .hostProcess,
        labels: ["self-hosted", "windows", "x64", "ilok", "forge"],
        minReplicas: 1, maxReplicas: 1, defaultReplicas: 1,
        runsOnMac: false,
        notContainerizedReason: """
            A Windows container cannot see a USB device. There is no passthrough, no flag and no \
            workaround, so the machine holding the dongle signs as a host process. It deliberately \
            has no compiler: a build job that could run there could compromise the signing host.
            """
    )

    public static let macIlok = RunnerClass(
        id: .macIlok,
        displayName: "macOS iLok signing",
        isolation: .hostProcess,
        labels: ["self-hosted", "macos", "arm64", "ilok", "forge"],
        minReplicas: 1, maxReplicas: 1, defaultReplicas: 1,
        runsOnMac: true,
        notContainerizedReason: """
            The dongle is a USB device and wraptool is a host tool, so this class runs as a host \
            process for the same reason win-ilok does. It deliberately has no compiler.
            """
    )

    public static let all: [RunnerClass] = [winBuild, linuxUtil, macBuild, winIlok, macIlok]

    public static func named(_ classId: String) -> RunnerClass? {
        all.first { $0.classId == classId }
    }
}
