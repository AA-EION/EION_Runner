import Foundation
import Observation
import SwiftUI

/// Drives the Preflight page.
@MainActor
@Observable
public final class PreflightModel {
    private let store: ForgeStore

    public var checks: [PreflightCheck] = []
    public var isRunning = false
    public var lastRunAt: Date?
    public var fixMessage: String?

    public init(store: ForgeStore) { self.store = store }

    public var failures: [PreflightCheck] { checks.filter { $0.status == .fail } }
    public var warnings: [PreflightCheck] { checks.filter { $0.status == .warn } }

    /// A hard block cannot be fixed by anything the app can do — an Intel Mac is
    /// the archetype. The UI says so instead of offering a Fix that would fail.
    public var hardBlocks: [PreflightCheck] { checks.filter(\.isHardBlock) }

    public var canStartRunners: Bool { !checks.isEmpty && failures.isEmpty }

    /// Class ids that at least one failing check blocks.
    public var blockedClassIds: Set<String> {
        Set(failures.flatMap(\.blocksClasses))
    }

    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        checks = await store.services.preflightService.runAll(config: store.config)
        lastRunAt = Date()

        let failed = failures.count
        if failed == 0 {
            await store.services.logBus.info("preflight", "all \(checks.count) checks pass")
        } else {
            await store.services.logBus.warning(
                "preflight", "\(failed) of \(checks.count) checks failed")
        }
    }

    /// The only auto-fixes offered are ones with an exact, non-destructive
    /// command. Anything else states the manual step rather than guessing.
    public func fix(_ check: PreflightCheck) async {
        guard check.autoFixable else { return }
        fixMessage = nil

        switch check.name {
        case "Rosetta 2":
            let result = try? await store.services.processRunner.run(
                "/usr/sbin/softwareupdate",
                arguments: ["--install-rosetta", "--agree-to-license"],
                logSource: "preflight")
            fixMessage = (result?.succeeded == true)
                ? "Rosetta 2 installed."
                : "Rosetta 2 install failed; see the Logs page."

        case "Free disk space":
            _ = try? await store.services.sweeperService.purge(config: store.config)
            fixMessage = "Sweeper run. Re-checking free space."

        case "System sleep":
            // caffeinate is held for the app's lifetime by RunnerForgeApp; this
            // only reports that the assertion exists, it does not change pmset.
            fixMessage = "Runner Forge already holds a caffeinate assertion while it is open."

        default:
            fixMessage = check.fixHint
        }

        await run()
    }
}


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
