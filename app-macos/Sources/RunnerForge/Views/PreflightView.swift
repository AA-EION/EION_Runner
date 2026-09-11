import SwiftUI

public struct PreflightView: View {
    @State private var model: PreflightModel

    public init(store: ForgeStore) {
        _model = State(initialValue: PreflightModel(store: store))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader("Preflight",
                           "What this Mac can actually host, checked against the machine rather than assumed.")

                HStack {
                    Button(model.isRunning ? "Checking…" : "Run checks") {
                        Task { await model.run() }
                    }
                    .disabled(model.isRunning)
                    .keyboardShortcut("r")

                    if let at = model.lastRunAt {
                        Text("Last run \(at.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !model.checks.isEmpty {
                        Text("\(model.checks.count - model.failures.count - model.warnings.count) pass · "
                             + "\(model.warnings.count) warn · \(model.failures.count) fail")
                            .font(.caption.monospaced())
                    }
                }

                if !model.hardBlocks.isEmpty {
                    ExplanationBox(
                        symbol: "exclamationmark.octagon",
                        text: "Some checks cannot be fixed on this machine: "
                            + model.hardBlocks.map(\.name).joined(separator: ", ")
                            + ". Runner Forge does not offer a Fix for these, because no setting would "
                            + "make them true.")
                }

                if let message = model.fixMessage {
                    ExplanationBox(symbol: "wrench.and.screwdriver", text: message)
                }

                ForEach(model.checks) { check in
                    CheckRow(check: check) {
                        Task { await model.fix(check) }
                    }
                }

                if model.checks.isEmpty && !model.isRunning {
                    ExplanationBox(text: "No checks have run yet. Press Run checks.")
                }
            }
            .padding(20)
        }
        .task { await model.run() }
    }
}

private struct CheckRow: View {
    let check: PreflightCheck
    let onFix: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusBadge(check.status).frame(width: 74, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(check.name).font(.headline)
                Text(check.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let hint = check.fixHint, check.status != .pass {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !check.blocksClasses.isEmpty, check.status != .pass {
                    Text("Blocks: " + check.blocksClasses.joined(separator: ", "))
                        .font(.caption.monospaced()).foregroundStyle(.orange)
                }
            }

            Spacer()

            // A Fix button appears only where there is an exact command to run.
            // Offering one for a hard block would be a lie with a spinner.
            if check.autoFixable, check.status != .pass, !check.isHardBlock {
                Button("Fix", action: onFix)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}
