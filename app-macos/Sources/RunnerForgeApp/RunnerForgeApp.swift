import AppKit
import Foundation
import RunnerForge
import SwiftUI

@main
struct ForgeMainApp: App {
    @State private var store = ForgeStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .onAppear { delegate.attach(store: store) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Runners") {
                Button("Start enabled runners") { delegate.startEnabled() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Stop all runners") { delegate.stopAll() }
                    .keyboardShortcut(".", modifiers: [.command])
                Divider()
                Button("Drain and reap") { delegate.drainAndReap() }
                Button("Purge now") { delegate.purge() }
            }
        }

        // The menu bar item is how the app is driven while the window is closed:
        // these runners are meant to sit there for days.
        MenuBarExtra("Runner Forge", systemImage: "hammer.circle") {
            Text(delegate.menuSummary)

            Divider()

            Button("Start enabled runners") { delegate.startEnabled() }
            Button("Stop all runners") { delegate.stopAll() }
            Button("Drain and reap") { delegate.drainAndReap() }
            Button("Purge now") { delegate.purge() }

            Divider()

            Button("Quit Runner Forge") { NSApplication.shared.terminate(nil) }
        }
    }
}

/// Owns the two things that are not view state: the sleep assertion that keeps
/// this Mac awake while it is hosting runners, and the orderly shutdown.
@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ForgeStore?
    private var runners: RunnersModel?
    private var caffeinate: Process?

    /// Shown at the top of the menu bar menu.
    var menuSummary: String = "Not started"

    private var isShuttingDown = false

    func attach(store: ForgeStore) {
        guard self.store == nil else { return }
        self.store = store
        self.runners = RunnersModel(store: store)
        self.runners?.startPolling()
        startCaffeinate()
        Task { await refreshSummary() }
    }

    // -----------------------------------------------------------------------
    // Sleep
    // -----------------------------------------------------------------------

    /// A sleeping Mac drops its runner's websocket, and GitHub re-queues the job
    /// after a long timeout rather than immediately. `caffeinate -dimsu` held for
    /// the app's lifetime is the supported way to prevent that; changing the
    /// user's pmset settings behind their back is not.
    private func startCaffeinate() {
        guard caffeinate == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-dimsu"]
        do {
            try process.run()
            caffeinate = process
        } catch {
            caffeinate = nil
        }
    }

    private func releaseCaffeinate() {
        guard let process = caffeinate else { return }
        if process.isRunning { process.terminate() }
        caffeinate = nil
    }

    // -----------------------------------------------------------------------
    // Menu actions
    // -----------------------------------------------------------------------

    func startEnabled() {
        Task { await runners?.startAllEnabled(); await refreshSummary() }
    }

    func stopAll() {
        Task { await runners?.stopAll(); await refreshSummary() }
    }

    func drainAndReap() {
        Task { await runners?.drainAndReap(); await refreshSummary() }
    }

    func purge() {
        Task {
            guard let store else { return }
            _ = try? await store.services.sweeperService.purge(config: store.config)
            await refreshSummary()
        }
    }

    private func refreshSummary() async {
        guard let runners else { return }
        await runners.refresh()
        let active = runners.replicas.filter { $0.state != .stopped }.count
        menuSummary = active == 0 ? "No runners active" : "\(active) runner(s) active"
    }

    // -----------------------------------------------------------------------
    // Shutdown
    // -----------------------------------------------------------------------

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateNow }
        isShuttingDown = true

        // Quitting mid-job would leave a runner registered with GitHub and a VM
        // clone on disk, so the app asks for time and gives it back when the
        // drain, the reap and the sweep have actually finished.
        Task { @MainActor in
            await runners?.drainAndReap(timeout: 180)
            runners?.stopPolling()

            if let store, store.config.retention.purgeOnExit {
                _ = try? await store.services.sweeperService.purge(config: store.config)
            }

            releaseCaffeinate()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
