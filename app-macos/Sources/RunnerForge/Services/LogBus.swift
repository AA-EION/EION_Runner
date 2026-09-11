import Foundation

public enum LogLevel: Int, Sendable, Comparable, CaseIterable, Identifiable {
    case debug = 0, info, warning, error

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LogEntry: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let timestamp: Date
    public let level: LogLevel
    public let source: String
    public let message: String

    public var formatted: String {
        let time = LogEntry.timeFormatter.string(from: timestamp)
        return "\(time) [\(level.label)] \(source) \(message)"
    }

    /// The file sink's form. A support log read days later needs the date; the
    /// UI's time-only column does not.
    public var formattedWithDate: String {
        let stamp = LogEntry.fileFormatter.string(from: timestamp)
        return "\(stamp) [\(level.label)] \(source) \(message)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return formatter
    }()
}

/// The single place every log line passes through, so redaction cannot be
/// bypassed by forgetting to call it.
///
/// EVERY line is redacted before it reaches the UI, a file, or the pasteboard.
/// Secrets are registered by VALUE when read from the Keychain and any
/// occurrence is replaced with `***`. That is deliberately value-based rather
/// than pattern-based: patterns miss things, and a secret that reaches a log has
/// already leaked.
///
/// An actor because log lines arrive from many concurrent subprocess readers.
public actor LogBus {
    private var entries: [LogEntry] = []
    private var secretValues: [String] = []
    private var observers: [UUID: @Sendable (LogEntry) -> Void] = [:]
    private let maxEntries = 20_000

    // -----------------------------------------------------------------------
    // The file sink.
    //
    // Without it, a crash before the window appears leaves the user with no
    // window AND no record of why — which is exactly the position the Windows
    // app was in, and it took a CI run with a log dump to get out of it. The
    // lines written here are the same ones the UI gets, so they are ALREADY
    // REDACTED: redaction happens inside write(), before anything leaves it.
    // -----------------------------------------------------------------------

    /// `~/Library/Logs/RunnerForge/runnerforge.log` — where Console.app and
    /// every Mac user already looks for an application log.
    public static let defaultLogPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Logs/RunnerForge/runnerforge.log")
            .path
    }()

    /// Set once a write fails. Logging must never be the thing that takes the
    /// app down, and there is nowhere left to report a logging failure to.
    private var fileUnavailable = false
    private var fileHandle: FileHandle?

    private let maxLogBytes = 8 * 1024 * 1024

    public init() {}

    /// Shapes that are secret regardless of whether we hold the value.
    private static let shapePatterns: [(pattern: String, replacement: String)] = [
        ("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----",
         "***PRIVATE KEY REDACTED***"),
        ("(?i)(authorization:\\s*(bearer|token)\\s+)\\S+", "$1***"),
        ("(?i)(--(password|token|jitconfig|client-secret)[= ])\\S+", "$1***"),
        ("(?i)\\b(ghp_|gho_|ghs_|github_pat_)[A-Za-z0-9_]{20,}", "***"),
    ]

    /// Registers a secret so it is scrubbed from every subsequent line. Call this
    /// the moment a secret is read from the Keychain.
    public func registerSecret(_ value: String?) {
        // Very short values would match far too much and turn logs into noise.
        guard let value, value.count >= 8, !secretValues.contains(value) else { return }
        secretValues.append(value)
    }

    public func forgetSecrets() { secretValues.removeAll() }

    public func redact(_ message: String) -> String {
        var result = message

        for secret in secretValues {
            result = result.replacingOccurrences(of: secret, with: "***")
        }

        for (pattern, replacement) in Self.shapePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement)
        }

        return result
    }

    public func write(_ level: LogLevel, _ source: String, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, source: source, message: redact(message))
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        for observer in observers.values { observer(entry) }
        appendToFile(entry)
    }

    private func appendToFile(_ entry: LogEntry) {
        guard !fileUnavailable else { return }

        do {
            let handle = try openLogFile()
            guard let data = (entry.formattedWithDate + "\n").data(using: .utf8) else { return }
            try handle.write(contentsOf: data)
        } catch {
            // One failure is enough: stop trying rather than throwing on every
            // subsequent line.
            fileUnavailable = true
            fileHandle = nil
        }
    }

    private func openLogFile() throws -> FileHandle {
        if let handle = fileHandle {
            // Rotate once the file is large, keeping exactly one previous file.
            // Unbounded growth on a machine that hosts runners for days is a
            // real disk problem, and two files is all anyone reads.
            let size = try handle.offset()
            if size < UInt64(maxLogBytes) { return handle }

            try handle.close()
            fileHandle = nil

            let fileManager = FileManager.default
            let path = Self.defaultLogPath
            let previous = path + ".1"
            try? fileManager.removeItem(atPath: previous)
            try? fileManager.moveItem(atPath: path, toPath: previous)
        }

        let fileManager = FileManager.default
        let path = Self.defaultLogPath
        let directory = (path as NSString).deletingLastPathComponent

        try fileManager.createDirectory(
            atPath: directory, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(atPath: path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        fileHandle = handle
        return handle
    }

    public func debug(_ source: String, _ message: String) { write(.debug, source, message) }
    public func info(_ source: String, _ message: String) { write(.info, source, message) }
    public func warning(_ source: String, _ message: String) { write(.warning, source, message) }
    public func error(_ source: String, _ message: String) { write(.error, source, message) }

    public func snapshot() -> [LogEntry] { entries }

    public func clear() { entries.removeAll() }

    /// Already redacted, so it is safe to write to a file or the pasteboard.
    public func plainText() -> String {
        entries.map(\.formatted).joined(separator: "\n")
    }

    @discardableResult
    public func observe(_ observer: @escaping @Sendable (LogEntry) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    public func stopObserving(_ token: UUID) { observers[token] = nil }
}
