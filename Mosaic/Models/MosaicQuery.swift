import Foundation

// Search and filtering operate on metadata and the local visual index only; they
// never start media downloads. "beach", "blue", or "dog" match analyzed content.
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

    func matches(
        _ item: MediaItem, favorites: Set<String>, text: [String: String],
        visual: [String: VisualDescriptor] = [:]
    ) -> Bool {
        guard kind == nil || kind == item.kind,
            !favoritesOnly || favorites.contains(item.id),
            source == .all || (source == .photos ? item.isPhotoLibrary : !item.isPhotoLibrary)
        else { return false }
        let words = query.split(whereSeparator: \.isWhitespace)
        if words.isEmpty { return true }
        var searchable =
            "\(item.name) \(item.kind.title) \(Calendar.current.component(.year, from: item.date)) \(text[item.id] ?? "")"
        if let descriptor = visual[item.id] {
            searchable += " \(descriptor.color) \(descriptor.theme ?? "")"
            for label in descriptor.labels ?? [] { searchable += " \(MediaTheme.readable(label))" }
        }
        return words.allSatisfy { searchable.localizedStandardContains(String($0)) }
    }
}

// A seed search compares every available descriptor once, then sorts its bounded
// result set. It crosses media types: a video's poster frame can match a photograph.
// Missing descriptors never masquerade as visual matches; names provide a fallback.
// Results are ordered most-similar first, which the canvas lays out center-outward.
enum MosaicSimilarity {
    static let limit = 900

    static func matches(
        seed: MediaItem, items: [MediaItem], mode: MosaicGrouping,
        descriptors: [String: VisualDescriptor], sentiments: [String: String] = [:],
        continuing: Bool = false
    ) -> [MediaItem] {
        let seedVisual = descriptors[seed.id]
        let seedName = MosaicClusterBuilder.nameGroup(seed.name)
        let ranked: [(item: MediaItem, distance: Float)] = items.compactMap { item in
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
                guard let seedVisual, let candidate = descriptors[item.id] else { return nil }
                if let a = seedVisual.palette, let b = candidate.palette {
                    let distance = VisualMetric.paletteDistance(a, b)
                    return distance <= 0.22 ? (item, distance) : nil
                }
                guard candidate.color == seedVisual.color else { return nil }
                return (item, Float((seedVisual.hash ^ candidate.hash).nonzeroBitCount))
            case .theme:
                guard let seedVisual, let theme = seedVisual.theme, let candidate = descriptors[item.id]
                else { return nil }
                let shared = VisualMetric.labelOverlap(seedVisual.labels, candidate.labels)
                guard candidate.theme == theme || shared >= 0.25 else { return nil }
                let distance = VisualMetric.distance(seedVisual, candidate) ?? (1 - shared)
                return (item, distance + (candidate.theme == theme ? 0 : 0.5))
            case .similar:
                if let seedVisual, let candidate = descriptors[item.id] {
                    if let distance = VisualMetric.distance(seedVisual, candidate) {
                        return distance <= 0.6 ? (item, distance) : nil
                    }
                    let distance = (seedVisual.hash ^ candidate.hash).nonzeroBitCount
                    guard distance <= 20 else { return nil }
                    // Hash fallbacks rank after any semantic match.
                    return (item, 10 + Float(distance + (seedVisual.color == candidate.color ? 0 : 6)))
                }
                guard seedVisual == nil, seedName != "Other names",
                    MosaicClusterBuilder.nameGroup(item.name) == seedName
                else { return nil }
                return (item, 100)
            }
        }
        var result = ranked.sorted {
            $0.distance == $1.distance ? $0.item.id < $1.item.id : $0.distance < $1.distance
        }.prefix(limit).map(\.item)
        // On the canvas, discovery never dead-ends: past the close matches, the rest of
        // the analyzed library continues outward in decreasing visual similarity.
        if continuing, let seedVisual, result.count < limit, mode != .name, mode != .sentiment {
            let included = Set(result.map(\.id)).union([seed.id])
            let rest: [(item: MediaItem, distance: Float)] = items.compactMap { item in
                guard !included.contains(item.id), let candidate = descriptors[item.id] else { return nil }
                let distance =
                    VisualMetric.distance(seedVisual, candidate)
                    ?? (Float((seedVisual.hash ^ candidate.hash).nonzeroBitCount) / 32
                        + VisualMetric.paletteDistance(seedVisual.palette ?? [], candidate.palette ?? []))
                return (item, distance)
            }
            result += rest.sorted {
                $0.distance == $1.distance ? $0.item.id < $1.item.id : $0.distance < $1.distance
            }.prefix(limit - result.count).map(\.item)
        }
        // Unanalyzed items with a related name form the outermost ring: discoverable,
        // but placed after every visual result rather than presented as one.
        if continuing, mode == .similar, seedVisual != nil, seedName != "Other names", result.count < limit {
            let included = Set(result.map(\.id)).union([seed.id])
            result += items.filter {
                !included.contains($0.id) && descriptors[$0.id] == nil
                    && MosaicClusterBuilder.nameGroup($0.name) == seedName
            }.prefix(limit - result.count)
        }
        return result
    }
}
