import Foundation
import Observation

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

    public var id: String { keyName }

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
