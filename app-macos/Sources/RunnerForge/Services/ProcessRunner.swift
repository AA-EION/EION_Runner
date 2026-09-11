import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { exitCode == 0 }

    /// Both streams, for error messages that should show everything.
    public var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }
}

/// Runs external processes and streams their output into the LogBus.
///
/// Secrets are passed through `environment` or standard input, NEVER through
/// arguments: an argument list is readable by any user on the machine via the
/// process list. There is deliberately no overload that takes a secret as an
/// argument.
public struct ProcessRunner: Sendable {
    private let logBus: LogBus

    public init(logBus: LogBus) { self.logBus = logBus }

    public func run(
        _ executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        standardInput: String? = nil,
        logSource: String = "process",
        streamOutput: Bool = true
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = Self.resolve(executable)
        process.arguments = arguments

        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
                // Anything injected as an environment variable is, by definition,
                // something we do not want echoed back at us.
                await logBus.registerSecret(value)
            }
            process.environment = merged
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe: Pipe? = standardInput != nil ? Pipe() : nil
        if let inputPipe { process.standardInput = inputPipe }

        // The argument list is logged, which is safe precisely because secrets
        // are never in it. Redaction still runs as a second line of defence.
        await logBus.debug(logSource, "$ \(executable) \(arguments.joined(separator: " "))")

        try process.run()

        if let inputPipe, let standardInput {
            // The JIT config arrives this way. It is written, flushed, and the
            // handle closed immediately; the value never touches a file.
            await logBus.registerSecret(standardInput)
            inputPipe.fileHandleForWriting.write(Data((standardInput + "\n").utf8))
            try? inputPipe.fileHandleForWriting.close()
        }

        let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
        let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()

        process.waitUntilExit()

        let output = String(decoding: outputData, as: UTF8.self)
        let errorOutput = String(decoding: errorData, as: UTF8.self)

        if streamOutput {
            for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                await logBus.info(logSource, String(line))
            }
            for line in errorOutput.split(separator: "\n", omittingEmptySubsequences: true) {
                await logBus.warning(logSource, String(line))
            }
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: output,
            standardError: errorOutput)
    }

    /// Resolves a bare name against PATH, or uses the path as given.
    static func resolve(_ executable: String) -> URL {
        if executable.contains("/") { return URL(fileURLWithPath: executable) }

        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        for directory in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }

        return URL(fileURLWithPath: "/usr/bin/env")
    }

    /// True when the executable can be found on PATH.
    public static func isOnPath(_ executable: String) -> Bool {
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        for directory in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return true }
        }
        return false
    }
}
