import AppKit
import SwiftUI

public struct LogsView: View {
    @State private var model: LogsModel

    public init(store: ForgeStore) {
        _model = State(initialValue: LogsModel(store: store))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader("Logs",
                       "Everything Runner Forge ran, with secrets redacted before they ever reach this page.")

            HStack {
                Picker("Level", selection: $model.minimumLevel) {
                    ForEach(LogLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .frame(width: 170)

                Picker("Source", selection: $model.sourceFilter) {
                    Text("all").tag("")
                    ForEach(model.sources, id: \.self) { source in
                        Text(source).tag(source)
                    }
                }
                .frame(width: 200)

                TextField("search", text: $model.searchText).textFieldStyle(.roundedBorder)

                Toggle("Follow", isOn: $model.isFollowing)

                Button("Copy") { copyAll() }
                Button("Save…") { save() }
                Button("Clear", role: .destructive) { Task { await model.clear() } }
            }

            if let message = model.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.filtered) { entry in
                            Text(entry.formatted)
                                .font(.caption.monospaced())
                                .foregroundStyle(tint(for: entry.level))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: model.filtered.count) { _, _ in
                    guard model.isFollowing, let last = model.filtered.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .padding(20)
        .task { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private func tint(for level: LogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }

    private func copyAll() {
        let text = model.filtered.map(\.formatted).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.statusMessage = "Copied \(model.filtered.count) line(s)."
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (model.defaultSavePath() as NSString).lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.save(to: url.path) }
        }
    }
}
