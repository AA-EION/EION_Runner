import AppKit
import SwiftUI

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
