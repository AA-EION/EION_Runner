import Foundation
import Testing
@testable import RunnerForge

/// forge.json is the contract between the GUI and every script, and it is the
/// one file that must never hold a secret. These tests are about that.
@Suite("ConfigStore")
struct ConfigStoreTests {

    /// A minimal valid document, so each test can break exactly one thing.
    private func validRoot() -> [String: Any] {
        [
            "schemaVersion": 1,
            "github": [
                "owner": "example",
                "repos": ["plugin"],
                "appId": "123456",
                "installationId": "7890123",
            ],
            "runners": [
                ["classId": "mac-build", "enabled": true, "replicas": 1,
                 "labels": ["self-hosted"], "jobTimeoutMinutes": 60],
            ],
            "signing": [
                "mode": "windows-ilok",
                "windows": ["provider": "azure-trusted-signing"],
            ],
            "paths": ["workDir": "/Users/example/RunnerForge"],
            "retention": ["keepBaseImages": true, "keepTartImages": true, "logRetentionDays": 7],
            "limits": ["maxDiskGb": 120],
            "telemetry": false,
        ]
    }

    @Test("a well-formed document has no problems")
    func validDocumentPasses() {
        #expect(ConfigStore.validate(validRoot()).isEmpty)
    }

    /// The important one. A secret must be rejected wherever it appears, not
    /// only at the top level, because "nested" is exactly how one would slip in.
    @Test("every keystore key name is rejected, at any depth",
          arguments: ConfigStore.forbiddenKeys)
    func forbiddenKeysAreRejectedAtAnyDepth(key: String) {
        var root = validRoot()
        var signing = root["signing"] as! [String: Any]
        var windows = signing["windows"] as! [String: Any]
        windows[key] = "this should never be persisted"
        signing["windows"] = windows
        root["signing"] = signing

        let problems = ConfigStore.validate(root)
        #expect(problems.contains { $0.contains(key) && $0.contains("SECRET") })
        #expect(problems.contains { $0.hasPrefix("/signing/windows/\(key)") })
    }

    @Test("a secret at the top level is rejected too")
    func forbiddenKeyAtTopLevel() {
        var root = validRoot()
        root["pacePassword"] = "hunter2"
        #expect(ConfigStore.validate(root).contains { $0.hasPrefix("/pacePassword") })
    }

    @Test("telemetry cannot be turned on")
    func telemetryMustBeFalse() {
        var root = validRoot()
        root["telemetry"] = true
        #expect(ConfigStore.validate(root).contains { $0.contains("/telemetry") })
    }

    @Test("base images and tart images cannot be opted out of keeping")
    func retentionFlagsAreForced() {
        var root = validRoot()
        root["retention"] = ["keepBaseImages": false, "keepTartImages": false, "logRetentionDays": 7]
        let problems = ConfigStore.validate(root)
        #expect(problems.contains { $0.contains("keepBaseImages") })
        #expect(problems.contains { $0.contains("keepTartImages") })
    }

    /// An iLok class has one dongle, so two replicas is not "twice as fast", it
    /// is two processes fighting over one piece of hardware.
    @Test("an iLok class is rejected above one replica")
    func ilokReplicasAreFixed() {
        var root = validRoot()
        root["runners"] = [
            ["classId": "mac-ilok", "enabled": true, "replicas": 2,
             "labels": ["self-hosted"], "jobTimeoutMinutes": 60],
        ]
        let problems = ConfigStore.validate(root)
        #expect(problems.contains { $0.contains("/runners/0/replicas") && $0.contains("dongle") })
    }

    @Test("an unknown runner class is named, not ignored")
    func unknownClassIsReported() {
        var root = validRoot()
        root["runners"] = [["classId": "win-gpu", "replicas": 1]]
        #expect(ConfigStore.validate(root).contains { $0.contains("/runners/0/classId") })
    }

    @Test("an unknown signing mode is rejected")
    func unknownSigningMode() {
        var root = validRoot()
        root["signing"] = ["mode": "usb-stick", "windows": ["provider": "none"]]
        #expect(ConfigStore.validate(root).contains { $0.contains("/signing/mode") })
    }

    // ------------------------------------------------------------------
    // Unconfigured is not invalid.
    //
    // These four fields are what the GUI exists to collect. Treating them as
    // validation errors meant the app wrote a default forge.json on first run
    // and then refused to load the file it had just written on the second,
    // leaving no way in at all: the only way to fill them is the window that
    // would not open. See TROUBLESHOOTING #22.
    // ------------------------------------------------------------------

    @Test("an unconfigured GitHub section is a setup gap, not a validation error")
    func emptyGitHubFieldsAreGaps() {
        var root = validRoot()
        root["github"] = ["owner": "", "repos": [], "appId": "", "installationId": ""]

        let problems = ConfigStore.validate(root)
        for pointer in ["/github/owner", "/github/appId", "/github/installationId", "/github/repos"] {
            #expect(!problems.contains { $0.hasPrefix(pointer) }, "\(pointer) must not block loading")
        }
    }

    @Test("a freshly created default config loads without error")
    func defaultConfigLoads() {
        let fresh = ForgeConfig.makeDefault(workDir: "/tmp/rf-work")
        let data = try! JSONEncoder().encode(fresh)
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(ConfigStore.validate(root).isEmpty)
    }

    @Test("every unconfigured field is reported as a gap that names a page and a remedy")
    func setupGapsNameAPageAndARemedy() {
        let fresh = ForgeConfig.makeDefault(workDir: "/tmp/rf-work")
        let gaps = ConfigStore.describeSetupGaps(fresh)

        #expect(gaps.contains { $0.what.lowercased().contains("owner") })
        #expect(gaps.contains { $0.what.contains("App ID") })
        #expect(gaps.contains { $0.what.contains("Installation ID") })
        #expect(gaps.contains { $0.what.lowercased().contains("repository") })

        // A gap the user cannot act on is worse than no gap.
        let pages = ["Preflight", "Credentials", "Targets", "Runners", "Signing", "Export", "Logs", "Cleanup"]
        for gap in gaps {
            #expect(pages.contains(gap.page), "unknown page \(gap.page)")
            #expect(!gap.howToFix.isEmpty)
        }
    }

    @Test("a fully configured config reports no gaps")
    func configuredConfigHasNoGaps() {
        var config = ForgeConfig.makeDefault(workDir: "/tmp/rf-work")
        config.github = GitHubConfig(
            owner: "example", repos: ["plugin"], appId: "123456", installationId: "7890123")

        #expect(ConfigStore.describeSetupGaps(config).isEmpty)
    }

    @Test("a saved config round-trips through the parser")
    func saveThenLoadRoundTrips() async throws {
        let bus = LogBus()
        let store = ConfigStore(logBus: bus)
        let directory = NSTemporaryDirectory() + "rf-test-\(UUID().uuidString)"
        let path = (directory as NSString).appendingPathComponent("forge.json")
        defer { try? FileManager.default.removeItem(atPath: directory) }

        var config = ForgeConfig.makeDefault(workDir: directory)
        config.github = GitHubConfig(
            owner: "example", repos: ["plugin"], appId: "123456", installationId: "7890123")

        try await store.save(config, to: path)
        let loaded = try await store.load(from: path)

        #expect(loaded == config)
    }

    /// The default document must itself be valid. A product that ships an
    /// invalid default is a product whose first launch fails.
    @Test("the default config validates")
    func defaultConfigIsValid() throws {
        var config = ForgeConfig.makeDefault(workDir: "/tmp/rf")
        config.github = GitHubConfig(
            owner: "example", repos: ["plugin"], appId: "1", installationId: "2")

        let data = try JSONEncoder().encode(config)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(ConfigStore.validate(root).isEmpty)
    }
}
