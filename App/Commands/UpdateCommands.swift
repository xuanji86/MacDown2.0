import SwiftUI

/// App menu > Check for Updates…
struct UpdateCommands: Commands {
    private let updater = UpdaterController.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
