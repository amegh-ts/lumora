import AppKit
import UniformTypeIdentifiers

/// Making Lumora the app that opens video files: a one-time offer on first launch (#37) and a
/// button in Settings › General. macOS asks the user to confirm each change.
@MainActor
enum DefaultPlayer {
    private static let offeredKey = "lumora.defaultPlayer.offered"

    /// Common video types; the first is used to check whether Lumora is already the default.
    static var videoTypes: [UTType] {
        var types: [UTType] = [.mpeg4Movie, .quickTimeMovie, .movie, .avi, .mpeg, .mpeg2Video, .mpeg2TransportStream]
        for ext in ["mkv", "webm", "flv", "wmv", "m2ts", "ts"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    static var isDefault: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: .mpeg4Movie) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// First launch only, and only from an installed app (not a debug build or the DMG).
    static func offerIfFirstLaunch(in window: NSWindow?) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: offeredKey), !DebugMode.background, Bundle.main.bundleURL.pathExtension == "app",
            !Bundle.main.bundlePath.hasPrefix("/Volumes/"), !isDefault, let window
        else { return }
        defaults.set(true, forKey: offeredKey)
        let alert = NSAlert()
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.messageText = "Make Lumora your video player?"
        alert.informativeText =
            "Double-clicking a video (MP4, MKV, MOV, AVI, WebM and more) will open it in Lumora. You can change this any time in Settings › General."
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Use Lumora")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { makeDefault() }
        }
    }

    /// Asks macOS to open the video types with Lumora (macOS shows its own confirmation).
    static func makeDefault(completion: (@MainActor (Bool) -> Void)? = nil) {
        let app = Bundle.main.bundleURL
        let types = videoTypes
        Task { @MainActor in
            var allOK = true
            for type in types {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
                } catch {
                    allOK = false
                }
            }
            completion?(allOK)
        }
    }
}
