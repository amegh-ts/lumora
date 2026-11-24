import Foundation
import Combine

@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var items: [PlaybackItem] = []
    @Published private(set) var currentIndex: Int?
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off

    var current: PlaybackItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    func add(_ newItems: [PlaybackItem], playFirst: Bool = false) {
        guard !newItems.isEmpty else { return }
        let startIndex = items.count
        items.append(contentsOf: newItems)
        if playFirst || currentIndex == nil {
            currentIndex = startIndex
        }
    }

    func clear() {
        items.removeAll()
        currentIndex = nil
    }

    func insert(_ item: PlaybackItem, afterCurrent: Bool = true) {
        let index: Int
        if afterCurrent, let currentIndex {
            index = min(currentIndex + 1, items.count)
        } else {
            index = items.count
        }
        items.insert(item, at: index)
        if currentIndex == nil {
            currentIndex = index
        } else if index <= currentIndex! {
            currentIndex! += 1
        }
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        guard let currentIndex else { return }
        if index < currentIndex {
            self.currentIndex = currentIndex - 1
        } else if index == currentIndex {
            self.currentIndex = items.isEmpty ? nil : min(index, items.count - 1)
        }
    }

    func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source), items.indices.contains(destination), source != destination else { return }
        let item = items.remove(at: source)
        items.insert(item, at: destination)
        guard let oldCurrent = currentIndex else { return }
        if oldCurrent == source {
            currentIndex = destination
        } else if source < oldCurrent && destination >= oldCurrent {
            currentIndex = oldCurrent - 1
        } else if source > oldCurrent && destination <= oldCurrent {
            currentIndex = oldCurrent + 1
        }
    }

    func select(at index: Int) {
        guard items.indices.contains(index) else { return }
        currentIndex = index
    }

    func next(auto: Bool = false) -> PlaybackItem? {
        guard !items.isEmpty else { return nil }
        guard let currentIndex else {
            self.currentIndex = 0
            return items[0]
        }
        if auto && repeatMode == .one {
            return items[currentIndex]
        }
        if shuffle && items.count > 1 {
            var candidate = currentIndex
            while candidate == currentIndex {
                candidate = Int.random(in: 0..<items.count)
            }
            self.currentIndex = candidate
            return items[candidate]
        }
        let candidate = currentIndex + 1
        guard candidate < items.count else {
            if auto && repeatMode == .off {
                return nil
            }
            self.currentIndex = 0
            return items[0]
        }
        self.currentIndex = candidate
        return items[candidate]
    }

    func previous() -> PlaybackItem? {
        guard !items.isEmpty else { return nil }
        guard let currentIndex else {
            self.currentIndex = 0
            return items[0]
        }
        let candidate = currentIndex - 1
        if candidate >= 0 {
            self.currentIndex = candidate
            return items[candidate]
        }
        if repeatMode != .off {
            self.currentIndex = items.count - 1
            return items[items.count - 1]
        }
        self.currentIndex = 0
        return items[0]
    }
}
