import Foundation

/// Reaper outcome. These values are the contract with the GUI.
public enum ReaperResult: Int, Sendable {
    /// Nothing stray was found.
    case clean = 0
    /// Strays were found and are now gone.
    case straysKilled = 10
    /// Something survived SIGKILL. The GUI must refuse to start new runners.
    case straysSurvived = 20
}

public struct Stray: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let kind: String
    public let name: String
    public let processId: Int32?
    public let detail: String
}

/// "Verify nothing keeps running."
///
/// Answers exactly one question: is anything still alive that should not be? It
/// does NOT decide what to delete — that is the Sweeper's job. Keeping them
/// apart matters because "is it running?" and "can I delete it?" have different
/// answers and different blast radii.
public struct ReaperService: Sendable {
    private let logBus: LogBus
    private let processRunner: ProcessRunner

    public init(logBus: LogBus, processRunner: ProcessRunner) {
        self.logBus = logBus
        self.processRunner = processRunner
    }

    /// Processes that must not exist outside a live, registered job.
    public static let strayProcessNames = [
        "Runner.Listener", "Runner.Worker", "xcodebuild", "clang", "ld",
        "cmake", "ninja", "wraptool", "notarytool",
    ]

    public var grace: TimeInterval { 10 }

    /// Finds strays without touching anything. Used by the watchdog poll.
    public func findStrays(
        config: ForgeConfig,
        livePids: Set<Int32>,
        liveRunnerNames: Set<String>
    ) async throws -> [Stray] {
        var strays: [Stray] = []
        let selfPid = ProcessInfo.processInfo.processIdentifier

        for name in Self.strayProcessNames {
            let result = try await processRunner.run(
                "pgrep", arguments: ["-x", name], logSource: "reaper", streamOutput: false)

            for line in result.standardOutput.split(separator: "\n") {
                guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)),
                      pid != selfPid, !livePids.contains(pid) else { continue }

                // The full command line is what makes a stray diagnosable rather
                // than just a number in a log.
                let describe = try await processRunner.run(
                    "ps", arguments: ["-o", "command=", "-p", String(pid)],
                    logSource: "reaper", streamOutput: false)

                let commandLine = describe.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                strays.append(Stray(kind: "process", name: name, processId: pid,
                                    detail: "\(name) pid=\(pid) :: \(commandLine)"))
            }
        }

        // Tart clones running with no job claiming them.
        if ProcessRunner.isOnPath("tart") {
            let result = try await processRunner.run(
                "tart", arguments: ["list", "--quiet"], logSource: "reaper", streamOutput: false)

            for line in result.standardOutput.split(separator: "\n") {
                let name = line.trimmingCharacters(in: .whitespaces)
                guard name.hasPrefix("forge-"),
                      !liveRunnerNames.contains(where: { name.contains($0) }) else { continue }
                strays.append(Stray(kind: "vm", name: name, processId: nil,
                                    detail: "tart clone \(name)"))
            }
        }

        // An ephemeral keychain left behind means a signing script died before
        // its trap ran, which also means a private key is sitting unlocked.
        let keychains = try await processRunner.run(
            "security", arguments: ["list-keychains"], logSource: "reaper", streamOutput: false)

        for line in keychains.standardOutput.split(separator: "\n") {
            let name = line.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            guard name.contains("runnerforge-ci-") else { continue }
            strays.append(Stray(kind: "keychain", name: name, processId: nil,
                                detail: "ephemeral keychain \(name)"))
        }

        return strays
    }

    /// Finds strays, terminates them politely, escalates, and RE-VERIFIES.
    /// Reporting "killed" without checking is how a stray survives a reap and
    /// nobody notices.
    public func reap(
        config: ForgeConfig,
        livePids: Set<Int32> = [],
        liveRunnerNames: Set<String> = []
    ) async throws -> ReaperResult {
        let strays = try await findStrays(
            config: config, livePids: livePids, liveRunnerNames: liveRunnerNames)

        guard !strays.isEmpty else {
            await logBus.info("reaper", "clean: no stray processes, VM clones or ephemeral keychains")
            return .clean
        }

        await logBus.warning("reaper", "found \(strays.count) stray item(s)")
        for stray in strays { await logBus.warning("reaper", "  " + stray.detail) }

        // Polite first. A runner given the chance to shut down cleanly
        // unregisters itself from GitHub; one killed outright leaves an offline
        // registration behind for crash recovery to clean up.
        for stray in strays where stray.processId != nil {
            await logBus.info("reaper", "SIGTERM -> \(stray.processId!)")
            kill(stray.processId!, SIGTERM)
        }

        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, Self.anyAlive(strays) {
            try? await Task.sleep(for: .seconds(1))
        }

        for stray in strays where stray.processId != nil {
            guard kill(stray.processId!, 0) == 0 else { continue }
            await logBus.warning("reaper", "SIGKILL -> \(stray.processId!) (ignored SIGTERM)")
            kill(stray.processId!, SIGKILL)
        }

        for stray in strays where stray.kind == "vm" {
            _ = try? await processRunner.run("tart", arguments: ["stop", stray.name],
                                             logSource: "reaper", streamOutput: false)
            _ = try? await processRunner.run("tart", arguments: ["delete", stray.name],
                                             logSource: "reaper", streamOutput: false)
        }

        for stray in strays where stray.kind == "keychain" {
            _ = try? await processRunner.run("security", arguments: ["delete-keychain", stray.name],
                                             logSource: "reaper", streamOutput: false)
        }

        try? await Task.sleep(for: .seconds(1))

        let survivors = try await findStrays(
            config: config, livePids: livePids, liveRunnerNames: liveRunnerNames)

        if !survivors.isEmpty {
            await logBus.error("reaper",
                "STRAYS SURVIVED — \(survivors.count) item(s) are still present after SIGKILL:")
            for survivor in survivors { await logBus.error("reaper", "  " + survivor.detail) }
            await logBus.error("reaper", "new runners must not be started until this is resolved.")
            return .straysSurvived
        }

        await logBus.info("reaper", "all \(strays.count) stray item(s) confirmed gone")
        return .straysKilled
    }

    static func anyAlive(_ strays: [Stray]) -> Bool {
        strays.contains { stray in
            guard let pid = stray.processId else { return false }
            return kill(pid, 0) == 0
        }
    }
}
