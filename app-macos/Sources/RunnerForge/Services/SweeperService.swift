import Foundation

/// The KEEP/PURGE policy as pure data and pure functions, so it can be proven
/// without a Tart install or a disk.
public enum SweeperPolicy {
    /// Named volumes and cache directories that are never deleted.
    public static let keepVolumes = ["forge-fetchcontent", "forge-sccache", "forge-ccache", "forge-aax-sdk"]

    /// Tart images that are never deleted, given the configured version.
    public static func keepTartImages(tag: String) -> [String] {
        ["runnerforge-macos:\(tag)", "ghcr.io/cirruslabs/macos-tahoe-xcode:26"]
    }

    /// Work-directory subtrees that are always purged.
    public static let purgeDirectories: [(relative: String, description: String)] = [
        ("jobs", "job workspaces"),
        ("tmp", "temp downloads"),
    ]

    /// The prune commands the sweeper is allowed to run. Deliberately explicit:
    /// this list is what a test asserts against.
    public static let allowedPruneCommands = ["docker image prune -f", "docker builder prune -f"]

    /// True when a command would destroy KEEP items.
    public static func isForbiddenPrune(_ command: String) -> Bool {
        let lowered = command.lowercased()
        return lowered.contains("system prune")
            || (lowered.contains("image prune") && lowered.contains(" -a"))
    }

    /// Whether a Tart entry may be deleted. Only CLONES (forge-*) may be; an
    /// IMAGE never may, because rebuilding one costs about an hour.
    public static func isDeletableTartEntry(_ name: String) -> Bool {
        name.hasPrefix("forge-")
    }

    /// True when the named item must survive every sweep.
    public static func isKeepItem(_ name: String, tartTag: String) -> Bool {
        keepVolumes.contains(name)
            || keepTartImages(tag: tartTag).contains(name)
            || name.hasPrefix("runnerforge-macos:")
            || name.contains("macos-tahoe-xcode")
    }
}

/// "Clean on close, keep only what makes the next run fast."
///
/// Works from two EXPLICIT lists, never a heuristic, because erring in either
/// direction is a bug. `tart delete` is only ever applied to CLONES.
public struct SweeperService: Sendable {
    private let logBus: LogBus
    private let processRunner: ProcessRunner

    public init(logBus: LogBus, processRunner: ProcessRunner) {
        self.logBus = logBus
        self.processRunner = processRunner
    }

    public func survey(config: ForgeConfig) async throws -> DiskUsage {
        var keep: [DiskUsageItem] = []
        var purge: [DiskUsageItem] = []

        let workDir = config.paths.workDir
        let cacheDir = (workDir as NSString).appendingPathComponent("cache")

        if FileManager.default.fileExists(atPath: cacheDir) {
            keep.append(DiskUsageItem(
                description: "cache \(cacheDir)",
                category: .keep,
                bytes: Self.directorySize(cacheDir),
                reason: "Deleting this is what makes the next build re-clone JUCE from scratch."))
        }

        // Tart IMAGES are KEEP. Only clones are ever listed for purging.
        if ProcessRunner.isOnPath("tart") {
            let result = try await processRunner.run(
                "tart", arguments: ["list", "--quiet"], logSource: "sweeper", streamOutput: false)

            for line in result.standardOutput.split(separator: "\n") {
                let name = line.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }

                if SweeperPolicy.isDeletableTartEntry(name) {
                    purge.append(DiskUsageItem(
                        description: "tart clone \(name)", category: .purge, bytes: 0))
                } else {
                    keep.append(DiskUsageItem(
                        description: "tart image \(name)", category: .keep, bytes: 0,
                        reason: "Rebuilding a macOS image takes about an hour."))
                }
            }
        }

        for entry in SweeperPolicy.purgeDirectories {
            let full = (workDir as NSString).appendingPathComponent(entry.relative)
            guard FileManager.default.fileExists(atPath: full) else { continue }
            purge.append(DiskUsageItem(
                description: "\(entry.description) \(full)",
                category: .purge,
                bytes: Self.directorySize(full)))
        }

        let oldLogs = Self.oldLogBytes(workDir: workDir, retentionDays: config.retention.logRetentionDays)
        if oldLogs > 0 {
            purge.append(DiskUsageItem(
                description: "logs older than \(config.retention.logRetentionDays) days",
                category: .purge, bytes: oldLogs))
        }

        // An ephemeral keychain left behind means a signing script died before
        // its trap ran, which also means a private key is sitting unlocked.
        let keychains = try await processRunner.run(
            "security", arguments: ["list-keychains"], logSource: "sweeper", streamOutput: false)

        let strayKeychains = keychains.standardOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { $0.contains("runnerforge-ci-") }

        if !strayKeychains.isEmpty {
            purge.append(DiskUsageItem(
                description: "ephemeral keychains x\(strayKeychains.count)",
                category: .purge, bytes: 0))
        }

        return DiskUsage(keep: keep, purge: purge)
    }

    /// Runs the sweep and reports the bytes actually reclaimed.
    @discardableResult
    public func purge(config: ForgeConfig) async throws -> Int64 {
        let before = try await survey(config: config)
        await logBus.info("sweeper", "reclaimable: \(before.humanReclaimableBytes)")

        let workDir = config.paths.workDir

        for entry in SweeperPolicy.purgeDirectories {
            let full = (workDir as NSString).appendingPathComponent(entry.relative)
            guard FileManager.default.fileExists(atPath: full) else { continue }
            await logBus.info("sweeper", "removing \(entry.description)")
            Self.deleteChildren(of: full)
        }

        Self.deleteOldLogs(workDir: workDir, retentionDays: config.retention.logRetentionDays)
        Self.deleteOldProofBundles(workDir: workDir)

        // CLONES ONLY. Deleting an image here would destroy tens of gigabytes.
        if ProcessRunner.isOnPath("tart") {
            let result = try await processRunner.run(
                "tart", arguments: ["list", "--quiet"], logSource: "sweeper", streamOutput: false)

            for line in result.standardOutput.split(separator: "\n") {
                let name = line.trimmingCharacters(in: .whitespaces)
                guard SweeperPolicy.isDeletableTartEntry(name) else { continue }

                await logBus.info("sweeper", "deleting tart CLONE \(name) (images are never touched)")
                _ = try? await processRunner.run("tart", arguments: ["stop", name],
                                                 logSource: "sweeper", streamOutput: false)
                _ = try? await processRunner.run("tart", arguments: ["delete", name],
                                                 logSource: "sweeper", streamOutput: false)
            }
        }

        let after = try await survey(config: config)
        let reclaimed = max(0, before.reclaimableBytes - after.reclaimableBytes)
        await logBus.info("sweeper", "reclaimed \(DiskUsageItem.format(bytes: reclaimed))")
        return reclaimed
    }

    // --- helpers -------------------------------------------------------------
    static func directorySize(_ path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0

        while let relative = enumerator.nextObject() as? String {
            let full = (path as NSString).appendingPathComponent(relative)
            let attributes = try? FileManager.default.attributesOfItem(atPath: full)
            total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }

        return total
    }

    static func oldLogBytes(workDir: String, retentionDays: Int) -> Int64 {
        let logs = (workDir as NSString).appendingPathComponent("logs")
        guard let enumerator = FileManager.default.enumerator(atPath: logs) else { return 0 }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        var total: Int64 = 0

        while let relative = enumerator.nextObject() as? String {
            let full = (logs as NSString).appendingPathComponent(relative)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: full),
                  let modified = attributes[.modificationDate] as? Date, modified < cutoff else { continue }
            total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }

        return total
    }

    static func deleteOldLogs(workDir: String, retentionDays: Int) {
        let logs = (workDir as NSString).appendingPathComponent("logs")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: logs) else { return }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)

        for entry in entries {
            let full = (logs as NSString).appendingPathComponent(entry)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: full),
                  let modified = attributes[.modificationDate] as? Date, modified < cutoff else { continue }
            try? FileManager.default.removeItem(atPath: full)
        }
    }

    /// Keeps the most recent proof bundle. It is what the Runners page shows as
    /// "currently known-good"; deleting it would make the GUI claim the setup
    /// has never been verified.
    static func deleteOldProofBundles(workDir: String) {
        let proof = (workDir as NSString).appendingPathComponent("proof")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: proof) else { return }

        let sorted = entries
            .map { name -> (String, Date) in
                let full = (proof as NSString).appendingPathComponent(name)
                let attributes = try? FileManager.default.attributesOfItem(atPath: full)
                return (full, (attributes?[.modificationDate] as? Date) ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }

        for (path, _) in sorted.dropFirst() {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    static func deleteChildren(of directory: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries {
            try? FileManager.default.removeItem(
                atPath: (directory as NSString).appendingPathComponent(entry))
        }
    }
}
