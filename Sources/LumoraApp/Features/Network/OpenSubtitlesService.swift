import Foundation

struct OSSearchResponse: Decodable {
    let data: [OSSearchItem]
}

struct OSSearchItem: Decodable {
    let attributes: OSAttributes
}

struct OSAttributes: Decodable {
    let fileID: Int
    let fileName: String
    let language: String
    let release: String?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileName = "file_name"
        case language
        case release
    }
}

struct OSDownloadResponse: Decodable {
    let link: String
}

enum OpenSubtitlesService {
    private static let baseURL = "https://api.opensubtitles.com/api/v1"
    private static let maxSubtitleBytes = 5 * 1024 * 1024

    static func search(query: String, languages: String, apiKey: String) async -> [SubtitleSearchResult] {
        guard !apiKey.isEmpty, !query.isEmpty else { return [] }
        var components = URLComponents(string: "\(baseURL)/subtitles")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "languages", value: languages)
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Lumora 0.1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let decoded = try? JSONDecoder().decode(OSSearchResponse.self, from: data)
        else { return [] }
        return decoded.data.compactMap { item in
            let attributes = item.attributes
            return SubtitleSearchResult(
                id: String(attributes.fileID),
                title: attributes.fileName,
                language: attributes.language,
                releaseName: attributes.release ?? "",
                fileID: attributes.fileID
            )
        }
    }

    static func download(result: SubtitleSearchResult, apiKey: String) async -> Data? {
        guard !apiKey.isEmpty, let url = URL(string: "\(baseURL)/download") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Lumora 0.1.0", forHTTPHeaderField: "User-Agent")
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
