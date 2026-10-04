import SwiftUI

/// App menu > Check for Updates…
struct UpdateCommands: Commands {
    private let updater = UpdaterController.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
