import AppKit
import Foundation
import Observation
import SwiftUI

/// Drives the Logs page.
///
/// Everything shown here has already been through LogBus redaction: secrets are
/// replaced by value AND by shape, so a credential cannot reach this page even
/// if some service forgets to be careful.
@MainActor
@Observable
public final class LogsModel {
    private let store: ForgeStore

    public var entries: [LogEntry] = []
    public var minimumLevel: LogLevel = .info
    public var sourceFilter = ""
    public var searchText = ""
    public var isFollowing = true
    public var statusMessage: String?

    private var pollTask: Task<Void, Never>?

    public init(store: ForgeStore) { self.store = store }

    public var sources: [String] {
        Array(Set(entries.map(\.source))).sorted()
    }

    public var filtered: [LogEntry] {
        entries.filter { entry in
            guard entry.level >= minimumLevel else { return false }
            if !sourceFilter.isEmpty, entry.source != sourceFilter { return false }
            if !searchText.isEmpty,
               !entry.message.localizedCaseInsensitiveContains(searchText) { return false }
            return true
        }
    }

    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh() async {
        guard isFollowing else { return }
        entries = await store.services.logBus.snapshot()
    }

    public func clear() async {
        await store.services.logBus.clear()
        entries = []
    }

    /// Saves the log to a file the user can attach to a bug report. The text is
    /// the redacted text, not a second rendering from raw entries.
    public func save(to path: String) async {
        do {
            let text = await store.services.logBus.plainText()
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            statusMessage = "Saved \(text.utf8.count) bytes to \(path)."
        } catch {
            statusMessage = "Could not save: \(error)"
        }
    }

    public func defaultSavePath() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return desktop.appendingPathComponent("runnerforge-\(stamp).log").path
    }
}


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
