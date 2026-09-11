import SwiftUI

public struct RunnersView: View {
    private let store: ForgeStore
    @State private var model: RunnersModel

    public init(store: ForgeStore) {
        self.store = store
        _model = State(initialValue: RunnersModel(store: store))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader("Runners",
                           "Every runner takes one job and is destroyed. Nothing here is long-lived.")

                if model.blockedByStraySurvivors {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Strays survived the last reap", systemImage: "exclamationmark.octagon.fill")
                                .font(.headline).foregroundStyle(.red)
                            Text("New runners are blocked. Something from a previous job is still running "
                                 + "and would share this machine with the next job. Deal with it, then "
                                 + "acknowledge.")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                            ForEach(model.straySurvivorDetails, id: \.self) { detail in
                                Text(detail).font(.caption.monospaced())
                            }
                            Button("I have dealt with these — unblock") {
                                Task { await model.acknowledgeStraySurvivors() }
                            }
                        }
                        .padding(6)
                    }
                }

                HStack {
                    Button("Start enabled") { Task { await model.startAllEnabled() } }
                        .disabled(model.isBusy || model.blockedByStraySurvivors)
                    Button("Stop all") { Task { await model.stopAll() } }
                        .disabled(model.isBusy)
                    Button("Drain and reap") { Task { await model.drainAndReap() } }
                        .disabled(model.isBusy)
                    Spacer()
                    if let message = model.statusMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }

                ForEach(model.classes) { runnerClass in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(runnerClass.displayName).font(.headline)
                                StatusBadge(
                                    text: model.isRunning(runnerClass) ? "running" : "stopped",
                                    tint: model.isRunning(runnerClass) ? .green : .secondary)
                                Spacer()
                                Button("Start") { Task { await model.start(runnerClass) } }
                                    .disabled(model.isBusy || model.blockedByStraySurvivors
                                              || !store.runnerConfig(for: runnerClass).enabled)
                                Button("Stop") { Task { await model.stop(runnerClass) } }
                                    .disabled(model.isBusy || !model.isRunning(runnerClass))
                            }

                            if !store.runnerConfig(for: runnerClass).enabled {
                                Text("Disabled on the Targets page.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }

                            ForEach(model.replicas(for: runnerClass)) { replica in
                                HStack(spacing: 10) {
                                    Text("#\(replica.index)").font(.caption.monospaced())
                                        .frame(width: 30, alignment: .leading)
                                    StatusBadge(text: replica.state.label,
                                                tint: tint(for: replica.state))
                                    Text(replica.runnerName).font(.caption.monospaced())
                                    Spacer()
                                    Text("\(replica.jobsCompletedToday) job(s) today").font(.caption)
                                    if let error = replica.lastError {
                                        Text(error).font(.caption).foregroundStyle(.red)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .padding(6)
                    }
                }

                GroupBox("Self-test") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(model.selfTestRunning ? "Running…" : "Run self-test") {
                                Task { await model.runSelfTest() }
                            }
                            .disabled(model.selfTestRunning)
                            if let progress = model.selfTestProgress {
                                Text(progress).font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        Text("Dispatches the canary workflow at these runners, waits for it, downloads "
                             + "every artifact and asserts the contract. A green run that landed on a "
                             + "hosted runner is not a pass.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let proof = model.lastProof, proof.runId != 0 {
                            ProofView(proof: proof)
                        } else {
                            Text("No self-test has run on this machine yet.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }
            }
            .padding(20)
        }
        .task { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private func tint(for state: ReplicaState) -> Color {
        switch state {
        case .stopped: .secondary
        case .starting: .blue
        case .waitingForJob: .teal
        case .runningJob: .green
        case .cleaningUp: .orange
        case .error: .red
        }
    }
}

private struct ProofView: View {
    let proof: SelfTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StatusBadge(text: proof.verdict, tint: proof.passed ? .green : .red)
                Text("run \(proof.runId) · \(proof.conclusion) · \(proof.durationSeconds)s")
                    .font(.caption.monospaced())
            }

            HStack {
                Image(systemName: proof.allJobsOnForgeRunners
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(proof.allJobsOnForgeRunners ? .green : .orange)
                Text(proof.allJobsOnForgeRunners
                     ? "Every job ran on a Runner Forge runner."
                     : "At least one job did NOT run on a Runner Forge runner: "
                        + proof.runnerNames.joined(separator: ", "))
                    .font(.caption)
            }

            Text("Reaper exit \(proof.reaperExitCode) · sweeper reclaimed "
                 + DiskUsageItem.format(bytes: Int64(proof.sweeperReclaimedBytes)))
                .font(.caption.monospaced()).foregroundStyle(.secondary)

            ForEach(proof.artifacts) { artifact in
                HStack {
                    StatusBadge(text: artifact.verdict, tint: artifact.verdict == "pass" ? .green : .red)
                    Text(artifact.name).font(.caption.monospaced())
                    Spacer()
                    Text("\(artifact.fileCount) file(s) · "
                         + DiskUsageItem.format(bytes: Int64(artifact.bytes)))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }
}
