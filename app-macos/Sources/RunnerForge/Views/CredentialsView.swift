import Foundation
import Observation
import SwiftUI

/// One editable credential row.
///
/// `value` is a scratch buffer for what the user is typing. It is cleared the
/// instant the secret reaches the Keychain, and it is never copied into
/// ForgeConfig — forge.json holds identifiers only.
@MainActor
@Observable
public final class CredentialField: Identifiable {
    public let keyName: String
    public let displayName: String
    public let help: String
    public let isMultiline: Bool
    public var value: String = ""
    public var isStored: Bool = false

    // `Identifiable` is a nonisolated protocol, so a main-actor-isolated `id`
    // cannot satisfy it under Swift 6. `keyName` is an immutable `let` of a
    // Sendable type, so reading it off the main actor is safe.
    public nonisolated var id: String { keyName }

    public init(keyName: String, displayName: String, help: String, isMultiline: Bool = false) {
        self.keyName = keyName
        self.displayName = displayName
        self.help = help
        self.isMultiline = isMultiline
    }
}

/// Drives the Credentials page.
@MainActor
@Observable
public final class CredentialsModel {
    private let store: ForgeStore

    public var fields: [CredentialField] = []
    public var statusMessage: String?
    public var testResult: String?
    public var isTesting = false

    public init(store: ForgeStore) {
        self.store = store
        fields = [
            CredentialField(
                keyName: "githubAppPrivateKey",
                displayName: "GitHub App private key (PEM)",
                help: "The .pem downloaded from the App's settings. Runner Forge signs a JWT with it and "
                    + "exchanges that for a short-lived installation token; no registration token is ever stored.",
                isMultiline: true),
            CredentialField(
                keyName: "paceAccount", displayName: "PACE account",
                help: "Your iLok / PACE account name, used by wraptool."),
            CredentialField(
                keyName: "pacePassword", displayName: "PACE password",
                help: "Passed to wraptool through the environment, never through an argument list."),
            CredentialField(
                keyName: "azureClientId", displayName: "Azure client id",
                help: "Azure Trusted Signing service principal. Only needed for Authenticode."),
            CredentialField(
                keyName: "azureClientSecret", displayName: "Azure client secret",
                help: "Azure Trusted Signing service principal secret."),
            CredentialField(
                keyName: "azureTenantId", displayName: "Azure tenant id",
                help: "Azure directory the signing account belongs to."),
            CredentialField(
                keyName: "appleDevIdP12", displayName: "Developer ID .p12 (base64)",
                help: "base64 of the exported Developer ID Application certificate and key. Imported into an "
                    + "ephemeral keychain for the duration of a signing job, then deleted.",
                isMultiline: true),
            CredentialField(
                keyName: "appleDevIdP12Password", displayName: "Developer ID .p12 password",
                help: "The export password for the .p12 above."),
            CredentialField(
                keyName: "appleAscIssuerId", displayName: "App Store Connect issuer id",
                help: "notarytool authentication. A UUID from App Store Connect."),
            CredentialField(
                keyName: "appleAscKeyId", displayName: "App Store Connect key id",
                help: "notarytool authentication. The 10-character key id."),
            CredentialField(
                keyName: "appleAscPrivateKey", displayName: "App Store Connect .p8 key",
                help: "The AuthKey_XXXXXXXX.p8 contents. Written to a 0600 temporary file only for the "
                    + "duration of the notarytool call, then removed.",
                isMultiline: true),
        ]
    }

    public func refresh() async {
        await store.refreshSecretPresence()
        for field in fields {
            field.isStored = store.secretPresence[field.keyName] ?? false
        }
    }

    public func save(_ field: CredentialField) async {
        let secret = field.value
        guard !secret.isEmpty else {
            statusMessage = "\(field.displayName): nothing to save."
            return
        }

        let ok = await store.services.secretStore.write(field.keyName, secret)

        // Clear the scratch buffer whether or not the write succeeded: leaving a
        // secret in memory bound to a text field is exactly what this page exists
        // to avoid.
        field.value = ""
        field.isStored = ok
        statusMessage = ok
            ? "\(field.displayName) saved to the Keychain."
            : "\(field.displayName) could not be saved; see the Logs page."

        await store.refreshSecretPresence()
        await store.services.refreshRedaction()
    }

    public func delete(_ field: CredentialField) async {
        _ = await store.services.secretStore.delete(field.keyName)
        field.value = ""
        field.isStored = false
        statusMessage = "\(field.displayName) removed from the Keychain."
        await store.refreshSecretPresence()
        await store.services.refreshRedaction()
    }

    public var appId: String {
        get { store.config.github.appId }
        set { store.config.github.appId = newValue; store.markDirty() }
    }

    public var installationId: String {
        get { store.config.github.installationId }
        set { store.config.github.installationId = newValue; store.markDirty() }
    }

    /// Mints a real installation token and reports what it is good for. This is
    /// the only honest test: a key that parses is not a key GitHub accepts.
    public func testGitHubApp() async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }

        do {
            testResult = try await store.services.appService.testAppCredentials(config: store.config)
        } catch {
            testResult = "FAIL: \(error)"
        }
    }
}


public struct CredentialsView: View {
    @Bindable private var store: ForgeStore
    @State private var model: CredentialsModel

    public init(store: ForgeStore) {
        _store = Bindable(wrappedValue: store)
        _model = State(initialValue: CredentialsModel(store: store))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader("Credentials",
                           "Every secret lives in the login Keychain. None of them is ever written to forge.json.")

                ExplanationBox(
                    symbol: "lock.shield",
                    text: "Runner Forge stores identifiers — App id, installation id, certificate common "
                        + "names — in forge.json, and secrets in the Keychain under "
                        + "\(SecretStore.service). Secrets reach a child process through its environment, "
                        + "never through its argument list, because an argument list is readable by any "
                        + "user on the machine. Log output is redacted by value and by shape.")

                GroupBox("GitHub App") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("App id") {
                            TextField("123456", text: $store.config.github.appId)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: store.config.github.appId) { _, _ in store.markDirty() }
                        }
                        LabeledContent("Installation id") {
                            TextField("12345678", text: $store.config.github.installationId)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: store.config.github.installationId) { _, _ in
                                    store.markDirty()
                                }
                        }
                        HStack {
                            Button(model.isTesting ? "Testing…" : "Test credentials") {
                                Task { await model.testGitHubApp() }
                            }
                            .disabled(model.isTesting)

                            if let outcome = model.testResult {
                                Text(outcome)
                                    .font(.caption)
                                    .foregroundStyle(outcome.hasPrefix("FAIL") ? .red : .green)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("Test mints a real installation token. A key that merely parses is not a key "
                             + "GitHub accepts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                if let message = model.statusMessage {
                    ExplanationBox(symbol: "checkmark.circle", text: message)
                }

                ForEach(model.fields) { field in
                    CredentialRow(field: field,
                                  onSave: { Task { await model.save(field) } },
                                  onDelete: { Task { await model.delete(field) } })
                }
            }
            .padding(20)
        }
        .task { await model.refresh() }
    }
}

private struct CredentialRow: View {
    @Bindable var field: CredentialField
    let onSave: () -> Void
    let onDelete: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(field.displayName).font(.headline)
                    Spacer()
                    StatusBadge(text: field.isStored ? "stored" : "not set",
                                tint: field.isStored ? .green : .secondary)
                }

                Text(field.help).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if field.isMultiline {
                    // A multi-line secret (a PEM, a base64 .p12) cannot use
                    // SecureField, which is single-line. It is still never
                    // persisted anywhere but the Keychain, and the buffer is
                    // cleared the moment Save returns.
                    TextEditor(text: $field.value)
                        .font(.body.monospaced())
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                } else {
                    SecureField("", text: $field.value)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button("Save", action: onSave).disabled(field.value.isEmpty)
                    Button("Remove", role: .destructive, action: onDelete).disabled(!field.isStored)
                    Spacer()
                }
            }
            .padding(6)
        }
    }
}
