import Foundation

public struct TartStatus: Sendable {
    public let installed: Bool
    public let version: String?
    public let images: [String]
    public let clones: [String]
}

/// Everything Runner Forge asks of Tart: status, image presence, and running one
/// job in a throwaway VM clone.
///
/// macOS runners exist ONLY here. Tart uses Apple's Virtualization framework, so
/// there is no Windows, Linux, QEMU or KVM path to a macOS runner — it is both
/// technically impossible on that hardware and a violation of Apple's licence.
public struct TartService: Sendable {
    private let logBus: LogBus
    private let processRunner: ProcessRunner

    public init(logBus: LogBus, processRunner: ProcessRunner) {
        self.logBus = logBus
        self.processRunner = processRunner
    }

    public func status() async throws -> TartStatus {
        guard ProcessRunner.isOnPath("tart") else {
            return TartStatus(installed: false, version: nil, images: [], clones: [])
        }

        let versionResult = try await processRunner.run(
            "tart", arguments: ["--version"], logSource: "tart", streamOutput: false)

        let listResult = try await processRunner.run(
            "tart", arguments: ["list", "--quiet"], logSource: "tart", streamOutput: false)

        var images: [String] = []
        var clones: [String] = []

        for line in listResult.standardOutput.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            // A clone is named forge-*; anything else is an image and is KEEP.
            if SweeperPolicy.isDeletableTartEntry(name) { clones.append(name) } else { images.append(name) }
        }

        return TartStatus(
            installed: true,
            version: versionResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            images: images,
            clones: clones)
    }

    /// Runs one job in a throwaway clone by delegating to scripts/tart-runner.sh.
    ///
    /// The script owns the lifecycle because its `trap EXIT` is what guarantees
    /// the clone is deleted whether the job passes, fails, or is interrupted. A
    /// leaked clone is tens of gigabytes and a poisoned environment for the next
    /// job.
    ///
    /// The JIT config goes in on STDIN, never as an argument.
    public func runEphemeralJob(
        scriptsDirectory: String,
        image: String,
        jitConfig: String,
        cacheDirectory: String,
        jobTimeoutMinutes: Int
    ) async throws -> ProcessResult {
        let script = (scriptsDirectory as NSString).appendingPathComponent("tart-runner.sh")

        guard FileManager.default.fileExists(atPath: script) else {
            throw NSError(domain: "RunnerForge", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "tart-runner.sh not found at \(script)",
            ])
        }

        await logBus.info("tart", "starting a VM clone from \(image) (one job, then it is deleted)")

        return try await processRunner.run(
            "/bin/bash",
            arguments: [
                script,
                "--image", image,
                "--cache-dir", cacheDirectory,
                "--job-timeout-minutes", String(jobTimeoutMinutes),
            ],
            standardInput: jitConfig,
            logSource: "tart")
    }

    public func imageExists(_ name: String) async throws -> Bool {
        try await status().images.contains(name)
    }

    /// Free space on the volume holding the Tart storage.
    public func freeDiskBytes() -> Int64 {
        let home = NSHomeDirectory()
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: home)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
}
