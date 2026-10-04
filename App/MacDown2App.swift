import AppKit
import SwiftUI

@main
struct MacDown2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() { AppExtensions.start() }

    var body: some Scene {
        // Every window is a workspace window (PLAN Q15): it owns its documents, tabs and sidebar. Cmd-N opens another one.
        WindowGroup(id: WorkspaceScene.id) {
            WorkspaceView()
        }
        .defaultSize(width: 1100, height: 700)  // wide enough for the whole toolbar
        // Windows come back from WorkspaceRegistry's own record (tabs, sidebar, split), the same on every system setting;
        // SwiftUI must neither restore windows itself nor skip the first one when it thinks it restored "no windows".
        .handlesExternalEvents(matching: [])  // open-file events are the app delegate's (WorkspaceRegistry.open), not a new window each
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .commands {
            UpdateCommands()
            FileCommands()
            TabCommands()
            AppearanceCommands()
            FormatCommands()
            ExportCommands()
        }
        Settings { SettingsView() }
    }
}

/// What SwiftUI's scenes cannot do: the open-file events, restoring windows by our own record, the quit review.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false  // tabs are ours; the system's "Show Tab Bar" must not appear
        MainActor.assumeIsolated { WorkspaceRegistry.shared.prepareLaunch() }
    }

    /// There is no untitled document.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { WorkspaceRegistry.shared.open(urls) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let registry = WorkspaceRegistry.shared
            guard registry.needsTerminationReview else {
                registry.beginTermination()
                return .terminateNow
            }
            registry.reviewForTermination { proceed in sender.reply(toApplicationShouldTerminate: proceed) }
            return .terminateLater
        }
    }
}
