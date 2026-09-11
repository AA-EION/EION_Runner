import Foundation
import Observation

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
