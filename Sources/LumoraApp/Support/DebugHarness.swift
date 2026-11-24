#if DEBUG
import AppKit

@MainActor
enum DebugHarness {
    static func run(open: (([URL]) -> Void)) {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["LUMORA_OPEN"] {
            open([URL(fileURLWithPath: path)])
            if environment["LUMORA_MUTE"] != nil,
               let player = NSApp.windows.compactMap({ $0.contentViewController as? PlayerViewController }).first {
                player.engine.toggleMute()
            }
        }
        guard let directory = environment["LUMORA_SNAPSHOT_DIR"] else { return }
        let steps = (environment["LUMORA_SNAPSHOT_STEPS"] ?? "2").split(separator: ",").compactMap { Double($0) }
        for (index, delay) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                snapshot(to: URL(fileURLWithPath: directory).appendingPathComponent("step-\(index).png"))
            }
        }
        if let quit = steps.max() {
            DispatchQueue.main.asyncAfter(deadline: .now() + quit + 1) {
                NSApp.terminate(nil)
            }
        }
    }

    private static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.windowController is MainWindowController }),
              let view = window.contentView?.superview else { return }
        if let player = window.contentViewController as? PlayerViewController {
            let engine = player.engine
            print("[debug] t=\(engine.currentTime) d=\(engine.duration) playing=\(engine.isPlaying) media=\(engine.hasMedia) size=\(engine.videoSize) audio=\(engine.audioTracks.map(\.displayName)) subs=\(engine.subtitleTracks.map(\.displayName)) chapters=\(engine.chapters.count) status=\(engine.statusMessage)")
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
