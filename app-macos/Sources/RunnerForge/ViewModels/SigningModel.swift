import Foundation
import Observation

/// Drives the Signing page.
@MainActor
@Observable
public final class SigningModel {
    private let store: ForgeStore

    public var requirements: [SigningRequirement] = []
    public var isChecking = false
    public var dryRunOutputPath = ""
    public var dryRunMessage: String?

    public init(store: ForgeStore) { self.store = store }

    public var mode: SigningMode {
        get { store.config.signing.modeValue }
        set {
            store.config.signing.modeValue = newValue
            // Cloud signing is the only mode where --allowsigningservice applies;
            // sending it with a physical dongle attached is a wraptool error, not
            // a no-op.
            store.config.signing.allowSigningService = (newValue == .cloud)
            store.markDirty()
            Task { await refresh() }
        }
    }

    public var windowsProvider: WindowsSigningProvider {
        get { WindowsSigningProvider(rawValue: store.config.signing.windows.provider) ?? .none }
        set { store.config.signing.windows.provider = newValue.rawValue; store.markDirty() }
    }

    public var wcGuid: String {
        get { store.config.signing.paceWcGuid }
        set { store.config.signing.paceWcGuid = newValue; store.markDirty() }
    }

    public var signId: String {
        get { store.config.signing.paceSignId }
        set { store.config.signing.paceSignId = newValue; store.markDirty() }
    }

    public var teamId: String {
        get { store.config.signing.macos.teamId }
        set { store.config.signing.macos.teamId = newValue; store.markDirty() }
    }

    public var devIdAppIdentity: String {
        get { store.config.signing.macos.devIdAppIdentity }
        set { store.config.signing.macos.devIdAppIdentity = newValue; store.markDirty() }
    }

    public var devIdInstallerIdentity: String {
        get { store.config.signing.macos.devIdInstallerIdentity }
        set { store.config.signing.macos.devIdInstallerIdentity = newValue; store.markDirty() }
    }

    public var notarize: Bool {
        get { store.config.signing.macos.notarize }
        set { store.config.signing.macos.notarize = newValue; store.markDirty() }
    }

    public var unmetCount: Int { requirements.filter { !$0.satisfied }.count }
    public var isSatisfied: Bool { !requirements.isEmpty && unmetCount == 0 }

    /// Why turning notarization off is not a convenience setting.
    public static let staplingNote = """
        Notarization staples a ticket into the artifact. Without the staple, the plugin fails Gatekeeper \
        on every machine except the one that built it — and it fails silently, as a plugin the host \
        simply does not list.
        """

    public func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        requirements = await store.services.signingService
            .requirements(for: mode, config: store.config)
    }

    /// Runs the signing path with --dry-run: every argument is assembled and
    /// printed, nothing is signed, and passwords come out redacted.
    public func dryRun() async {
        let path = dryRunOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            dryRunMessage = "Pick a bundle to dry-run against first."
            return
        }

        do {
            let ok = try await store.services.signingService.signAax(
                config: store.config,
                scriptsDirectory: store.services.scriptsDirectory,
                bundlePath: path,
                dryRun: true)
            dryRunMessage = ok
                ? "Dry run completed. The exact wraptool command is on the Logs page, with the password redacted."
                : "Dry run failed. See the Logs page."
        } catch {
            dryRunMessage = "Dry run failed: \(error)"
        }
    }
}
