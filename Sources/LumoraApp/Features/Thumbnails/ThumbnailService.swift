import AppKit
import AVFoundation

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    private var memoryCache: [String: NSImage] = [:]

    func cached(url: URL, time: TimeInterval) -> NSImage? {
        let key = cacheKey(url: url, time: time)
        if let image = memoryCache[key] {
            return image
        }
        let file = cacheFile(key: key)
        guard let data = try? Data(contentsOf: file), let image = NSImage(data: data) else { return nil }
        memoryCache[key] = image
        return image
    }

    func thumbnail(url: URL, time: TimeInterval) async -> NSImage? {
        if let cached = cached(url: url, time: time) {
            return cached
        }
        let key = cacheKey(url: url, time: time)
        let file = cacheFile(key: key)
        let data = await Task.detached(priority: .utility) { () -> Data? in
            if let diskData = try? Data(contentsOf: file) {
                return diskData
            }
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
            guard let image = try? generator.copyCGImage(at: target, actualTime: nil) else { return nil }
            let representation = NSBitmapImageRep(cgImage: image)
            guard let png = representation.representation(using: .png, properties: [:]) else { return nil }
            try? png.write(to: file)
            return png
        }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        memoryCache[key] = image
        return image
    }

    func prewarm(url: URL, duration: TimeInterval) {
        guard duration > 0 else { return }
        Task { @MainActor in
            for index in 1...8 {
                let time = duration * Double(index) / 9
                _ = await thumbnail(url: url, time: time)
            }
        }
    }

    private func cacheKey(url: URL, time: TimeInterval) -> String {
        let encoded = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        let bucket = Int(time.rounded())
        return "\(encoded)-\(bucket)"
    }

    private func cacheFile(key: String) -> URL {
        AppPaths.thumbnailCache.appendingPathComponent("\(key).png")
    }
}
