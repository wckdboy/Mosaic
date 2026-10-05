import Foundation

// Search and filtering operate on metadata only; they never start media downloads.
struct MosaicFilter: Equatable, Sendable {
    enum Source: String, CaseIterable, Sendable {
        case all = "All sources"
        case photos = "Photos"
        case files = "Files"
    }
    var query = ""
    var kind: MediaItem.Kind?
    var favoritesOnly = false
    var source = Source.all
    var isActive: Bool { kind != nil || favoritesOnly || source != .all }

    func matches(_ item: MediaItem, favorites: Set<String>, text: [String: String]) -> Bool {
        guard kind == nil || kind == item.kind,
            !favoritesOnly || favorites.contains(item.id),
            source == .all || (source == .photos ? item.isPhotoLibrary : !item.isPhotoLibrary)
        else { return false }
        let words = query.split(whereSeparator: \.isWhitespace)
        let searchable =
            "\(item.name) \(item.kind.title) \(Calendar.current.component(.year, from: item.date)) \(text[item.id] ?? "")"
        return words.allSatisfy { searchable.localizedStandardContains(String($0)) }
    }
}

// A seed search compares every available descriptor once, then sorts its bounded
// result set. It crosses media types: a video's thumbnail can match a photograph.
// Missing descriptors never masquerade as visual matches; names provide a fallback.
enum MosaicSimilarity {
    static func matches(
        seed: MediaItem, items: [MediaItem], mode: MosaicGrouping,
        descriptors: [String: VisualDescriptor], sentiments: [String: String] = [:]
    ) -> [MediaItem] {
        let seedVisual = descriptors[seed.id]
        let seedName = MosaicClusterBuilder.nameGroup(seed.name)
        let ranked: [(item: MediaItem, distance: Int)] = items.compactMap { item in
            guard item.id != seed.id else { return nil }
            switch mode {
            case .name:
                return seedName != "Other names" && MosaicClusterBuilder.nameGroup(item.name) == seedName
                    ? (item, 0) : nil
            case .sentiment:
                guard let sentiment = sentiments[seed.id], sentiments[item.id] == sentiment else {
                    return nil
                }
                return (item, 0)
            case .color:
                guard let seedVisual, let candidate = descriptors[item.id],
                    candidate.color == seedVisual.color
                else { return nil }
                return (item, (seedVisual.hash ^ candidate.hash).nonzeroBitCount)
            case .similar:
                if let seedVisual, let candidate = descriptors[item.id] {
                    let distance = (seedVisual.hash ^ candidate.hash).nonzeroBitCount
                    guard distance <= 20 else { return nil }
                    return (item, distance + (seedVisual.color == candidate.color ? 0 : 6))
                }
                guard seedVisual == nil, seedName != "Other names",
                    MosaicClusterBuilder.nameGroup(item.name) == seedName
                else { return nil }
                return (item, 64)
            }
        }
        return ranked.sorted {
            $0.distance == $1.distance ? $0.item.id < $1.item.id : $0.distance < $1.distance
        }.prefix(200).map(\.item)
    }
}
