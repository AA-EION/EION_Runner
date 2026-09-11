import Foundation

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
            logBus: logBus, processRunner: processRunner, tartService: tartService,
            secretStore: secretStore)
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
