import Foundation

/// Says exactly what is missing on this Mac, and fixes what it can.
///
/// An Intel Mac is a HARD BLOCK with no workaround: Tart uses Apple's
/// Virtualization framework, which requires Apple Silicon. Saying so here is far
/// kinder than letting the user find out three failed builds later.
public struct PreflightService: Sendable {
    private let logBus: LogBus
    private let processRunner: ProcessRunner
    private let tartService: TartService
    private let session: URLSession

    public init(logBus: LogBus, processRunner: ProcessRunner, tartService: TartService,
                session: URLSession = .shared) {
        self.logBus = logBus
        self.processRunner = processRunner
        self.tartService = tartService
        self.session = session
    }

    public static let minimumMacOs = "26.0"
    public static let minimumTart = "2.27.0"

    public func runAll(config: ForgeConfig) async -> [PreflightCheck] {
        var checks: [PreflightCheck] = []

        checks.append(checkAppleSilicon())
        checks.append(checkMacOsVersion())
        checks.append(await checkTart())
        checks.append(await checkXcode())
        checks.append(await checkRosetta())
        checks.append(checkFreeDisk(config: config))
        checks.append(await checkSleep())

        for endpoint in ["github.com", "api.github.com", "ghcr.io"] {
            checks.append(await checkEndpoint(endpoint))
        }

        checks.append(await checkBaseImage())
        checks.append(contentsOf: await checkDeveloperIdentities())
        checks.append(await checkNotarytool())

        if config.signing.modeValue == .macosIlok {
            checks.append(contentsOf: await checkIlok())
        } else {
            checks.append(PreflightCheck(
                name: "iLok checks", status: .pass,
                detail: "skipped: signing mode is '\(config.signing.mode)', which needs no dongle on this host"))
        }

        return checks
    }

    private func checkAppleSilicon() -> PreflightCheck {
        #if arch(arm64)
        return PreflightCheck(name: "Apple Silicon", status: .pass, detail: "arm64")
        #else
        return PreflightCheck(
            name: "Apple Silicon", status: .fail,
            detail: "This Mac is not Apple Silicon. Tart uses Apple's Virtualization framework, which "
                  + "requires Apple Silicon. There is no supported fallback.",
            fixHint: "Use an Apple Silicon Mac for the mac-build class.",
            blocksClasses: ["mac-build", "mac-ilok"],
            isHardBlock: true)
        #endif
    }

    private func checkMacOsVersion() -> PreflightCheck {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let actual = "\(version.majorVersion).\(version.minorVersion)"

        return Self.versionAtLeast(actual, Self.minimumMacOs)
            ? PreflightCheck(name: "macOS version", status: .pass,
                             detail: "\(actual) (minimum \(Self.minimumMacOs))")
            : PreflightCheck(name: "macOS version", status: .fail,
                             detail: "\(actual) is below the minimum \(Self.minimumMacOs).",
                             fixHint: "Update macOS.", blocksClasses: ["mac-build"])
    }

    private func checkTart() async -> PreflightCheck {
        guard let status = try? await tartService.status(), status.installed else {
            return PreflightCheck(
                name: "Tart installed", status: .fail, detail: "tart is not on PATH.",
                fixHint: "brew install cirruslabs/cli/tart",
                autoFixable: true, blocksClasses: ["mac-build"])
        }

        let version = (status.version ?? "").filter { $0.isNumber || $0 == "." }

        return Self.versionAtLeast(version, Self.minimumTart)
            ? PreflightCheck(name: "Tart installed", status: .pass,
                             detail: "\(version) (minimum \(Self.minimumTart))")
            : PreflightCheck(name: "Tart installed", status: .warn,
                             detail: "tart \(version) is below the pinned minimum \(Self.minimumTart).",
                             fixHint: "brew upgrade cirruslabs/cli/tart",
                             autoFixable: true, blocksClasses: ["mac-build"])
    }

    private func checkXcode() async -> PreflightCheck {
        guard let selected = try? await processRunner.run(
            "xcode-select", arguments: ["-p"], logSource: "preflight", streamOutput: false),
              selected.succeeded else {
            return PreflightCheck(
                name: "Xcode", status: .fail,
                detail: "xcode-select does not point at a valid developer directory.",
                fixHint: "Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app",
                blocksClasses: ["mac-build"])
        }

        guard let build = try? await processRunner.run(
            "xcodebuild", arguments: ["-version"], logSource: "preflight", streamOutput: false),
              build.succeeded else {
            return PreflightCheck(
                name: "Xcode", status: .fail,
                detail: "xcodebuild fails — the licence is probably unaccepted.",
                fixHint: "sudo xcodebuild -license accept", blocksClasses: ["mac-build"])
        }

        let firstLine = build.standardOutput.split(separator: "\n").first.map(String.init) ?? "Xcode"
        return PreflightCheck(name: "Xcode", status: .pass,
                              detail: "\(firstLine) at \(selected.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    private func checkRosetta() async -> PreflightCheck {
        if FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta") {
            return PreflightCheck(name: "Rosetta 2", status: .pass, detail: "installed")
        }

        return PreflightCheck(
            name: "Rosetta 2", status: .warn,
            detail: "not installed. Needed for x86_64 slices of universal2 builds and some Intel-only tooling.",
            fixHint: "softwareupdate --install-rosetta --agree-to-license",
            autoFixable: true, blocksClasses: ["mac-build"])
    }

    private func checkFreeDisk(config: ForgeConfig) -> PreflightCheck {
        let freeGb = Double(tartService.freeDiskBytes()) / 1024 / 1024 / 1024

        return Int(freeGb) >= config.limits.maxDiskGb
            ? PreflightCheck(name: "Free disk space", status: .pass,
                             detail: String(format: "%.1f GB free (minimum %d GB)", freeGb, config.limits.maxDiskGb))
            : PreflightCheck(name: "Free disk space", status: .fail,
                             detail: String(format: "%.1f GB free, below the configured minimum of %d GB. "
                                            + "A macOS Tart image alone is tens of GB.",
                                            freeGb, config.limits.maxDiskGb),
                             fixHint: "Free space, or lower limits.maxDiskGb in forge.json.",
                             blocksClasses: ["mac-build"])
    }

    private func checkSleep() async -> PreflightCheck {
        // The app holds its own caffeinate assertion while runners are active;
        // this reports whether one is currently held.
        let result = try? await processRunner.run(
            "pgrep", arguments: ["-x", "caffeinate"], logSource: "preflight", streamOutput: false)

        return (result?.succeeded ?? false)
            ? PreflightCheck(name: "Sleep prevented while runners are active", status: .pass,
                             detail: "a caffeinate assertion is held")
            : PreflightCheck(name: "Sleep prevented while runners are active", status: .warn,
                             detail: "no caffeinate assertion is currently held. Runner Forge takes one "
                                   + "automatically while runners are running; a sleeping Mac drops in-flight jobs.")
    }

    private func checkEndpoint(_ endpoint: String) async -> PreflightCheck {
        var request = URLRequest(url: URL(string: "https://\(endpoint)")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15

        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // A 4xx still proves reachability; only a transport failure matters.
            return PreflightCheck(name: "Outbound HTTPS: \(endpoint)", status: .pass,
                                  detail: "HTTP \(code) (reachable)")
        } catch {
            return PreflightCheck(
                name: "Outbound HTTPS: \(endpoint)", status: .fail,
                detail: "unreachable: \(error.localizedDescription)",
                fixHint: "Check your firewall, proxy, or corporate TLS inspection settings.",
                blocksClasses: ["mac-build", "mac-ilok"])
        }
    }

    private func checkBaseImage() async -> PreflightCheck {
        guard let status = try? await tartService.status(), status.installed else {
            return PreflightCheck(name: "Base Tart image", status: .warn, detail: "tart is not installed")
        }

        let provisioned = status.images.filter { $0.contains("runnerforge-macos") }

        return provisioned.isEmpty
            ? PreflightCheck(name: "Base Tart image", status: .warn,
                             detail: "not built yet. Informational: the first build takes a long time but "
                                   + "only happens once.",
                             fixHint: "packer build images/macos/packer/runnerforge-macos.pkr.hcl",
                             autoFixable: true)
            : PreflightCheck(name: "Base Tart image", status: .pass,
                             detail: provisioned.joined(separator: ", "))
    }

    private func checkDeveloperIdentities() async -> [PreflightCheck] {
        guard let result = try? await processRunner.run(
            "security", arguments: ["find-identity", "-v", "-p", "codesigning"],
            logSource: "preflight", streamOutput: false) else {
            return [PreflightCheck(name: "Developer ID identities", status: .warn,
                                   detail: "could not query the keychain")]
        }

        // Both certificates are needed and they are DIFFERENT: Application signs
        // the bundles, Installer signs the .pkg.
        return ["Developer ID Application", "Developer ID Installer"].map { kind in
            result.standardOutput.contains(kind)
                ? PreflightCheck(name: "\(kind) identity", status: .pass, detail: "present in the keychain")
                : PreflightCheck(name: "\(kind) identity", status: .warn,
                                 detail: "no '\(kind)' identity found. Only signing is affected; unsigned "
                                       + "builds still produce artifacts.",
                                 fixHint: "Import the certificate from your Apple Developer account.")
        }
    }

    private func checkNotarytool() async -> PreflightCheck {
        let result = try? await processRunner.run(
            "xcrun", arguments: ["--find", "notarytool"], logSource: "preflight", streamOutput: false)

        return (result?.succeeded ?? false)
            ? PreflightCheck(name: "xcrun notarytool", status: .pass,
                             detail: result!.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            : PreflightCheck(name: "xcrun notarytool", status: .warn,
                             detail: "notarytool is not available. Notarization will be skipped; stapling "
                                   + "then cannot happen either, and the artifact fails Gatekeeper offline.",
                             fixHint: "Install a current Xcode.")
    }

    private func checkIlok() async -> [PreflightCheck] {
        var checks: [PreflightCheck] = []

        let driverPresent = FileManager.default.fileExists(atPath: "/Library/Application Support/PACE")
        checks.append(driverPresent
            ? PreflightCheck(name: "iLok driver", status: .pass, detail: "PACE support files present")
            : PreflightCheck(name: "iLok driver", status: .fail,
                             detail: "The PACE/iLok driver is not installed.",
                             fixHint: "Install iLok License Manager.", blocksClasses: ["mac-ilok"]))

        let usb = try? await processRunner.run(
            "system_profiler", arguments: ["SPUSBDataType"], logSource: "preflight", streamOutput: false)

        let dongle = (usb?.standardOutput ?? "").lowercased().contains("ilok")
        checks.append(dongle
            ? PreflightCheck(name: "iLok dongle detected", status: .pass,
                             detail: "an iLok USB device is attached")
            : PreflightCheck(name: "iLok dongle detected", status: .fail,
                             detail: "No iLok USB device found.",
                             fixHint: "Plug the dongle into this Mac, or switch signing mode to Cloud.",
                             blocksClasses: ["mac-ilok"]))

        // The PACE installer does NOT put wraptool on PATH, so asking PATH
        // reports "missing" on a machine where it is installed and working. Use
        // the same discovery the Signing page and the signing scripts use, so
        // the two pages cannot disagree about whether it is there.
        checks.append(SigningService.findWraptool().map { path in
            PreflightCheck(name: "wraptool available", status: .pass, detail: path)
        } ?? PreflightCheck(
            name: "wraptool available", status: .fail,
            detail: "wraptool was not found on PATH, at the PACE Fusion SDK install path, "
                + "or via the WRAPTOOL environment variable.",
            fixHint: "Install the PACE Fusion SDK (it ships wraptool under "
                + "/Applications/PACEAntiPiracy/Eden/Fusion/Versions/<version>/bin), "
                + "or set WRAPTOOL to its full path.",
            blocksClasses: ["mac-ilok"]))

        return checks
    }

    /// Compares dotted versions numerically.
    ///
    /// Hand-written because a lexical comparison gets "2.9.0" vs "2.27.0"
    /// backwards, which is exactly the kind of bug that silently accepts an
    /// out-of-date tool.
    public static func versionAtLeast(_ actual: String, _ minimum: String) -> Bool {
        let left = actual.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let right = minimum.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }

        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l > r { return true }
            if l < r { return false }
        }

        return true
    }
}
