import Foundation
import Testing
@testable import RunnerForge

/// The artifact contract is the deliverable. A green run that uploaded an empty
/// directory is a failure that looks like a success, so these tests build real
/// directories on disk and assert against them.
@Suite("Artifact assertion")
struct ArtifactAssertionTests {

    private func makeRoot() throws -> String {
        let root = NSTemporaryDirectory() + "rf-artifacts-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ path: String, bytes: Int) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    // -----------------------------------------------------------------------
    // The contract itself
    // -----------------------------------------------------------------------

    /// With no AAX SDK the two AAX artifacts become optional AND the skip marker
    /// becomes required, so the set is never silently one artifact short.
    @Test("the AAX rows flip together")
    func aaxRowsFlipTogether() {
        let withSdk = ArtifactExpectation.contract(for: "Canary", aaxAvailable: true)
        #expect(withSdk.first { $0.name == "Canary-aax-windows" }?.required == true)
        #expect(withSdk.first { $0.name == "Canary-aax-macos" }?.required == true)
        #expect(withSdk.first { $0.name == "Canary-aax-skipped" }?.required == false)

        let withoutSdk = ArtifactExpectation.contract(for: "Canary", aaxAvailable: false)
        #expect(withoutSdk.first { $0.name == "Canary-aax-windows" }?.required == false)
        #expect(withoutSdk.first { $0.name == "Canary-aax-macos" }?.required == false)
        #expect(withoutSdk.first { $0.name == "Canary-aax-skipped" }?.required == true)
    }

    /// macOS plugins are bundle DIRECTORIES with symlinks inside. upload-artifact
    /// flattens symlinks, so they are tarred on the way in — which means the
    /// macOS rows must say untar, or the assertion looks for a .vst3 that the
    /// artifact never contained.
    @Test("only the macOS rows untar, and they name their bundles")
    func macosRowsUntar() {
        let contract = ArtifactExpectation.contract(for: "Canary", aaxAvailable: true)
        let untarring = contract.filter(\.untar)

        #expect(untarring.map(\.name) == ["Canary-macos-universal"])
        #expect(untarring.allSatisfy { !$0.bundles.isEmpty })
        #expect(contract.filter { !$0.untar }.allSatisfy { $0.bundles.isEmpty })
    }

    @Test("every artifact name is unique and project-scoped")
    func namesAreUniqueAndScoped() {
        let contract = ArtifactExpectation.contract(for: "Canary", aaxAvailable: true)
        #expect(Set(contract.map(\.name)).count == contract.count)
        #expect(contract.allSatisfy { $0.name.hasPrefix("Canary-") })
        #expect(contract.allSatisfy { !$0.globs.isEmpty })
    }

    // -----------------------------------------------------------------------
    // Assertion against real directories
    // -----------------------------------------------------------------------

    @Test("an artifact matching its globs passes")
    func matchingArtifactPasses() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let expectation = ArtifactExpectation(
            name: "Canary-windows-x64", required: true, globs: ["*.vst3", "*.clap"])

        try write("\(root)/Canary-windows-x64/Canary.vst3", bytes: 2048)
        try write("\(root)/Canary-windows-x64/Canary.clap", bytes: 1024)

        let outcome = await SelfTestService.verifyArtifact(
            downloadRoot: root, expectation: expectation,
            processRunner: ProcessRunner(logBus: LogBus()))

        #expect(outcome.passed)
        #expect(outcome.bytes == 3072)
        #expect(outcome.fileCount == 2)
    }

    /// An empty file is the failure mode that a "does it exist" check misses: a
    /// build that produced a zero-byte plugin uploads happily.
    @Test("a zero-byte artifact fails")
    func emptyArtifactFails() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let expectation = ArtifactExpectation(
            name: "Canary-windows-x64", required: true, globs: ["*.vst3"])
        try write("\(root)/Canary-windows-x64/Canary.vst3", bytes: 0)

        let outcome = await SelfTestService.verifyArtifact(
            downloadRoot: root, expectation: expectation,
            processRunner: ProcessRunner(logBus: LogBus()))

        #expect(!outcome.passed)
    }

    @Test("a missing glob fails even when other files are present")
    func missingGlobFails() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let expectation = ArtifactExpectation(
            name: "Canary-windows-x64", required: true, globs: ["*.vst3", "*.clap"])
        try write("\(root)/Canary-windows-x64/Canary.vst3", bytes: 2048)

        let outcome = await SelfTestService.verifyArtifact(
            downloadRoot: root, expectation: expectation,
            processRunner: ProcessRunner(logBus: LogBus()))

        #expect(!outcome.passed)
    }

    @Test("a missing required artifact fails and a missing optional one does not")
    func missingArtifact() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let runner = ProcessRunner(logBus: LogBus())

        let required = await SelfTestService.verifyArtifact(
            downloadRoot: root,
            expectation: ArtifactExpectation(name: "absent", required: true, globs: ["*.vst3"]),
            processRunner: runner)
        #expect(!required.passed)

        let optional = await SelfTestService.verifyArtifact(
            downloadRoot: root,
            expectation: ArtifactExpectation(name: "absent", required: false, globs: ["*.aaxplugin"]),
            processRunner: runner)
        #expect(optional.passed)
    }

    /// The round trip the macOS rows exist for: tar the bundle, assert that
    /// Contents/MacOS and Contents/Info.plist survive.
    @Test("a tarred macOS bundle is extracted and its structure asserted")
    func tarredBundleRoundTrips() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let staging = "\(root)/staging"
        let bundle = "\(staging)/Canary.vst3"
        try write("\(bundle)/Contents/MacOS/Canary", bytes: 4096)
        try write("\(bundle)/Contents/Info.plist", bytes: 256)

        let artifactDir = "\(root)/Canary-macos-universal"
        try FileManager.default.createDirectory(atPath: artifactDir, withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", "\(artifactDir)/macos-bundles.tar", "-C", staging, "Canary.vst3"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)

        let outcome = await SelfTestService.verifyArtifact(
            downloadRoot: root,
            expectation: ArtifactExpectation(
                name: "Canary-macos-universal", required: true,
                globs: ["*.vst3"], untar: true, bundles: ["*.vst3"]),
            processRunner: ProcessRunner(logBus: LogBus()))

        #expect(outcome.passed)
    }

    /// A tar that unpacks to a bundle with no Contents/MacOS is not a plugin,
    /// however plausible its name.
    @Test("a bundle missing Contents/MacOS fails")
    func bundleWithoutMacOsFails() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let staging = "\(root)/staging"
        try write("\(staging)/Canary.vst3/Contents/Info.plist", bytes: 256)

        let artifactDir = "\(root)/Canary-macos-universal"
        try FileManager.default.createDirectory(atPath: artifactDir, withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", "\(artifactDir)/macos-bundles.tar", "-C", staging, "Canary.vst3"]
        try tar.run()
        tar.waitUntilExit()

        let outcome = await SelfTestService.verifyArtifact(
            downloadRoot: root,
            expectation: ArtifactExpectation(
                name: "Canary-macos-universal", required: true,
                globs: ["*.vst3"], untar: true, bundles: ["*.vst3"]),
            processRunner: ProcessRunner(logBus: LogBus()))

        #expect(!outcome.passed)
    }

    /// A self-test that ran on GitHub's hosted runners proves nothing about this
    /// machine, so the result type says so explicitly.
    @Test("a run on hosted runners is not a valid self-test")
    func hostedRunnersDoNotCount() {
        var result = SelfTestResult(runId: 1, conclusion: "success", verdict: "pass")
        result.runnerNames = ["forge-mac-build-0", "ubuntu-24.04"]
        #expect(!result.allJobsOnForgeRunners)

        result.runnerNames = ["forge-mac-build-0", "forge-win-build-1"]
        #expect(result.allJobsOnForgeRunners)

        result.runnerNames = []
        #expect(!result.allJobsOnForgeRunners)
    }
}
