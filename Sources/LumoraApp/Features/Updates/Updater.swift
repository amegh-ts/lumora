import AppKit
import Combine
import Sparkle

@MainActor
final class Updater {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?
    private var cancellable: AnyCancellable?

    private init() {}

    func start(settings: SettingsStore) {
        guard controller == nil, Self.isConfigured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.automaticallyChecksForUpdates = settings.checkForUpdates
        cancellable = settings.$checkForUpdates
            .removeDuplicates()
            .sink { enabled in
                controller.updater.automaticallyChecksForUpdates = enabled
            }
    }

    func checkForUpdates() {
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "Updates aren't available in this build"
            alert.informativeText = "Development builds run without the update feed. Install Lumora from a release DMG to get automatic updates."
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }

    private static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["SUFeedURL"] != nil && info["SUPublicEDKey"] != nil
    }
}
