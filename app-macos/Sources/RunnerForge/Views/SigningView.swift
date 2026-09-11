import AppKit
import Foundation
import Observation
import SwiftUI

/// Drives the Signing page.
@MainActor
@Observable
public final class SigningModel {
    private let store: ForgeStore

    public var requirements: [SigningRequirement] = []
    public var isChecking = false
    public var dryRunOutputPath = ""
    public var dryRunMessage: String?

    public init(store: ForgeStore) { self.store = store }

    public var mode: SigningMode {
        get { store.config.signing.modeValue }
        set {
            store.config.signing.modeValue = newValue
            // Cloud signing is the only mode where --allowsigningservice applies;
            // sending it with a physical dongle attached is a wraptool error, not
            // a no-op.
            store.config.signing.allowSigningService = (newValue == .cloud)
            store.markDirty()
            Task { await refresh() }
        }
    }

    public var windowsProvider: WindowsSigningProvider {
        get { WindowsSigningProvider(rawValue: store.config.signing.windows.provider) ?? .none }
        set { store.config.signing.windows.provider = newValue.rawValue; store.markDirty() }
    }

    public var wcGuid: String {
        get { store.config.signing.paceWcGuid }
        set { store.config.signing.paceWcGuid = newValue; store.markDirty() }
    }

    public var signId: String {
        get { store.config.signing.paceSignId }
        set { store.config.signing.paceSignId = newValue; store.markDirty() }
    }

    public var teamId: String {
        get { store.config.signing.macos.teamId }
        set { store.config.signing.macos.teamId = newValue; store.markDirty() }
    }

    public var devIdAppIdentity: String {
        get { store.config.signing.macos.devIdAppIdentity }
        set { store.config.signing.macos.devIdAppIdentity = newValue; store.markDirty() }
    }

    public var devIdInstallerIdentity: String {
        get { store.config.signing.macos.devIdInstallerIdentity }
        set { store.config.signing.macos.devIdInstallerIdentity = newValue; store.markDirty() }
    }

    public var notarize: Bool {
        get { store.config.signing.macos.notarize }
        set { store.config.signing.macos.notarize = newValue; store.markDirty() }
    }

    public var unmetCount: Int { requirements.filter { !$0.satisfied }.count }
    public var isSatisfied: Bool { !requirements.isEmpty && unmetCount == 0 }

    /// Why turning notarization off is not a convenience setting.
    public static let staplingNote = """
        Notarization staples a ticket into the artifact. Without the staple, the plugin fails Gatekeeper \
        on every machine except the one that built it — and it fails silently, as a plugin the host \
        simply does not list.
        """

    public func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        requirements = await store.services.signingService
            .requirements(for: mode, config: store.config)
    }

    /// Runs the signing path with --dry-run: every argument is assembled and
    /// printed, nothing is signed, and passwords come out redacted.
    public func dryRun() async {
        let path = dryRunOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            dryRunMessage = "Pick a bundle to dry-run against first."
            return
        }

        do {
            let ok = try await store.services.signingService.signAax(
                config: store.config,
                scriptsDirectory: store.services.scriptsDirectory,
                bundlePath: path,
                dryRun: true)
            dryRunMessage = ok
                ? "Dry run completed. The exact wraptool command is on the Logs page, with the password redacted."
                : "Dry run failed. See the Logs page."
        } catch {
            dryRunMessage = "Dry run failed: \(error)"
        }
    }
}


public struct SigningView: View {
    @State private var model: SigningModel

    public init(store: ForgeStore) {
        _model = State(initialValue: SigningModel(store: store))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader("Signing",
                           "How AAX and macOS artifacts get signed, and exactly what is still missing.")

                GroupBox("AAX signing mode") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Mode", selection: $model.mode) {
                            ForEach(SigningMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)

                        LabeledContent("WC GUID") {
                            TextField("", text: $model.wcGuid).textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Sign id") {
                            TextField("", text: $model.signId).textFieldStyle(.roundedBorder)
                        }

                        if model.mode == .cloud {
                            ExplanationBox(
                                text: "Cloud mode adds --allowsigningservice to wraptool. It is the only "
                                    + "mode that flag belongs in: with a physical dongle attached wraptool "
                                    + "rejects it.")
                        }
                        if model.mode == .macosIlok {
                            ExplanationBox(
                                symbol: "externaldrive.connected.to.line.below",
                                text: "The dongle must be plugged into this Mac, and the mac-ilok class "
                                    + "must be enabled on the Targets page. It runs as a host process "
                                    + "because no container can see a USB device.")
                        }
                        if model.mode == .windowsIlok {
                            ExplanationBox(
                                text: "The dongle lives in the Windows PC. This Mac hands its AAX bundles "
                                    + "to the win-ilok runner through the sign workflow; nothing is signed "
                                    + "here.")
                        }
                    }
                    .padding(6)
                }

                GroupBox("macOS Developer ID") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Team id") {
                            TextField("", text: $model.teamId).textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Application identity") {
                            TextField("Developer ID Application: …", text: $model.devIdAppIdentity)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Installer identity") {
                            TextField("Developer ID Installer: …", text: $model.devIdInstallerIdentity)
                                .textFieldStyle(.roundedBorder)
                        }
                        Toggle("Notarize and staple", isOn: $model.notarize)
                        ExplanationBox(symbol: "seal", text: SigningModel.staplingNote)
                        ExplanationBox(
                            symbol: "exclamationmark.triangle",
                            text: "Signing walks nested bundles inside-out and never uses codesign --deep. "
                                + "--deep is deprecated and re-signs nested code with the outer bundle's "
                                + "entitlements, which silently produces a bundle that fails validation.")
                    }
                    .padding(6)
                }

                GroupBox("Windows Authenticode") {
                    Picker("Provider", selection: $model.windowsProvider) {
                        Text("None (unsigned)").tag(WindowsSigningProvider.none)
                        Text("Azure Trusted Signing").tag(WindowsSigningProvider.azureTrustedSigning)
                    }
                    .pickerStyle(.radioGroup)
                    .padding(6)
                }

                GroupBox("Requirements") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(model.isChecking ? "Checking…" : "Re-check") {
                                Task { await model.refresh() }
                            }
                            .disabled(model.isChecking)
                            Spacer()
                            StatusBadge(text: model.isSatisfied ? "ready" : "\(model.unmetCount) missing",
                                        tint: model.isSatisfied ? .green : .orange)
                        }

                        ForEach(model.requirements) { requirement in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: requirement.satisfied
                                      ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(requirement.satisfied ? .green : .red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(requirement.description)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let fix = requirement.howToFix, !requirement.satisfied {
                                        Text(fix).font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox("Dry run") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("path to a bundle", text: $model.dryRunOutputPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") { chooseBundle() }
                            Button("Dry run") { Task { await model.dryRun() } }
                        }
                        Text("Assembles and prints the exact command without signing anything. "
                             + "Passwords come out as <redacted>.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let message = model.dryRunMessage {
                            Text(message).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(6)
                }
            }
            .padding(20)
        }
        .task { await model.refresh() }
    }

    private func chooseBundle() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.dryRunOutputPath = url.path
        }
    }
}
