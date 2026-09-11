import AppKit
import Foundation
import Observation
import SwiftUI

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


public struct ExportView: View {
    @State private var model: ExportModel
    @State private var overwrite = false
    @State private var selection: RenderedFile.ID?

    public init(store: ForgeStore) {
        _model = State(initialValue: ExportModel(store: store))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader("Export",
                       "Turn this configuration into the workflow files your plugin repository needs.")

            ExplanationBox(
                symbol: "square.stack.3d.up",
                text: "These templates describe how to DRIVE a build — checkout, configure, build, "
                    + "package, upload — and never what to build. Everything project-specific is a "
                    + "substitution value, which is why the same templates serve any CMake project.")

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Project name") {
                        TextField("MyPlugin", text: $model.projectName).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Source directory") {
                        TextField(".", text: $model.sourceDir).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        TextField("repository folder", text: $model.destinationDirectory)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseDestination() }
                    }
                    HStack {
                        Button("Render") { Task { await model.render() } }
                        Toggle("Overwrite existing files", isOn: $overwrite)
                        Button("Write to repository") { Task { await model.write(overwrite: overwrite) } }
                            .disabled(model.rendered.isEmpty)
                        Spacer()
                    }
                }
                .padding(6)
            }

            if let error = model.errorMessage {
                ExplanationBox(symbol: "xmark.octagon", text: error)
            }
            if let message = model.statusMessage {
                ExplanationBox(symbol: "checkmark.circle", text: message)
            }

            HSplitView {
                List(model.rendered, selection: $selection) { file in
                    VStack(alignment: .leading) {
                        Text(file.fileName).font(.body.monospaced())
                        Text(file.relativeDirectory).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(file.id)
                }
                .frame(minWidth: 220)

                ScrollView([.horizontal, .vertical]) {
                    Text(previewText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minWidth: 360)
            }
            .frame(minHeight: 240)
        }
        .padding(20)
    }

    private var previewText: String {
        guard let id = selection,
              let file = model.rendered.first(where: { $0.id == id }) else {
            return model.rendered.isEmpty
                ? "Nothing rendered yet."
                : "Select a file to preview it."
        }
        return file.contents
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.destinationDirectory = url.path
        }
    }
}
