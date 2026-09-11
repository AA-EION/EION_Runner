import SwiftUI

/// The window: a sidebar of the eight pages, and a status strip that is visible
/// from every one of them.
public struct RootView: View {
    @Bindable private var store: ForgeStore
    @State private var page: ForgePage = .preflight

    public init(store: ForgeStore) {
        _store = Bindable(wrappedValue: store)
    }

    public var body: some View {
        NavigationSplitView {
            List(ForgePage.allCases, selection: $page) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            VStack(spacing: 0) {
                detail
                Divider()
                statusStrip
            }
        }
        .frame(minWidth: 940, minHeight: 640)
        .task { await store.bootstrap() }
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .preflight: PreflightView(store: store)
        case .targets: TargetsView(store: store)
        case .credentials: CredentialsView(store: store)
        case .signing: SigningView(store: store)
        case .runners: RunnersView(store: store)
        case .cleanup: CleanupView(store: store)
        case .export: ExportView(store: store)
        case .logs: LogsView(store: store)
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 12) {
            Text(store.configPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)

            if store.isDirty {
                StatusBadge(text: "unsaved", tint: .orange)
            } else if let at = store.lastSavedAt {
                Text("saved \(at.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if !store.loadProblems.isEmpty {
                // The app stays usable with an invalid config on disk: refusing
                // to launch over a bad field would leave no way to fix the field.
                Text(store.loadProblems.first ?? "")
                    .font(.caption).foregroundStyle(.red).lineLimit(1)
                    .help(store.loadProblems.joined(separator: "\n"))
            }

            Button("Reload") { Task { await store.load() } }
            Button("Save") { Task { await store.save() } }
                .keyboardShortcut("s")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
