import SwiftUI

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
