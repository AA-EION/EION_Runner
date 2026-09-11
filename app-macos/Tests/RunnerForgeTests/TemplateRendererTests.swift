import Foundation
import Testing
@testable import RunnerForge

/// A workflow that still contains a {{placeholder}} is accepted by git and
/// rejected by Actions, minutes later and far less clearly. The renderer's job
/// is to make that impossible.
@Suite("TemplateRenderer")
struct TemplateRendererTests {

    @Test("substitutes every occurrence of a key")
    func substitutesRepeatedKeys() throws {
        let output = try TemplateRenderer().render(
            "{{name}} and {{name}} again", values: ["name": "Canary"])
        #expect(output == "Canary and Canary again")
    }

    @Test("a leftover placeholder is an error, not a warning")
    func leftoverPlaceholderThrows() {
        #expect(throws: TemplateRenderer.UnsubstitutedPlaceholderError.self) {
            try TemplateRenderer().render("runs-on: {{missing}}", values: [:])
        }
    }

    /// The error has to say WHICH placeholder, or the user is left diffing a
    /// 300-line workflow by eye.
    @Test("the error names every missing key")
    func errorNamesMissingKeys() {
        do {
            _ = try TemplateRenderer().render("{{alpha}} {{beta}}", values: ["alpha": "a"])
            Issue.record("expected the render to throw")
        } catch let error as TemplateRenderer.UnsubstitutedPlaceholderError {
            #expect(error.keys == ["beta"])
            #expect(error.description.contains("beta"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("placeholders(in:) lists keys once, sorted")
    func placeholderDiscovery() {
        let found = TemplateRenderer().placeholders(in: "{{b}} {{a}} {{b}}")
        #expect(found == ["a", "b"])
    }

    @Test("a template with no placeholders is returned unchanged")
    func noPlaceholders() throws {
        let text = "name: build\non: push\n"
        #expect(try TemplateRenderer().render(text, values: [:]) == text)
    }

    /// The substitution map must cover the shipped templates. This is the test
    /// that catches a template gaining a placeholder nobody wired up.
    @Test("buildValues covers every placeholder in the shipped templates")
    func buildValuesCoversTemplates() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RunnerForgeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app-macos
            .deletingLastPathComponent()   // repo root
        let templates = repoRoot.appendingPathComponent("templates")

        guard FileManager.default.fileExists(atPath: templates.path) else {
            // Running from an installed copy rather than the repo. Say so rather
            // than passing silently on an assertion that never ran.
            Issue.record("templates/ not found at \(templates.path); this test must run from the repo")
            return
        }

        var config = ForgeConfig.makeDefault(workDir: "/tmp/rf")
        config.github = GitHubConfig(
            owner: "example", repos: ["plugin"], appId: "1", installationId: "2")

        let values = TemplateRenderer.buildValues(
            config: config, projectName: "Canary", sourceDir: ".",
            secretPresence: Dictionary(uniqueKeysWithValues: SecretStore.keyNames.map { ($0, true) }))

        let renderer = TemplateRenderer()
        let names = try FileManager.default.contentsOfDirectory(atPath: templates.path)
            .filter { $0.hasSuffix(".tmpl") }
        #expect(!names.isEmpty)

        for name in names {
            let text = try String(
                contentsOf: templates.appendingPathComponent(name), encoding: .utf8)
            let missing = renderer.placeholders(in: text).filter { values[$0] == nil }
            #expect(missing.isEmpty, "\(name) has unmapped placeholders: \(missing)")
        }
    }

    /// --allowsigningservice belongs to cloud mode only. Emitting it with a
    /// physical dongle attached is a wraptool error, not a harmless extra flag.
    @Test("the AAX requirement flags follow the SDK setting")
    func aaxFlagsFollowSdk() {
        var config = ForgeConfig.makeDefault(workDir: "/tmp/rf")

        config.paths.aaxSdkSource = ""
        var values = TemplateRenderer.buildValues(
            config: config, projectName: "Canary", sourceDir: ".", secretPresence: [:])
        #expect(values["aaxRequired"] == "false")
        #expect(values["aaxSkipRequired"] == "true")

        config.paths.aaxSdkSource = "/Volumes/sdk/aax.zip"
        values = TemplateRenderer.buildValues(
            config: config, projectName: "Canary", sourceDir: ".", secretPresence: [:])
        #expect(values["aaxRequired"] == "true")
        #expect(values["aaxSkipRequired"] == "false")
    }

    /// Secret PRESENCE reaches the templates; secret VALUES never do.
    @Test("only presence, never a value, reaches the substitution map")
    func secretsNeverReachTemplates() {
        let config = ForgeConfig.makeDefault(workDir: "/tmp/rf")
        let values = TemplateRenderer.buildValues(
            config: config, projectName: "Canary", sourceDir: ".",
            secretPresence: ["pacePassword": true, "appleDevIdP12": false])

        #expect(values["havePacePassword"] == "yes")
        #expect(values["haveAppleP12"] == "no")
        for value in values.values {
            #expect(!value.contains("BEGIN PRIVATE KEY"))
            #expect(!value.contains("BEGIN RSA PRIVATE KEY"))
        }
    }

    // -----------------------------------------------------------------------
    // Publisher arguments
    //
    // wraptool takes EITHER a Wrap Config GUID OR a customer number paired with
    // the company name, and rejects the number on its own. These tests are the
    // only place that rule is checked before a twenty-minute build spends itself
    // proving it.
    // -----------------------------------------------------------------------

    private func exampleConfig() -> ForgeConfig {
        var config = ForgeConfig.makeDefault(workDir: "/tmp/rf")
        config.github = GitHubConfig(
            owner: "example", repos: ["plugin"], appId: "1", installationId: "2")
        return config
    }

    @Test("a Wrap Config GUID becomes a single wcguid argument")
    func wrapConfigBecomesOneArgument() {
        var config = exampleConfig()
        config.signing.paceWcGuid = "ED052BE6-9B79-4E72-A838-E226320B778E"

        #expect(TemplateRenderer.paceIdentityArgs(config, shell: true)
                == "--wcguid 'ED052BE6-9B79-4E72-A838-E226320B778E'")
        #expect(TemplateRenderer.paceIdentityArgs(config, shell: false)
                == "-WcGuid 'ED052BE6-9B79-4E72-A838-E226320B778E'")
    }

    @Test("a customer number always carries the company name with it")
    func customerNumberCarriesName() {
        var config = exampleConfig()
        config.signing.paceWcGuid = ""
        config.signing.paceCustomerNumber = "ABCD-1234-ABCD-1234"
        config.signing.paceCustomerName = "My Company, Inc."

        let shell = TemplateRenderer.paceIdentityArgs(config, shell: true)
        #expect(shell.contains("--customernumber 'ABCD-1234-ABCD-1234'"))
        #expect(shell.contains("--customername 'My Company, Inc.'"))
        #expect(!shell.contains("--wcguid"))

        let pwsh = TemplateRenderer.paceIdentityArgs(config, shell: false)
        #expect(pwsh.contains("-CustomerNumber 'ABCD-1234-ABCD-1234'"))
        #expect(pwsh.contains("-CustomerName 'My Company, Inc.'"))
    }

    /// The failure this guards against: emitting a workflow with no publisher
    /// argument at all, which fails inside wraptool minutes later with a message
    /// that never mentions the configuration.
    @Test("a customer number without a name emits a marker, never an empty string")
    func incompleteCustomerEmitsMarker() {
        var config = exampleConfig()
        config.signing.paceWcGuid = ""
        config.signing.paceCustomerNumber = "ABCD-1234-ABCD-1234"
        config.signing.paceCustomerName = ""

        let shell = TemplateRenderer.paceIdentityArgs(config, shell: true)
        #expect(!shell.trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(shell.contains("SET-A-WRAP-CONFIG"))
        #expect(!shell.contains("ABCD-1234"))
    }

    @Test("publisher identity needs a GUID, or both customer fields")
    func publisherIdentityRule() {
        var config = exampleConfig()

        config.signing.paceWcGuid = "G"
        config.signing.paceCustomerNumber = ""
        config.signing.paceCustomerName = ""
        #expect(config.signing.hasPublisherIdentity)

        config.signing.paceWcGuid = ""
        config.signing.paceCustomerNumber = "N"
        #expect(!config.signing.hasPublisherIdentity)

        config.signing.paceCustomerName = "Co"
        #expect(config.signing.hasPublisherIdentity)
    }

    @Test("the self-signed flag is emitted only when the certificate is self-signed")
    func selfSignedFlag() {
        var config = exampleConfig()

        config.signing.paceSelfSigned = false
        var values = TemplateRenderer.buildValues(
            config: config, projectName: "Canary", sourceDir: ".", secretPresence: [:])
        #expect(values["paceSelfSignedSh"] == "")
        #expect(values["paceSelfSignedPs"] == "")

        config.signing.paceSelfSigned = true
        values = TemplateRenderer.buildValues(
            config: config, projectName: "Canary", sourceDir: ".", secretPresence: [:])
        #expect(values["paceSelfSignedSh"]?.contains("--self-signed") == true)
        #expect(values["paceSelfSignedPs"]?.contains("-SelfSigned") == true)
    }

    /// A forge.json written before these fields existed must still load. A
    /// decoder that throws on a missing key turns an upgrade into a crash.
    @Test("a signing block without the new fields still decodes")
    func olderConfigStillDecodes() throws {
        let json = """
        {"mode":"windows-ilok","paceAccount":"acct","paceWcGuid":"G","paceSignId":"S",
         "allowSigningService":true,
         "windows":{"provider":"none","azureEndpoint":"","azureAccount":"","azureProfile":""},
         "macos":{"teamId":"","devIdAppIdentity":"","devIdInstallerIdentity":"","notarize":true}}
        """
        let signing = try JSONDecoder().decode(SigningConfig.self, from: Data(json.utf8))

        #expect(signing.paceWcGuid == "G")
        #expect(signing.paceCustomerNumber == "")
        #expect(signing.paceCustomerName == "")
        #expect(signing.paceSelfSigned == false)
        #expect(signing.hasPublisherIdentity)
    }
}
