import Foundation

/// Raised when forge.json does not satisfy the schema.
public struct ConfigValidationError: Error, CustomStringConvertible {
    public let problems: [String]

    public var description: String {
        "forge.json is not valid:\n" + problems.map { "  \($0)" }.joined(separator: "\n")
    }
}

/// Reads and writes forge.json, validating on load and reporting the offending
/// JSON pointer in readable text rather than a stack trace.
public struct ConfigStore: Sendable {
    private let logBus: LogBus

    public init(logBus: LogBus) { self.logBus = logBus }

    /// ~/Library/Application Support/RunnerForge/forge.json
    public static var defaultConfigPath: String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("RunnerForge/forge.json").path
    }

    public static var defaultWorkDir: String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("RunnerForge/work").path
    }

    /// Keystore key names. None of these may appear anywhere in forge.json.
    public static let forbiddenKeys = [
        "githubAppPrivateKey", "pacePassword", "azureClientId", "azureClientSecret",
        "azureTenantId", "appleDevIdP12", "appleDevIdP12Password",
        "appleAscIssuerId", "appleAscKeyId", "appleAscPrivateKey",
    ]

    public func load(from path: String = ConfigStore.defaultConfigPath) async throws -> ForgeConfig {
        guard FileManager.default.fileExists(atPath: path) else {
            await logBus.info("config", "no config at \(path); creating defaults")
            let created = ForgeConfig.makeDefault(workDir: Self.defaultWorkDir)
            try await save(created, to: path)
            return created
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try parse(data)
    }

    /// Parses and validates. Separate from `load` so the validation rules are
    /// directly testable without touching the filesystem.
    public func parse(_ data: Data) throws -> ForgeConfig {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigValidationError(problems: ["/ : the file is not valid JSON — \(error.localizedDescription)"])
        }

        guard let object = json as? [String: Any] else {
            throw ConfigValidationError(problems: ["/ : the top level must be an object"])
        }

        let problems = Self.validate(object)
        guard problems.isEmpty else { throw ConfigValidationError(problems: problems) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ForgeConfig.self, from: data)
    }

    /// The validation rules that matter, each reported against its JSON pointer.
    ///
    /// Hand-written rather than a schema library so the app carries no
    /// third-party dependency for something this small, and so the messages can
    /// say what to do about it.
    public static func validate(_ root: [String: Any]) -> [String] {
        var problems: [String] = []

        if (root["schemaVersion"] as? Int) != 1 {
            problems.append("/schemaVersion : must be 1")
        }

        // No secret may ever live in this file. Catching it here means a mistake
        // is reported rather than silently persisted.
        for forbidden in forbiddenKeys {
            if let pointer = findKey(forbidden, in: root) {
                problems.append(
                    "\(pointer) : '\(forbidden)' is a SECRET and must never appear in forge.json. "
                    + "It belongs in the macOS Keychain.")
            }
        }

        if let github = root["github"] as? [String: Any] {
            if (github["owner"] as? String).isNilOrEmpty { problems.append("/github/owner : must not be empty") }
            if (github["appId"] as? String).isNilOrEmpty { problems.append("/github/appId : must not be empty") }
            if (github["installationId"] as? String).isNilOrEmpty {
                problems.append("/github/installationId : must not be empty")
            }
            if ((github["repos"] as? [Any]) ?? []).isEmpty {
                problems.append("/github/repos : at least one repository is required")
            }
        } else {
            problems.append("/github : missing")
        }

        if let runners = root["runners"] as? [[String: Any]], !runners.isEmpty {
            for (index, runner) in runners.enumerated() {
                guard let classId = runner["classId"] as? String,
                      let runnerClass = RunnerClass.named(classId) else {
                    problems.append("/runners/\(index)/classId : not one of "
                                    + RunnerClass.all.map(\.classId).joined(separator: ", "))
                    continue
                }

                let replicas = runner["replicas"] as? Int ?? runnerClass.defaultReplicas
                if replicas < runnerClass.minReplicas || replicas > runnerClass.maxReplicas {
                    let extra = runnerClass.replicasAreFixed
                        ? " — an iLok class is fixed at 1 because there is one dongle"
                        : ""
                    problems.append(
                        "/runners/\(index)/replicas : \(replicas) is outside "
                        + "\(runnerClass.minReplicas)..\(runnerClass.maxReplicas) for \(classId)\(extra)")
                }

                let timeout = runner["jobTimeoutMinutes"] as? Int ?? 60
                if timeout < 1 || timeout > 720 {
                    problems.append("/runners/\(index)/jobTimeoutMinutes : \(timeout) is outside 1..720")
                }
            }
        } else {
            problems.append("/runners : at least one runner class is required")
        }

        if let signing = root["signing"] as? [String: Any] {
            let mode = signing["mode"] as? String ?? ""
            if SigningMode(rawValue: mode) == nil {
                problems.append("/signing/mode : '\(mode)' is not one of cloud, windows-ilok, macos-ilok")
            }
            if let windows = signing["windows"] as? [String: Any] {
                let provider = windows["provider"] as? String ?? ""
                if WindowsSigningProvider(rawValue: provider) == nil {
                    problems.append("/signing/windows/provider : '\(provider)' is not one of none, azure-trusted-signing")
                }
            }
        } else {
            problems.append("/signing : missing")
        }

        if let retention = root["retention"] as? [String: Any] {
            if retention["keepBaseImages"] as? Bool == false {
                problems.append("/retention/keepBaseImages : must be true — rebuilding base images costs tens of minutes")
            }
            if retention["keepTartImages"] as? Bool == false {
                problems.append("/retention/keepTartImages : must be true — only per-job clones are ever deleted")
            }
            let days = retention["logRetentionDays"] as? Int ?? 7
            if days < 1 || days > 365 {
                problems.append("/retention/logRetentionDays : \(days) is outside 1..365")
            }
        }

        if let limits = root["limits"] as? [String: Any] {
            let gb = limits["maxDiskGb"] as? Int ?? 120
            if gb < 20 || gb > 4096 { problems.append("/limits/maxDiskGb : \(gb) is outside 20..4096") }
        }

        if root["telemetry"] as? Bool == true {
            problems.append("/telemetry : must be false — Runner Forge sends no telemetry")
        }

        if let paths = root["paths"] as? [String: Any],
           (paths["workDir"] as? String).isNilOrEmpty {
            problems.append("/paths/workDir : must not be empty")
        }

        return problems
    }

    /// Finds a key anywhere in the document, returning its JSON pointer.
    static func findKey(_ key: String, in node: Any, pointer: String = "") -> String? {
        if let object = node as? [String: Any] {
            for (name, value) in object {
                if name == key { return "\(pointer)/\(name)" }
                if let found = findKey(key, in: value, pointer: "\(pointer)/\(name)") { return found }
            }
        } else if let array = node as? [Any] {
            for (index, value) in array.enumerated() {
                if let found = findKey(key, in: value, pointer: "\(pointer)/\(index)") { return found }
            }
        }
        return nil
    }

    public func save(_ config: ForgeConfig, to path: String = ConfigStore.defaultConfigPath) async throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        // Write to a temp file and move into place, so a crash mid-write cannot
        // leave a truncated config that the next launch refuses to load.
        let temporary = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: temporary))
        _ = try FileManager.default.replaceItemAt(
            URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temporary))

        await logBus.info("config", "saved \(path)")
    }
}

extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        self?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}
