import Foundation

// A saved view is a small, portable query over the current library: a search,
// media type, source, favorites filter, and sort order. It stores no media or
// permissions, so reopening one after disconnecting a source simply shows the
// items that are still available.
struct SavedLens: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var query = ""
    var kind: MediaItem.Kind?
    var favoritesOnly = false
    var source: MosaicFilter.Source = .all
    var sort: MediaSort = .newest
    var createdAt = Date()

    init(
        name: String, query: String = "", kind: MediaItem.Kind? = nil,
        favoritesOnly: Bool = false, source: MosaicFilter.Source = .all,
        sort: MediaSort = .newest, createdAt: Date = Date()
    ) {
        self.name = name
        self.query = query
        self.kind = kind
        self.favoritesOnly = favoritesOnly
        self.source = source
        self.sort = sort
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, query, kind, favoritesOnly, source, sort, createdAt
    }

    // Build 16 saved the first four fields only. Missing filter keys mean the
    // defaults rather than an unreadable archive.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        query = try values.decodeIfPresent(String.self, forKey: .query) ?? ""
        kind = try values.decodeIfPresent(MediaItem.Kind.self, forKey: .kind)
        favoritesOnly = try values.decodeIfPresent(Bool.self, forKey: .favoritesOnly) ?? false
        source = try values.decodeIfPresent(MosaicFilter.Source.self, forKey: .source) ?? .all
        sort = try values.decodeIfPresent(MediaSort.self, forKey: .sort) ?? .newest
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    var summary: String {
        var parts: [String] = []
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("“\(query)”")
        }
        parts.append(kind?.title ?? "All media")
        if favoritesOnly { parts.append("Favorites") }
        if source != .all { parts.append(source.rawValue) }
        if sort != .newest { parts.append(sort.rawValue) }
        return parts.joined(separator: " · ")
    }
}
