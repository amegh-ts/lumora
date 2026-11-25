import AppKit
import CryptoKit

/// Channel logos: downloaded on demand, kept in memory and on disk (Caches), at most a few at a
/// time so scrolling a list of 11,000 channels never floods the network.
@MainActor
final class ChannelLogoLoader {
    static let shared = ChannelLogoLoader()

    private let memory = NSCache<NSURL, NSImage>()
    private var failed = Set<URL>()
    private var waiting: [URL: [(NSImage?) -> Void]] = [:]
    private var queue: [URL] = []
    private var running = 0
    private static let maxConcurrent = 6
    nonisolated private static let maxBytes = 512 * 1024

    nonisolated private static var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.lumora.player/ChannelLogos", isDirectory: true)
    }

    private init() {
        memory.countLimit = 400
    }

    /// Frees logos held in memory (they stay in the disk cache).
    func purgeMemory() {
        memory.removeAllObjects()
        failed.removeAll()
    }

    func cached(_ url: URL) -> NSImage? {
        memory.object(forKey: url as NSURL)
    }

    /// Calls back on the main thread with the logo, or nil if it can't be loaded.
    func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        if let image = memory.object(forKey: url as NSURL) {
            completion(image)
            return
        }
        guard !failed.contains(url) else {
            completion(nil)
            return
        }
        if waiting[url] != nil {
            waiting[url]?.append(completion)
            return
        }
        waiting[url] = [completion]
        queue.append(url)
        pump()
    }

    /// Rows scrolled away no longer need their logo first.
    func cancel(_ url: URL) {
        guard let index = queue.firstIndex(of: url) else { return }
        queue.remove(at: index)
        waiting[url] = nil
    }

    private func pump() {
        while running < Self.maxConcurrent, !queue.isEmpty {
            let url = queue.removeLast()
            running += 1
            Task {
                let image = await Self.fetch(url)
                running -= 1
                if let image {
                    memory.setObject(image, forKey: url as NSURL)
                } else {
                    failed.insert(url)
                }
                waiting.removeValue(forKey: url)?.forEach { $0(image) }
                pump()
            }
        }
    }

    nonisolated private static func fetch(_ url: URL) async -> NSImage? {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = folder.appendingPathComponent(name)
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            return image
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Lumora", forHTTPHeaderField: "User-Agent")
        guard case .success(let data) = await CappedDownload.data(for: request, maxBytes: maxBytes), let image = NSImage(data: data)
        else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return image
    }
}
