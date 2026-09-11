import Foundation
import Observation

/// One rendered file waiting to be written.
public struct RenderedFile: Sendable, Identifiable, Hashable {
    public let fileName: String
    public let relativeDirectory: String
    public let contents: String

    public var id: String { (relativeDirectory as NSString).appendingPathComponent(fileName) }

    public init(fileName: String, relativeDirectory: String, contents: String) {
        self.fileName = fileName
        self.relativeDirectory = relativeDirectory
        self.contents = contents
    }
}

/// Drives the Export page: turn the configuration into the workflow files the
/// user's plugin repository needs.
///
/// The templates describe how to DRIVE a build; they never describe a plugin.
/// Everything project-specific arrives as a substitution value, which is why the
/// same templates serve any CMake project rather than only the canary.
@MainActor
@Observable
public final class ExportModel {
    private let store: ForgeStore

    public var projectName = "MyPlugin"
    public var sourceDir = "."
    public var destinationDirectory = ""
    public var rendered: [RenderedFile] = []
    public var statusMessage: String?
    public var errorMessage: String?

    public init(store: ForgeStore) { self.store = store }

    /// Where the templates ship inside the app bundle.
    public var templatesDirectory: String {
        Bundle.main.resourceURL?.appendingPathComponent("templates").path
            ?? "/usr/local/share/runnerforge/templates"
    }

    public func render() async {
        errorMessage = nil
        statusMessage = nil
        rendered = []

        let values = TemplateRenderer.buildValues(
            config: store.config,
            projectName: projectName,
            sourceDir: sourceDir,
            secretPresence: store.secretPresence)

        let jobs: [(template: String, output: String, directory: String)] = [
            ("workflow-build.yml.tmpl", "build.yml", ".github/workflows"),
            ("workflow-sign.yml.tmpl", "sign.yml", ".github/workflows"),
            ("workflow-selftest.yml.tmpl", "selftest-selfhosted.yml", ".github/workflows"),
            ("secrets-checklist.md.tmpl", "RUNNER-FORGE-SECRETS.md", "docs"),
        ]

        for job in jobs {
            let path = (templatesDirectory as NSString).appendingPathComponent(job.template)
            do {
                let template = try String(contentsOfFile: path, encoding: .utf8)
                let output = try store.services.templateRenderer.render(template, values: values)
                rendered.append(RenderedFile(
                    fileName: job.output, relativeDirectory: job.directory, contents: output))
            } catch let error as TemplateRenderer.UnsubstitutedPlaceholderError {
                // Never write a workflow with a {{placeholder}} still in it. It
                // would be accepted by git and rejected by Actions, far later and
                // far less clearly.
                errorMessage = error.description
                rendered = []
                await store.services.logBus.error("export", error.description)
                return
            } catch {
                errorMessage = "\(job.template): \(error)"
                rendered = []
                await store.services.logBus.error("export", "\(job.template): \(error)")
                return
            }
        }

        statusMessage = "Rendered \(rendered.count) file(s). Nothing has been written yet."
    }

    /// Writes the rendered files, refusing to clobber anything silently.
    public func write(overwrite: Bool) async {
        let root = destinationDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            errorMessage = "Choose the repository folder to write into."
            return
        }
        guard !rendered.isEmpty else {
            errorMessage = "Render first."
            return
        }

        var written: [String] = []
        var skipped: [String] = []

        for file in rendered {
            let directory = (root as NSString).appendingPathComponent(file.relativeDirectory)
            let target = (directory as NSString).appendingPathComponent(file.fileName)

            if FileManager.default.fileExists(atPath: target), !overwrite {
                skipped.append(target)
                continue
            }

            do {
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true)
                try file.contents.write(toFile: target, atomically: true, encoding: .utf8)
                written.append(target)
            } catch {
                errorMessage = "\(target): \(error)"
                await store.services.logBus.error("export", "\(target): \(error)")
                return
            }
        }

        errorMessage = nil
        statusMessage = skipped.isEmpty
            ? "Wrote \(written.count) file(s)."
            : "Wrote \(written.count) file(s). Skipped \(skipped.count) that already exist — "
                + "tick Overwrite to replace them."

        for path in written { await store.services.logBus.info("export", "wrote \(path)") }
    }
}
