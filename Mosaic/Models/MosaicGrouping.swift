import Foundation

// Compact visual descriptors are persisted instead of images or full ML embeddings.
// The 64-bit perceptual hash makes similarity comparisons constant-size operations.
struct VisualDescriptor: Codable, Sendable {
    let color: String
    let hash: UInt64
    var sourceModified: Date?
}

enum MosaicGrouping: String, CaseIterable, Identifiable {
    case color = "Color"
    case name = "Name"
    case similar = "Similar"
    case sentiment = "Sentiment"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .color: "circle.lefthalf.filled"
        case .name: "textformat.abc"
        case .similar: "square.on.square"
        case .sentiment: "text.bubble"
        }
    }
}

struct MosaicCluster: Identifiable, Sendable {
    let id: String
    let title: String
    var items: [MediaItem]
}

// Clustering bounds similarity work to at most 32 representatives, avoiding an
// all-pairs O(n²) comparison as libraries grow. Unanalyzed items remain visible.
enum MosaicClusterBuilder {
    static func clusters(
        items: [MediaItem], mode: MosaicGrouping, descriptors: [String: VisualDescriptor],
        sentiments: [String: String]
    ) -> [MosaicCluster] {
        var groups: [String: [MediaItem]] = [:]
        var representatives: [(name: String, hash: UInt64)] = []
        for item in items {
            let key: String
            switch mode {
            case .color: key = descriptors[item.id]?.color ?? "Not analyzed"
            case .name: key = nameGroup(item.name)
            case .sentiment: key = sentiments[item.id] ?? "Neutral"
            case .similar:
                if let descriptor = descriptors[item.id] {
                    let closest = representatives.min {
                        ($0.hash ^ descriptor.hash).nonzeroBitCount
                            < ($1.hash ^ descriptor.hash).nonzeroBitCount
                    }
                    if let closest, (closest.hash ^ descriptor.hash).nonzeroBitCount <= 12 {
                        key = closest.name
                    } else if representatives.count < 32 {
                        key = "Visual group \(representatives.count + 1)"
                        representatives.append((key, descriptor.hash))
                    } else {
                        key = "Other compositions"
                    }
                } else {
                    key = "Not analyzed"
                }
            }
            groups[key, default: []].append(item)
        }
        return groups.map { MosaicCluster(id: $0.key, title: $0.key, items: $0.value) }
            .sorted { left, right in
                if left.id == "Not analyzed" { return false }
                if right.id == "Not analyzed" { return true }
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
    }

    static func nameGroup(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let words = stem.replacingOccurrences(of: "[0-9_\\-]+", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
        return words.first.map { String($0).capitalized } ?? "Other names"
    }
}
