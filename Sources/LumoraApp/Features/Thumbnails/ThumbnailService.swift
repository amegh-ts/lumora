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

    private var memoryCache: [String: NSImage] = [:]
    private var memoryOrder: [String] = []
    private let memoryLimit = 120
    private var isWorking = false
    private var pending: Request?

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
        if let image = memoryCache[key] {
            completion(image)
            return
        }
        pending = Request(url: url, bucket: bucket, completion: completion)
        runNext()
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
        memoryCache[key] = image
        memoryOrder.append(key)
        if memoryOrder.count > memoryLimit {
            let evicted = memoryOrder.removeFirst()
            memoryCache[evicted] = nil
        }
    }

    private func cacheKey(url: URL, bucket: Int) -> String {
        let digest = SHA256.hash(data: Data(url.path.utf8))
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
