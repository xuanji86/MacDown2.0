import AppKit
import SwiftUI

@main
struct MacDown2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        AppDefaults.installIsolation()
        AppExtensions.start()
    }

    var body: some Scene {
        // Every window is a workspace window (PLAN Q15): it owns its documents, tabs and sidebar. Cmd-N opens another one.
        WindowGroup(id: WorkspaceScene.id) {
            WorkspaceView()
        }
        .defaultAppStorage(AppDefaults.store)
        .defaultSize(width: 1100, height: 700)  // wide enough for the whole toolbar
        .windowToolbarStyle(.expanded)  // title on top, the toolbar as its own row below
        // Windows come back from WorkspaceRegistry's own record (tabs, sidebar, split), the same on every system setting;
        // SwiftUI must neither restore windows itself nor skip the first one when it thinks it restored "no windows".
        .handlesExternalEvents(matching: [])  // open-file events are the app delegate's (WorkspaceRegistry.open), not a new window each
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .commands {
            UpdateCommands()
            CommandLineToolCommands()
            FileCommands()
            TabCommands()
            AppearanceCommands()
            FormatCommands()
            ExportCommands()
        }
        Settings { SettingsView() }
            .defaultAppStorage(AppDefaults.store)
    }
}

/// What SwiftUI's scenes cannot do: the open-file events, restoring windows by our own record, the quit review.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false  // tabs are ours; the system's "Show Tab Bar" must not appear
        MainActor.assumeIsolated {
            IconStyle.start()
            WorkspaceRegistry.shared.prepareLaunch()
        }
    }

    /// There is no untitled document.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// Closing the last tab or window never quits: the app stays in the Dock until Cmd-Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon with no window open: a new window (with a blank untitled tab). With windows left (a minimized one) the system's
    /// default brings them back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !MainActor.assumeIsolated { WorkspaceRegistry.shared.reopen() }
    }

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
            registry.reviewForTermination { proceed in
                if !proceed { AppRelauncher.cancel() }
                sender.reply(toApplicationShouldTerminate: proceed)
            }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppRelauncher.launchNewInstanceIfRequested() }
    }
}
