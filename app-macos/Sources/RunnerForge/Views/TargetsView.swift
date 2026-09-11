import SwiftUI

public struct TargetsView: View {
    @Bindable private var store: ForgeStore
    @State private var model: TargetsModel

    public init(store: ForgeStore) {
        _store = Bindable(wrappedValue: store)
        _model = State(initialValue: TargetsModel(store: store))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader("Targets",
                           "Which repositories this Mac serves, and which runner classes it hosts.")

                GroupBox("GitHub") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Owner") {
                            TextField("owner", text: $store.config.github.owner)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: store.config.github.owner) { _, _ in store.markDirty() }
                        }

                        HStack {
                            TextField("repository name", text: $model.newRepo)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.addRepo() }
                            Button("Add", action: model.addRepo)
                        }

                        ForEach(model.repos, id: \.self) { repo in
                            HStack {
                                Text("\(store.config.github.owner)/\(repo)").font(.body.monospaced())
                                if let outcome = model.accessResults[repo] {
                                    Text(outcome)
                                        .font(.caption)
                                        .foregroundStyle(outcome.hasPrefix("FAIL") ? .red : .green)
                                }
                                Spacer()
                                Button(role: .destructive) { model.removeRepo(repo) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        HStack {
                            Button(model.isVerifying ? "Verifying…" : "Verify App access") {
                                Task { await model.verifyAccess() }
                            }
                            .disabled(model.isVerifying || model.repos.isEmpty)

                            if let message = model.statusMessage {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(6)
                }

                ExplanationBox(
                    text: "Only the macOS classes appear here. The Windows classes are hosted by the "
                        + "Windows app on the PC that has the hardware; showing them on this machine "
                        + "would offer a switch that could not do anything.")

                ForEach(model.classes()) { runnerClass in
                    ClassRow(model: model, runnerClass: runnerClass,
                             entry: store.runnerConfig(for: runnerClass))
                }
            }
            .padding(20)
        }
    }
}

private struct ClassRow: View {
    // The model is held rather than two closures because SwiftUI's Binding
    // setter is `@isolated(any) @Sendable`, and a stored plain function value
    // converted to it is a data-race warning under Swift 6. A closure written
    // inline in `body` is already main-actor-isolated, so it converts cleanly.
    let model: TargetsModel
    let runnerClass: RunnerClass
    let entry: RunnerConfig

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle(runnerClass.displayName, isOn: Binding(
                        get: { entry.enabled },
                        set: { model.setEnabled(runnerClass, $0) }))
                    .toggleStyle(.switch)

                    Spacer()

                    StatusBadge(text: runnerClass.isolation.rawValue, tint: .blue)
                }

                Text("Labels: " + runnerClass.labels.joined(separator: ", "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)

                HStack {
                    Text("Replicas")
                    Stepper(value: Binding(get: { entry.replicas },
                                           set: { model.setReplicas(runnerClass, $0) }),
                            in: runnerClass.minReplicas...runnerClass.maxReplicas) {
                        Text("\(entry.replicas)").font(.body.monospaced())
                    }
                    .disabled(runnerClass.replicasAreFixed)

                    if runnerClass.replicasAreFixed {
                        Text("fixed at 1 — there is one dongle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let reason = runnerClass.notContainerizedReason {
                    ExplanationBox(symbol: "shield.lefthalf.filled", text: reason)
                }
            }
            .padding(6)
        }
    }
}
