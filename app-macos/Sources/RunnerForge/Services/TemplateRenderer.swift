import Foundation

/// Substitutes `{{key}}` placeholders in the workflow templates.
///
/// Hand-rolled on purpose: a template engine would be a dependency, a security
/// surface and a source of surprising behaviour for something that is literally
/// string replacement. The one rule that matters is that an UNSUBSTITUTED
/// placeholder is an error, not something to paste into a workflow and discover
/// later.
public struct TemplateRenderer: Sendable {
    /// Raised when a template still contains placeholders after rendering.
    public struct UnsubstitutedPlaceholderError: Error, CustomStringConvertible {
        public let keys: [String]

        public var description: String {
            "The template still contains unsubstituted placeholders: \(keys.joined(separator: ", ")). "
            + "Rendering an incomplete workflow would produce YAML that fails at run time."
        }
    }

    private static let pattern = "\\{\\{([A-Za-z][A-Za-z0-9]*)\\}\\}"

    public init() {}

    public func render(_ template: String, values: [String: String]) throws -> String {
        guard let regex = try? NSRegularExpression(pattern: Self.pattern) else { return template }

        var result = ""
        var lastEnd = template.startIndex

        let matches = regex.matches(in: template, range: NSRange(template.startIndex..., in: template))

        for match in matches {
            guard let fullRange = Range(match.range, in: template),
                  let keyRange = Range(match.range(at: 1), in: template) else { continue }

            result += template[lastEnd..<fullRange.lowerBound]
            let key = String(template[keyRange])
            result += values[key] ?? String(template[fullRange])
            lastEnd = fullRange.upperBound
        }

        result += template[lastEnd...]

        let remaining = placeholders(in: result)
        guard remaining.isEmpty else { throw UnsubstitutedPlaceholderError(keys: remaining) }

        return result
    }

    /// Every placeholder a template uses, so the UI can show what a render needs.
    public func placeholders(in template: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: Self.pattern) else { return [] }

        let matches = regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
        var found: Set<String> = []

        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: template) else { continue }
            found.insert(String(template[keyRange]))
        }

        return found.sorted()
    }

    /// The substitution map for a configuration. The single definition of how
    /// config becomes workflow, shared by the Export page and the self-test.

    /// The wraptool publisher arguments for this configuration, as a ready-made
    /// fragment. `--wcguid` when a Wrap Config is set, otherwise the customer
    /// number and company name, which wraptool requires together.
    public static func paceIdentityArgs(_ config: ForgeConfig, shell: Bool) -> String {
        let guid = config.signing.paceWcGuid.trimmingCharacters(in: .whitespaces)
        if !guid.isEmpty {
            return shell ? "--wcguid '\(guid)'" : "-WcGuid '\(guid)'"
        }

        let number = config.signing.paceCustomerNumber.trimmingCharacters(in: .whitespaces)
        let name = config.signing.paceCustomerName.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty, !name.isEmpty else {
            // Deliberately not a silent empty string: an emitted workflow with no
            // publisher argument fails inside wraptool minutes later, with a
            // message that does not mention the configuration at all.
            return shell
                ? "--wcguid 'SET-A-WRAP-CONFIG-OR-CUSTOMER-NUMBER-ON-THE-SIGNING-PAGE'"
                : "-WcGuid 'SET-A-WRAP-CONFIG-OR-CUSTOMER-NUMBER-ON-THE-SIGNING-PAGE'"
        }

        return shell
            ? "--customernumber '\(number)' \\\n            --customername '\(name)'"
            : "-CustomerNumber '\(number)' `\n            -CustomerName '\(name)'"
    }

    public static func buildValues(
        config: ForgeConfig,
        projectName: String,
        sourceDir: String,
        secretPresence: [String: Bool]
    ) -> [String: String] {
        func labelsJson(_ id: RunnerClassId) -> String {
            let runnerClass = RunnerClass.all.first { $0.id == id }!
            let configured = config.runners.first { $0.classId == runnerClass.classId }
            let labels = (configured?.labels.isEmpty == false) ? configured!.labels : runnerClass.labels
            return "[" + labels.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        }

        func present(_ key: String) -> String { (secretPresence[key] ?? false) ? "yes" : "no" }

        let aaxAvailable = !config.paths.aaxSdkSource.trimmingCharacters(in: .whitespaces).isEmpty

        return [
            "projectName": projectName,
            "sourceDir": sourceDir,
            "githubOwner": config.github.owner,
            "githubRepo": config.github.repos.first ?? "",
            "pushBranches": "main",

            "checkoutAction": "v4",
            "uploadArtifactAction": "v4",
            "downloadArtifactAction": "v4",

            "winBuildLabelsJson": labelsJson(.winBuild),
            "macBuildLabelsJson": labelsJson(.macBuild),
            "linuxUtilLabelsJson": labelsJson(.linuxUtil),
            "winIlokLabelsJson": labelsJson(.winIlok),
            "macIlokLabelsJson": labelsJson(.macIlok),

            "winHostedJson": "\"windows-2022\"",
            "macHostedJson": "\"macos-14\"",
            "linuxHostedJson": "\"ubuntu-24.04\"",

            "windowsTimeoutMinutes": "90",
            "macosTimeoutMinutes": "90",

            "fetchContentBaseDir": "C:\\cache\\fetchcontent",
            "sccacheDir": "C:\\cache\\sccache",
            "macFetchContentBaseDir": "$HOME/cache/fetchcontent",
            "innoSetupScript": "installer\\windows\\\(projectName).iss",
            "macPackagingScript": "installer/macos/build_installer.sh",

            "signingMode": config.signing.mode,
            "signWorkflowFileName": "workflow-sign.yml",
            "paceWcGuid": config.signing.paceWcGuid,
            "paceSignId": config.signing.paceSignId,

            // These four expand to complete argument fragments rather than bare
            // values, because the shape of the call changes with the
            // configuration: a Wrap Config is one flag, a customer number is two,
            // and a self-signed certificate adds one more. Emitting the fragment
            // keeps that decision here instead of spreading conditionals through
            // YAML, where they cannot be unit-tested.
            "paceIdentityArgsSh": paceIdentityArgs(config, shell: true),
            "paceIdentityArgsPs": paceIdentityArgs(config, shell: false),
            "paceSelfSignedSh": config.signing.paceSelfSigned ? " \\\n            --self-signed" : "",
            "paceSelfSignedPs": config.signing.paceSelfSigned ? " `\n            -SelfSigned" : "",

            "windowsSigningEnabled": config.signing.windows.provider == "none" ? "false" : "true",
            "azureEndpoint": config.signing.windows.azureEndpoint,
            "azureAccount": config.signing.windows.azureAccount,
            "azureProfile": config.signing.windows.azureProfile,

            "macosSigningEnabled": config.signing.macos.notarize ? "true" : "false",
            "devIdAppIdentity": config.signing.macos.devIdAppIdentity,
            "devIdInstallerIdentity": config.signing.macos.devIdInstallerIdentity,
            "appleTeamId": config.signing.macos.teamId,

            // With no SDK the AAX artifacts become optional and the skip marker
            // becomes required, so the set is never silently short.
            "aaxRequired": aaxAvailable ? "true" : "false",
            "aaxSkipRequired": aaxAvailable ? "false" : "true",

            "havePaceAccount": present("paceAccount"),
            "havePacePassword": present("pacePassword"),
            "haveAzureClientId": present("azureClientId"),
            "haveAzureClientSecret": present("azureClientSecret"),
            "haveAzureTenantId": present("azureTenantId"),
            "haveAppleP12": present("appleDevIdP12"),
            "haveAppleP12Password": present("appleDevIdP12Password"),
            "haveAscIssuerId": present("appleAscIssuerId"),
            "haveAscKeyId": present("appleAscKeyId"),
            "haveAscPrivateKey": present("appleAscPrivateKey"),

            "workflowName": "\(projectName)-selftest",
            "workflowFileName": "selftest-selfhosted.yml",
            "stageName": "Runner Forge self-test",
            "winBuildLabels": "[" + RunnerClass.winBuild.labels.joined(separator: ", ") + "]",
            "macBuildLabels": "[" + RunnerClass.macBuild.labels.joined(separator: ", ") + "]",
            "linuxUtilLabels": "[" + RunnerClass.linuxUtil.labels.joined(separator: ", ") + "]",
        ]
    }
}
