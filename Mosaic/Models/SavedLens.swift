import Foundation

// A saved view is a small, portable query over the current library: a search,
// media type, and sort order. It stores no media or permissions, so reopening one
// after disconnecting a source simply shows the items that are still available.
struct SavedLens: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var query = ""
    var kind: MediaItem.Kind?
    var sort: MediaSort = .newest
    var createdAt = Date()

    var summary: String {
        var parts: [String] = []
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("“\(query)”")
        }
        parts.append(kind?.title ?? "All media")
        if sort != .newest { parts.append(sort.rawValue) }
        return parts.joined(separator: " · ")
    }
}
