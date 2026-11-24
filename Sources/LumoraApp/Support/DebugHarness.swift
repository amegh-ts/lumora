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
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            }
        }
    }

    private static func snapshot(to url: URL) {
        let players = NSApp.windows.filter { $0.windowController is MainWindowController }
        FileHandle.standardError.write("[debug] player windows=\(players.count) visible=\(players.filter(\.isVisible).count)\n".data(using: .utf8)!)
        guard let window = players.first(where: \.isVisible),
              let view = window.contentView?.superview else { return }
        if let player = window.contentViewController as? PlayerViewController {
            let engine = player.engine
            print("[debug] title=\(engine.currentItem?.title ?? "-") t=\(engine.currentTime) d=\(engine.duration) playing=\(engine.isPlaying) media=\(engine.hasMedia) size=\(engine.videoSize) audio=\(engine.audioTracks.map(\.displayName)) subs=\(engine.subtitleTracks.map(\.displayName)) chapters=\(engine.chapters.count) status=\(engine.statusMessage)")
        }
        if let player = window.contentViewController as? PlayerViewController, player.engine.isActive {
            let shot = url.deletingPathExtension().path + "-vo.png"
            MPV.command(player.engine.handle, ["screenshot-to-file", shot, "window"])
            print("[debug] renderer=\(player.engine.renderer.rawValue) vo-shot=\(shot)")
        }
        print("[debug] window=\(window.frame.size) content=\(window.contentLayoutRect.size)")
        print("[debug] menu=\(NSApp.mainMenu?.items.map(\.title) ?? []) appMenu=\(NSApp.mainMenu?.items.first?.submenu?.items.first?.title ?? "")")
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
