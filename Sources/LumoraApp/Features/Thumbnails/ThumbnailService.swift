import AppKit
import CryptoKit
import CMPV

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    private struct Request {
        let url: URL
        let bucket: Int
        let completion: (NSImage?) -> Void
    }

    private let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    /// Files that produced no picture (audio-only, unsupported), so hovering doesn't retry them.
    private var failedKeys = Set<String>()
    private var isWorking = false
    private var pending: Request?
    private var debounce: DispatchWorkItem?

    private init() {
        Task.detached(priority: .background) {
            ThumbnailService.pruneDiskCache()
        }
    }

    func request(url: URL, time: TimeInterval, duration: TimeInterval, completion: @escaping (NSImage?) -> Void) {
        guard url.isFileURL else {
            completion(nil)
            return
        }
        let step = max(2, duration / 200)
        let bucket = Int((time / step).rounded() * step)
        let key = cacheKey(url: url, bucket: bucket)
        if let image = memoryCache.object(forKey: key as NSString) {
            completion(image)
            return
        }
        if failedKeys.contains(cacheKey(url: url, bucket: -1)) {
            completion(nil)
            return
        }
        // Only the latest hover position matters; tell the replaced request it won't get an image.
        pending?.completion(nil)
        pending = Request(url: url, bucket: bucket, completion: completion)
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runNext() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func runNext() {
        guard !isWorking, let request = pending else { return }
        pending = nil
        isWorking = true
        let key = cacheKey(url: request.url, bucket: request.bucket)
        let file = AppPaths.thumbnailCache.appendingPathComponent("\(key).jpg")
        let url = request.url
        let time = TimeInterval(request.bucket)
        Task { @MainActor in
            let data = await Self.generate(url: url, time: time, file: file)
            let image = data.flatMap(NSImage.init(data:))
            if let image {
                self.store(image, for: key)
            } else {
                self.failedKeys.insert(self.cacheKey(url: url, bucket: -1))
            }
            request.completion(image)
            self.isWorking = false
            self.runNext()
        }
    }

    nonisolated private static func generate(url: URL, time: TimeInterval, file: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            loadOrGenerate(url: url, time: time, file: file)
        }.value
    }

    private func store(_ image: NSImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    private func cacheKey(url: URL, bucket: Int) -> String {
        // Size and modification date are part of the key so a replaced file gets fresh previews.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(url.path)|\(size)|\(Int(modified))".utf8))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(hex)-\(bucket)"
    }

    nonisolated private static func loadOrGenerate(url: URL, time: TimeInterval, file: URL) -> Data? {
        if let data = try? Data(contentsOf: file) {
            return data
        }
        AppPaths.ensureDirectories()
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumora-thumb-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        guard let handle = mpv_create() else { return nil }
        defer { mpv_terminate_destroy(handle) }
        let options: [(String, String)] = [
            ("config", "no"),
            ("terminal", "no"),
            ("msg-level", "all=no"),
            ("vo", "image"),
            ("vo-image-format", "jpg"),
            ("vo-image-jpeg-quality", "80"),
            ("vo-image-outdir", workDirectory.path),
            ("ao", "null"),
            ("aid", "no"),
            ("sid", "no"),
            ("hwdec", "no"),
            ("vd-lavc-threads", "2"),
            ("vd-lavc-skiploopfilter", "all"),
            ("cache", "no"),
            ("demuxer-max-bytes", "8MiB"),
            ("sub-auto", "no"),
            ("audio-file-auto", "no"),
            ("load-stats-overlay", "no"),
            ("load-console", "no"),
            ("load-auto-profiles", "no"),
            ("load-select", "no"),
            ("load-positioning", "no"),
            ("load-commands", "no"),
            ("load-context-menu", "no"),
            ("osc", "no"),
            ("hr-seek", "no"),
            ("frames", "1"),
            ("start", String(max(0, time))),
            ("vf", "scale=w=320:h=-2"),
            ("ytdl", "no"),
            ("idle", "no"),
            ("load-scripts", "no"),
            ("access-references", "no"),
            ("load-unsafe-playlists", "no")
        ]
        for (name, value) in options {
            mpv_set_option_string(handle, name, value)
        }
        guard mpv_initialize(handle) >= 0 else { return nil }
        MPV.command(handle, ["loadfile", url.path], async: false)

        let deadline = Date().addingTimeInterval(6)
        waiting: while Date() < deadline {
            guard let event = mpv_wait_event(handle, 0.5)?.pointee else { continue }
            switch event.event_id {
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN, MPV_EVENT_IDLE:
                break waiting
            default:
                continue
            }
        }
        let produced = (try? FileManager.default.contentsOfDirectory(at: workDirectory, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "jpg" }
        guard let produced, let data = try? Data(contentsOf: produced) else { return nil }
        try? data.write(to: file, options: .atomic)
        return data
    }

    nonisolated private static func pruneDiskCache() {
        let directory = AppPaths.thumbnailCache
        let keys: [URLResourceKey] = [.contentAccessDateKey, .fileSizeKey]
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys
            )
        else { return }
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if let accessed = values?.contentAccessDate, accessed < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
