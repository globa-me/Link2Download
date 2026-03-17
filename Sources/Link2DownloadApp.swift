import SwiftUI

@main
struct Link2DownloadApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var managerHolder: DownloadManagerHolder

    init() {
        let settingsStore = SettingsStore()
        _settings = StateObject(wrappedValue: settingsStore)
        _managerHolder = StateObject(wrappedValue: DownloadManagerHolder(settings: settingsStore))
    }

    var body: some Scene {
        WindowGroup {
            MainView(settings: settings, manager: managerHolder.manager)
                .preferredColorScheme(nil)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

@MainActor
final class DownloadManagerHolder: ObservableObject {
    let manager: DownloadManager

    init(settings: SettingsStore) {
        self.manager = DownloadManager(settings: settings)
    }
}
