import Foundation

struct OSSearchResponse: Decodable {
    let data: [OSSearchItem]
}

struct OSSearchItem: Decodable {
    let attributes: OSAttributes
}

/// OpenSubtitles REST v1: `attributes.files[]` holds the downloadable files.
struct OSAttributes: Decodable {
    let language: String?
    let release: String?
    let files: [OSFile]
    let downloadCount: Int
    let hearingImpaired: Bool

    enum CodingKeys: String, CodingKey {
        case language
        case release
        case files
        case downloadCount = "download_count"
        case hearingImpaired = "hearing_impaired"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        release = try container.decodeIfPresent(String.self, forKey: .release)
        files = (try? container.decode([OSFile].self, forKey: .files)) ?? []
        downloadCount = (try? container.decodeIfPresent(Int.self, forKey: .downloadCount)) ?? 0
        hearingImpaired = (try? container.decodeIfPresent(Bool.self, forKey: .hearingImpaired)) ?? false
    }
}

struct OSFile: Decodable {
    let fileID: Int
    let fileName: String?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileName = "file_name"
    }
}

struct OSDownloadResponse: Decodable {
    let link: String
}

enum OpenSubtitlesService {
    private static let baseURL = "https://api.opensubtitles.com/api/v1"
    private static let maxSubtitleBytes = 5 * 1024 * 1024

    enum SearchError: Error {
        case badKey
        case rateLimited
        case network
        case server(Int)

        var message: String {
            switch self {
            case .badKey: return "OpenSubtitles didn't accept the API key. Check it in Settings › Subtitles."
            case .rateLimited: return "OpenSubtitles is limiting requests right now. Try again in a minute."
            case .network: return "Couldn't reach OpenSubtitles. Check your internet connection."
            case .server(let code): return "OpenSubtitles returned an error (\(code)). Try again later."
            }
        }
    }

    private static var userAgent: String {
        "Lumora \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")"
    }

    static func search(query: String, languages: String, apiKey: String) async -> [SubtitleSearchResult] {
        (try? await searchResults(query: query, languages: languages, apiKey: apiKey).get()) ?? []
    }

    /// Like `search`, but says why nothing came back.
    static func searchResults(query: String, languages: String, apiKey: String) async -> Result<[SubtitleSearchResult], SearchError> {
        guard !apiKey.isEmpty, !query.isEmpty else { return .success([]) }
        var components = URLComponents(string: "\(baseURL)/subtitles")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "languages", value: languages)
        ]
        guard let url = components?.url else { return .success([]) }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else {
            return .failure(.network)
        }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: return .failure(.badKey)
        case 429: return .failure(.rateLimited)
        default: return .failure(.server(http.statusCode))
        }
        guard let decoded = try? JSONDecoder().decode(OSSearchResponse.self, from: data) else { return .failure(.server(http.statusCode)) }
        return .success(
            decoded.data.compactMap { item in
                let attributes = item.attributes
                guard let file = attributes.files.first else { return nil }
                let name = file.fileName ?? attributes.release ?? "Subtitle \(file.fileID)"
                return SubtitleSearchResult(
                    id: String(file.fileID),
                    title: name,
                    language: attributes.language ?? "und",
                    releaseName: attributes.release ?? "",
                    fileID: file.fileID,
                    downloads: attributes.downloadCount,
                    hearingImpaired: attributes.hearingImpaired
                )
            })
    }

    static func download(result: SubtitleSearchResult, apiKey: String) async -> Data? {
        guard !apiKey.isEmpty, let url = URL(string: "\(baseURL)/download") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["file_id": result.fileID])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let decoded = try? JSONDecoder().decode(OSDownloadResponse.self, from: data),
            let downloadURL = URL(string: decoded.link),
            downloadURL.scheme?.lowercased() == "https",
            let (fileData, fileResponse) = try? await URLSession.shared.data(from: downloadURL),
            let fileHTTP = fileResponse as? HTTPURLResponse,
            (200..<300).contains(fileHTTP.statusCode),
            fileData.count <= maxSubtitleBytes
        else { return nil }
        return fileData
    }
}
