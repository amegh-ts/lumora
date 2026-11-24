import Foundation
import AppKit

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let lastCheckKey = "lumora.lastUpdateCheck"

    private init() {}

    func checkIfNeeded(settings: SettingsStore) async -> UpdateInfo {
        guard settings.checkForUpdates,
              !settings.updateFeedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .upToDate
        }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return .upToDate }
        return await check(settings: settings, force: false)
    }

    func check(settings: SettingsStore, force: Bool) async -> UpdateInfo {
        let feed = settings.updateFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feed.isEmpty, let url = URL(string: feed) else {
            return .failure("Set a valid update feed URL in Settings.")
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let xml = String(data: data, encoding: .utf8) else {
            return .failure("Could not read the update feed.")
        }
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)

        guard let version = extract("<version>", from: xml) else {
            return .failure("Update feed has no version.")
        }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        guard isNewer(version, than: current) else { return .upToDate }
        let notes = extract("<releaseNotes>", from: xml) ?? extract("<description>", from: xml) ?? ""
        let download = enclosureURL(from: xml)
        return .available(version: version, notes: notes, download: download)
    }

    static func present(_ info: UpdateInfo) {
        let alert = NSAlert()
        switch info {
        case .upToDate:
            alert.messageText = "Lumora is up to date"
            alert.informativeText = "No newer version was found."
            alert.addButton(withTitle: "OK")
        case let .available(version, notes, download):
            alert.messageText = "Lumora \(version) available"
            alert.informativeText = notes
            if download != nil {
                alert.addButton(withTitle: "Download")
            }
            alert.addButton(withTitle: "Later")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn, let download {
                NSWorkspace.shared.open(download)
            }
        case let .failure(message):
            alert.alertStyle = .warning
            alert.messageText = "Update check failed"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
        }
    }

    private func extract(_ tag: String, from xml: String) -> String? {
        let name = tag.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        let pattern = "<(?:[A-Za-z0-9_-]+:)?\(name)[^>]*>(.*?)</(?:[A-Za-z0-9_-]+:)?\(name)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines).decodedEntities
    }

    private func enclosureURL(from xml: String) -> URL? {
        let pattern = "<enclosure[^>]*url=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return URL(string: String(xml[range]).decodedEntities)
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left > right
            }
        }
        return false
    }
}

private extension String {
    var decodedEntities: String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
