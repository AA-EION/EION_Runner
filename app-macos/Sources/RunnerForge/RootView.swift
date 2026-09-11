import Foundation
import Observation
import SwiftUI

/// The application's shared state: the loaded configuration, the services, and
/// the few facts every page needs.
///
/// Observation, not Combine: `@Observable` is the supported way to publish
/// changes to SwiftUI on macOS 26, and it tracks reads per-property so a change
/// to `config.limits.maxDiskGb` does not redraw the Logs page.
@MainActor
@Observable
public final class ForgeStore {
    public let services: AppServices

    public var config: ForgeConfig
    public var configPath: String

    /// Set when the config on disk failed validation. The app stays usable —
    /// refusing to launch over a bad field would leave the user no way to fix it.
    public var loadProblems: [String] = []

    public var isDirty = false
    public var lastSavedAt: Date?

    /// Which secrets the Keychain holds, by key name. Never the values.
    public var secretPresence: [String: Bool] = [:]

    public init(services: AppServices = AppServices()) {
        self.services = services
        self.configPath = ConfigStore.defaultConfigPath
        self.config = ForgeConfig.makeDefault(workDir: ConfigStore.defaultWorkDir)
    }

    public func bootstrap() async {
        await load()
        await refreshSecretPresence()
        await services.refreshRedaction()
        await services.logBus.info("app", "Runner Forge ready — config \(configPath)")
    }

    public func load() async {
        do {
            config = try await services.configStore.load(from: configPath)
            loadProblems = []
            isDirty = false
        } catch let error as ConfigValidationError {
            loadProblems = error.problems
            await services.logBus.error("config", error.description)
        } catch {
            // A missing file on a first run is not a problem: defaults apply.
            if !FileManager.default.fileExists(atPath: configPath) {
                config = ForgeConfig.makeDefault(workDir: ConfigStore.defaultWorkDir)
                loadProblems = []
            } else {
                loadProblems = [String(describing: error)]
                await services.logBus.error("config", String(describing: error))
            }
        }
    }

    @discardableResult
    public func save() async -> Bool {
        do {
            try await services.configStore.save(config, to: configPath)
            isDirty = false
            lastSavedAt = Date()
            loadProblems = []
            return true
        } catch let error as ConfigValidationError {
            loadProblems = error.problems
            await services.logBus.error("config", error.description)
            return false
        } catch {
            loadProblems = [String(describing: error)]
            await services.logBus.error("config", String(describing: error))
            return false
        }
    }

    public func markDirty() { isDirty = true }

    public func refreshSecretPresence() async {
        secretPresence = await services.secretStore.presence()
    }

    /// The config's entry for a runner class, or the class defaults when the
    /// config has never mentioned it.
    public func runnerConfig(for runnerClass: RunnerClass) -> RunnerConfig {
        config.runners.first { $0.classId == runnerClass.classId }
            ?? RunnerConfig(forClass: runnerClass)
    }

    public func updateRunnerConfig(_ updated: RunnerConfig) {
        if let index = config.runners.firstIndex(where: { $0.classId == updated.classId }) {
            config.runners[index] = updated
        } else {
            config.runners.append(updated)
        }
        markDirty()
    }

    /// Runner classes this Mac can host. The Windows classes appear on the
    /// Windows app; listing them here would offer a control that cannot work.
    public var hostableClasses: [RunnerClass] { RunnerClass.all.filter(\.runsOnMac) }
}


/// The single place every service is constructed and wired.
///
/// Services are value types or actors, so this container is just the object
/// graph: one LogBus that everything writes to, one ProcessRunner that
/// everything shells out through, and the rest built on top of those two.
/// Constructing a service anywhere else would give it a second LogBus, and its
/// output would silently vanish from the Logs page.
@MainActor
public final class AppServices {
    public let logBus: LogBus
    public let processRunner: ProcessRunner
    public let configStore: ConfigStore
    public let secretStore: SecretStore
    public let tartService: TartService
    public let appService: GitHubAppService
    public let actionsService: GitHubActionsService
    public let reaperService: ReaperService
    public let sweeperService: SweeperService
    public let preflightService: PreflightService
    public let signingService: SigningService
    public let selfTestService: SelfTestService
    public let supervisor: RunnerSupervisor
    public let templateRenderer: TemplateRenderer

    /// Where the shipped scripts live inside the app bundle. The scripts are
    /// resources of the product, not something the user is expected to have
    /// cloned somewhere.
    public let scriptsDirectory: String

    public init() {
        let logBus = LogBus()
        let processRunner = ProcessRunner(logBus: logBus)
        let secretStore = SecretStore(logBus: logBus)
        let tartService = TartService(logBus: logBus, processRunner: processRunner)
        let appService = GitHubAppService(logBus: logBus, secretStore: secretStore)
        let actionsService = GitHubActionsService(logBus: logBus, appService: appService)
        let reaperService = ReaperService(logBus: logBus, processRunner: processRunner)
        let sweeperService = SweeperService(logBus: logBus, processRunner: processRunner)

        self.logBus = logBus
        self.processRunner = processRunner
        self.configStore = ConfigStore(logBus: logBus)
        self.secretStore = secretStore
        self.tartService = tartService
        self.appService = appService
        self.actionsService = actionsService
        self.reaperService = reaperService
        self.sweeperService = sweeperService
        self.preflightService = PreflightService(
            logBus: logBus, processRunner: processRunner, tartService: tartService)
        self.signingService = SigningService(
            logBus: logBus, processRunner: processRunner, secretStore: secretStore)
        self.selfTestService = SelfTestService(
            logBus: logBus, configStore: ConfigStore(logBus: logBus), actionsService: actionsService,
            reaperService: reaperService, sweeperService: sweeperService, processRunner: processRunner)
        self.supervisor = RunnerSupervisor(
            logBus: logBus, tartService: tartService, appService: appService,
            actionsService: actionsService, reaperService: reaperService)
        self.templateRenderer = TemplateRenderer()

        let bundled = Bundle.main.resourceURL?.appendingPathComponent("scripts").path
        self.scriptsDirectory = bundled ?? "/usr/local/share/runnerforge/scripts"
    }

    /// Teaches the LogBus every secret the Keychain holds, so redaction works on
    /// the VALUES and not only on patterns that happen to look secret-shaped.
    /// Called once at launch and again after any credential is saved.
    public func refreshRedaction() async {
        await logBus.forgetSecrets()
        for name in SecretStore.keyNames {
            await logBus.registerSecret(await secretStore.read(name))
        }
    }
}


/// The eight pages, in the order the user should walk them the first time.
public enum ForgePage: String, CaseIterable, Identifiable, Hashable {
    case preflight, targets, credentials, signing, runners, cleanup, export, logs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .preflight: "Preflight"
        case .targets: "Targets"
        case .credentials: "Credentials"
        case .signing: "Signing"
        case .runners: "Runners"
        case .cleanup: "Cleanup"
        case .export: "Export"
        case .logs: "Logs"
        }
    }

    public var symbol: String {
        switch self {
        case .preflight: "checklist"
        case .targets: "target"
        case .credentials: "key.fill"
        case .signing: "signature"
        case .runners: "play.circle"
        case .cleanup: "trash"
        case .export: "square.and.arrow.up"
        case .logs: "text.alignleft"
        }
    }
}

/// A page title plus a one-line explanation of what the page is for.
public struct PageHeader: View {
    let title: String
    let subtitle: String

    public init(_ title: String, _ subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A coloured status pill. One definition, so "pass" looks the same everywhere.
public struct StatusBadge: View {
    let text: String
    let tint: Color

    public init(text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    public init(_ status: PreflightStatus) {
        switch status {
        case .checking: self.init(text: "checking", tint: .secondary)
        case .pass: self.init(text: "pass", tint: .green)
        case .warn: self.init(text: "warn", tint: .orange)
        case .fail: self.init(text: "fail", tint: .red)
        }
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// A boxed explanatory note. Used where a design decision would otherwise look
/// like a missing feature.
public struct ExplanationBox: View {
    let symbol: String
    let text: String

    public init(symbol: String = "info.circle", text: String) {
        self.symbol = symbol
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}


/// The window: a sidebar of the eight pages, and a status strip that is visible
/// from every one of them.
public struct RootView: View {
    @Bindable private var store: ForgeStore
    @State private var page: ForgePage = .preflight

    public init(store: ForgeStore) {
        _store = Bindable(wrappedValue: store)
    }

    public var body: some View {
        NavigationSplitView {
            List(ForgePage.allCases, selection: $page) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            VStack(spacing: 0) {
                detail
                Divider()
                statusStrip
            }
        }
        .frame(minWidth: 940, minHeight: 640)
        .task { await store.bootstrap() }
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .preflight: PreflightView(store: store)
        case .targets: TargetsView(store: store)
        case .credentials: CredentialsView(store: store)
        case .signing: SigningView(store: store)
        case .runners: RunnersView(store: store)
        case .cleanup: CleanupView(store: store)
        case .export: ExportView(store: store)
        case .logs: LogsView(store: store)
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 12) {
            Text(store.configPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)

            if store.isDirty {
                StatusBadge(text: "unsaved", tint: .orange)
            } else if let at = store.lastSavedAt {
                Text("saved \(at.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if !store.loadProblems.isEmpty {
                // The app stays usable with an invalid config on disk: refusing
                // to launch over a bad field would leave no way to fix the field.
                Text(store.loadProblems.first ?? "")
                    .font(.caption).foregroundStyle(.red).lineLimit(1)
                    .help(store.loadProblems.joined(separator: "\n"))
            }

            Button("Reload") { Task { await store.load() } }
            Button("Save") { Task { await store.save() } }
                .keyboardShortcut("s")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
