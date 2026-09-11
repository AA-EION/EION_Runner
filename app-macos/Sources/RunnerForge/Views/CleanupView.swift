import SwiftUI

public struct CleanupView: View {
    @State private var model: CleanupModel

    public init(store: ForgeStore) {
        _model = State(initialValue: CleanupModel(store: store))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader("Cleanup",
                           "Two explicit lists. What is kept, and what is deleted — never a blanket prune.")

                ExplanationBox(symbol: "exclamationmark.shield", text: CleanupModel.pruneNote)

                HStack {
                    Button(model.isSurveying ? "Surveying…" : "Survey") {
                        Task { await model.survey() }
                    }
                    .disabled(model.isSurveying || model.isPurging)

                    Button(model.isPurging ? "Purging…" : "Purge now") {
                        Task { await model.purge() }
                    }
                    .disabled(model.isSurveying || model.isPurging)

                    Spacer()

                    if let reclaimed = model.lastReclaimed {
                        Text("Reclaimed \(DiskUsageItem.format(bytes: reclaimed))")
                            .font(.caption.monospaced()).foregroundStyle(.green)
                    }
                }

                if let error = model.errorMessage {
                    ExplanationBox(symbol: "xmark.octagon", text: error)
                }

                HStack(alignment: .top, spacing: 16) {
                    UsageColumn(
                        title: "KEEP",
                        subtitle: "Never deleted. Deleting these is what makes the next run slow.",
                        total: model.usage.humanKeepBytes,
                        tint: .green,
                        items: model.usage.keep)

                    UsageColumn(
                        title: "PURGE",
                        subtitle: "Deleted on demand, and on close when that is enabled.",
                        total: model.usage.humanReclaimableBytes,
                        tint: .orange,
                        items: model.usage.purge)
                }

                GroupBox("Policy") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Purge when Runner Forge closes", isOn: $model.purgeOnExit)
                        Stepper(value: $model.maxDiskGb, in: 10...2000, step: 10) {
                            Text("Disk budget: \(model.maxDiskGb) GB").font(.body.monospaced())
                        }
                        Stepper(value: $model.logRetentionDays, in: 1...365) {
                            Text("Keep logs for \(model.logRetentionDays) day(s)")
                                .font(.body.monospaced())
                        }
                    }
                    .padding(6)
                }
            }
            .padding(20)
        }
        .task { await model.survey() }
    }
}

private struct UsageColumn: View {
    let title: String
    let subtitle: String
    let total: String
    let tint: Color
    let items: [DiskUsageItem]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StatusBadge(text: title, tint: tint)
                    Spacer()
                    Text(total).font(.body.monospaced().bold())
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                if items.isEmpty {
                    Text("Nothing found.").font(.callout).foregroundStyle(.secondary)
                }

                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.description).font(.callout)
                            Spacer()
                            Text(item.humanBytes).font(.caption.monospaced())
                        }
                        if let reason = item.reason {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
