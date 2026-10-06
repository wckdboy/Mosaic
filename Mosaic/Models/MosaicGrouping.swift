import Foundation

// Compact visual descriptors are persisted instead of images. Version 2 adds a
// dominant palette, on-device scene labels, and a quantized Vision feature print;
// older descriptors decode with those fields absent and are re-analyzed.
struct VisualDescriptor: Codable, Sendable, Equatable {
    static let currentVersion = 2
    let color: String
    let hash: UInt64
    var sourceModified: Date?
    var version: Int?
    // Dominant color in HSB (0...1), then up to three palette swatches as 0xRRGGBB.
    var hue: Float?
    var saturation: Float?
    var brightness: Float?
    var palette: [UInt32]?
    // Vision classification identifiers, most confident first, and their coarse theme.
    var labels: [String]?
    var theme: String?
    // L2-normalized feature print, quantized to Int8 (×127). Cosine similarity is a dot product.
    var feature: Data?

    var isCurrent: Bool { (version ?? 1) >= Self.currentVersion }
    var dominantRGB: UInt32? { palette?.first }
}

enum MosaicGrouping: String, CaseIterable, Identifiable {
    case color = "Color"
    case theme = "Theme"
    case similar = "Similar"
    case name = "Name"
    case sentiment = "Sentiment"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .color: "circle.lefthalf.filled"
        case .theme: "sparkles.rectangle.stack"
        case .similar: "square.on.square"
        case .name: "textformat.abc"
        case .sentiment: "text.bubble"
        }
    }
}

struct MosaicCluster: Identifiable, Sendable {
    let id: String
    let title: String
    var items: [MediaItem]
}

// Color families are ordered around the wheel, so packed islands of neighboring
// hues sit next to each other on the canvas and panning reads as a gradient.
enum ColorFamily {
    static let order = [
        "Red", "Orange", "Brown", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink", "Light", "Neutral",
        "Dark",
    ]
    static func name(hue: Float, saturation: Float, brightness: Float) -> String {
        if brightness < 0.16 { return "Dark" }
        if saturation < 0.14 { return brightness > 0.82 ? "Light" : "Neutral" }
        switch hue * 360 {
        case 12..<40: return brightness < 0.55 ? "Brown" : "Orange"
        case 40..<68: return brightness < 0.4 ? "Brown" : "Yellow"
        case 68..<160: return "Green"
        case 160..<195: return "Teal"
        case 195..<255: return "Blue"
        case 255..<290: return "Purple"
        case 290..<340: return "Pink"
        default: return "Red"
        }
    }
    static func rank(_ name: String) -> Int { order.firstIndex(of: name) ?? order.count }
}

// Vision's taxonomy is hierarchical and reports ancestors (e.g. "animal" with
// "dog"), so a small keyword table maps ~1,300 identifiers to a few themes.
enum MediaTheme {
    static let fallback = "Everyday"
    static let table: [(theme: String, keywords: Set<String>)] = [
        (
            "Documents",
            [
                "document", "text", "screenshot", "receipt", "handwriting", "whiteboard", "menu", "paper",
                "book", "poster", "sign", "map", "diagram", "chart",
            ]
        ),
        (
            "Animals",
            [
                "animal", "mammal", "dog", "cat", "bird", "pet", "horse", "fish", "insect", "reptile",
                "canine", "feline", "puppy", "kitten", "wildlife",
            ]
        ),
        (
            "Food & Drink",
            [
                "food", "drink", "beverage", "dessert", "fruit", "vegetable", "meal", "baked_goods",
                "coffee", "wine", "cocktail", "pizza", "sushi", "cake", "bread", "salad",
            ]
        ),
        (
            "People",
            [
                "people", "person", "adult", "child", "baby", "crowd", "selfie", "portrait", "wedding",
                "group", "face", "teen", "toddler",
            ]
        ),
        (
            "Water & Beach",
            [
                "water", "beach", "ocean", "sea", "lake", "river", "shore", "underwater", "waterfall",
                "pool", "swimming", "surfing", "coast", "wave", "boat",
            ]
        ),
        (
            "Snow",
            ["snow", "ice", "winter", "skiing", "snowboarding", "glacier"]
        ),
        (
            "Night & Lights",
            ["night_sky", "fireworks", "concert", "nightclub", "neon", "candle", "light", "dark", "moon"]
        ),
        (
            "Sky",
            ["sky", "cloud", "sunset_sunrise", "sunset", "sunrise", "sun", "rainbow", "blue_sky"]
        ),
        (
            "Nature",
            [
                "plant", "flower", "tree", "foliage", "mountain", "forest", "grass", "garden", "landscape",
                "hill", "desert", "field", "leaf", "outdoor", "park", "canyon", "rock",
            ]
        ),
        (
            "City & Places",
            [
                "structure", "building", "cityscape", "architecture", "street", "bridge", "skyscraper",
                "road", "tower", "church", "monument", "urban", "house",
            ]
        ),
        (
            "Indoors",
            [
                "interior_room", "room", "furniture", "kitchen", "bedroom", "living_room", "office",
                "restaurant", "bar", "table", "chair",
            ]
        ),
        (
            "Vehicles",
            ["vehicle", "car", "aircraft", "airplane", "train", "bicycle", "motorcycle", "truck", "bus"]
        ),
        (
            "Art & Design",
            ["art", "painting", "drawing", "illustration", "sculpture", "graffiti", "cartoon", "pattern"]
        ),
        (
            "Sports & Action",
            ["sport", "ball", "games", "athlete", "stadium", "running", "skateboarding", "gym", "dancing"]
        ),
    ]

    // Weighted by label confidence, with earlier labels carrying more signal.
    static func theme(for labels: [(identifier: String, confidence: Float)]) -> String {
        var scores: [String: Float] = [:]
        for label in labels {
            let parts = Set(label.identifier.lowercased().split(separator: "_").map(String.init))
                .union([label.identifier.lowercased()])
            for entry in table where !entry.keywords.isDisjoint(with: parts) {
                scores[entry.theme, default: 0] += label.confidence
            }
        }
        guard let best = scores.max(by: { $0.value < $1.value }), best.value >= 0.25 else {
            return fallback
        }
        return best.key
    }
    static func rank(_ theme: String) -> Int {
        table.firstIndex(where: { $0.theme == theme }) ?? table.count
    }
    static func readable(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }
}

// Similarity primitives over descriptors. Feature prints dominate when present;
// the 64-bit composition hash and palette remain as fallbacks for older entries.
enum VisualMetric {
    // Cosine distance in 0...2 for the Int8-quantized, unit-length vectors.
    static func featureDistance(_ a: Data, _ b: Data) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        let dot = a.withUnsafeBytes { left in
            b.withUnsafeBytes { right in
                let l = left.bindMemory(to: Int8.self)
                let r = right.bindMemory(to: Int8.self)
                var sum: Int32 = 0
                for index in 0..<l.count { sum &+= Int32(l[index]) &* Int32(r[index]) }
                return sum
            }
        }
        return 1 - Float(dot) / (127 * 127)
    }
    // Perceptual RGB distance normalized to roughly 0...1.
    static func colorDistance(_ a: UInt32, _ b: UInt32) -> Float {
        let dr = Float(Int((a >> 16) & 255) - Int((b >> 16) & 255))
        let dg = Float(Int((a >> 8) & 255) - Int((b >> 8) & 255))
        let db = Float(Int(a & 255) - Int(b & 255))
        let mean = Float(Int((a >> 16) & 255) + Int((b >> 16) & 255)) / 2
        let weighted = (2 + mean / 256) * dr * dr + 4 * dg * dg + (2 + (255 - mean) / 256) * db * db
        return min(1, weighted.squareRoot() / 765)
    }
    static func paletteDistance(_ a: [UInt32], _ b: [UInt32]) -> Float {
        guard let first = a.first, let other = b.first else { return 1 }
        var total = colorDistance(first, other) * 0.6
        let restA = a.dropFirst()
        let restB = b.dropFirst()
        if !restA.isEmpty && !restB.isEmpty {
            // Each secondary swatch matches its closest counterpart.
            let secondary =
                restA.map { swatch in restB.map { colorDistance(swatch, $0) }.min() ?? 1 }
                .reduce(0, +) / Float(restA.count)
            total += secondary * 0.4
        } else {
            total += colorDistance(first, other) * 0.4
        }
        return total
    }
    static func labelOverlap(_ a: [String]?, _ b: [String]?) -> Float {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return 0 }
        let left = Set(a)
        let right = Set(b)
        return Float(left.intersection(right).count) / Float(left.union(right).count)
    }
    // 0 is identical. Combines semantics, palette, and shared labels.
    static func distance(_ a: VisualDescriptor, _ b: VisualDescriptor) -> Float? {
        guard let fa = a.feature, let fb = b.feature else { return nil }
        let semantic = featureDistance(fa, fb)
        let color = paletteDistance(a.palette ?? [], b.palette ?? [])
        let labels = 1 - labelOverlap(a.labels, b.labels)
        return semantic * 0.7 + color * 0.2 + labels * 0.1
    }
}

// Clustering bounds similarity work to a fixed number of representatives, avoiding
// all-pairs comparison as libraries grow. Unanalyzed items remain visible.
enum MosaicClusterBuilder {
    static let notAnalyzed = "Not analyzed"

    static func clusters(
        items: [MediaItem], mode: MosaicGrouping, descriptors: [String: VisualDescriptor],
        sentiments: [String: String]
    ) -> [MosaicCluster] {
        var groups: [String: [MediaItem]] = [:]
        var order: [String: Int] = [:]
        switch mode {
        case .similar:
            return similarClusters(items: items, descriptors: descriptors)
        case .color:
            for item in items {
                groups[descriptors[item.id]?.color ?? notAnalyzed, default: []].append(item)
            }
            for key in groups.keys { order[key] = ColorFamily.rank(key) }
        case .theme:
            for item in items {
                let key: String
                if let descriptor = descriptors[item.id] {
                    key = descriptor.theme ?? (descriptor.isCurrent ? MediaTheme.fallback : notAnalyzed)
                } else {
                    key = notAnalyzed
                }
                groups[key, default: []].append(item)
            }
            // Larger themes sit first so the canvas opens on its richest region.
            for (key, value) in groups { order[key] = -value.count }
        case .name:
            for item in items { groups[nameGroup(item.name), default: []].append(item) }
        case .sentiment:
            for item in items { groups[sentiments[item.id] ?? "Neutral", default: []].append(item) }
        }
        return groups.map { key, value in
            MosaicCluster(id: key, title: key, items: sortedForGradient(value, descriptors: descriptors))
        }
        .sorted { left, right in
            if left.id == notAnalyzed { return false }
            if right.id == notAnalyzed { return true }
            let l = order[left.id] ?? 0
            let r = order[right.id] ?? 0
            return l == r ? left.title.localizedStandardCompare(right.title) == .orderedAscending : l < r
        }
    }

    // Within an island, hue then brightness produce smooth color transitions.
    // Items without color data keep their incoming (date) order after analyzed ones.
    static func sortedForGradient(_ items: [MediaItem], descriptors: [String: VisualDescriptor])
        -> [MediaItem]
    {
        let keyed = items.enumerated().map { offset, item -> (MediaItem, Float, Float, Int) in
            guard let d = descriptors[item.id], let hue = d.hue, let brightness = d.brightness else {
                return (item, 9, 9, offset)
            }
            // Quantized hue keeps brightness ordering meaningful inside a band.
            return (item, (hue * 12).rounded(.down), -brightness, offset)
        }
        return keyed.sorted {
            ($0.1, $0.2, $0.3) < ($1.1, $1.2, $1.3)
        }.map(\.0)
    }

    // Leader clustering: each item joins its nearest representative when close
    // enough, otherwise founds a new group while under the representative budget.
    static func similarClusters(items: [MediaItem], descriptors: [String: VisualDescriptor])
        -> [MosaicCluster]
    {
        var groups: [[MediaItem]] = []
        var leaders: [VisualDescriptor] = []
        var other: [MediaItem] = []
        var missing: [MediaItem] = []
        let budget = 40
        for item in items {
            guard let descriptor = descriptors[item.id] else {
                missing.append(item)
                continue
            }
            var best: (index: Int, distance: Float)?
            for (index, leader) in leaders.enumerated() {
                let distance: Float
                let threshold: Float
                if let value = VisualMetric.distance(descriptor, leader) {
                    distance = value
                    threshold = 0.42
                } else if descriptor.feature == nil && leader.feature == nil {
                    distance = Float((leader.hash ^ descriptor.hash).nonzeroBitCount)
                    threshold = 12
                } else {
                    continue
                }
                if distance <= threshold, distance < (best?.distance ?? .infinity) {
                    best = (index, distance)
                }
            }
            if let best {
                groups[best.index].append(item)
            } else if leaders.count < budget {
                leaders.append(descriptor)
                groups.append([item])
            } else {
                other.append(item)
            }
        }
        var used: [String: Int] = [:]
        var result: [MosaicCluster] = []
        for (index, members) in groups.enumerated() {
            var title = groupTitle(members, leader: leaders[index], descriptors: descriptors)
            used[title, default: 0] += 1
            // Letters, not numbers: the island label already shows a count after the title.
            if let count = used[title], count > 1 {
                title += " " + String(UnicodeScalar(UInt8(64 + min(count, 26))))
            }
            result.append(
                MosaicCluster(
                    id: "group-\(index)", title: title,
                    items: sortedForGradient(members, descriptors: descriptors)))
        }
        // Larger groups first; singletons gather at the end to avoid a confetti canvas.
        result.sort { $0.items.count == $1.items.count ? $0.id < $1.id : $0.items.count > $1.items.count }
        let singles = result.filter { $0.items.count == 1 }
        result.removeAll { $0.items.count == 1 }
        let loose = singles.flatMap(\.items) + other
        if !loose.isEmpty {
            result.append(MosaicCluster(id: "other", title: "Other compositions", items: loose))
        }
        if !missing.isEmpty { result.append(MosaicCluster(id: notAnalyzed, title: notAnalyzed, items: missing)) }
        return result
    }

    private static func groupTitle(
        _ members: [MediaItem], leader: VisualDescriptor, descriptors: [String: VisualDescriptor]
    ) -> String {
        var counts: [String: Int] = [:]
        for member in members.prefix(64) {
            if let label = descriptors[member.id]?.labels?.first { counts[label, default: 0] += 1 }
        }
        let color = leader.color
        if let label = counts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key {
            return "\(MediaTheme.readable(label).capitalized) · \(color)"
        }
        // The fallback theme says nothing about the media; name the group by color.
        guard let theme = leader.theme, theme != MediaTheme.fallback else { return "\(color) compositions" }
        return "\(theme) · \(color)"
    }

    static func nameGroup(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let words = stem.replacingOccurrences(of: "[0-9_\\-]+", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
        return words.first.map { String($0).capitalized } ?? "Other names"
    }
}
