import Foundation

// Plans are pure metadata transformations. The UI previews these exact changes;
// applying a plan never renames or moves an original in Photos or a file provider.
struct OrganizationOptions: Equatable, Sendable {
    enum Grouping: String, CaseIterable, Sendable {
        case none = "None"
        case month = "Month"
        case type = "Media type"
        case name = "Name"
        case color = "Color"
        case theme = "Theme"
    }
    var moveOriginals = false
    var rename = true
    var pattern = "{date}_{type}_{sequence}"
    var grouping = Grouping.month
}

struct OrganizationChange: Identifiable, Sendable {
    var id: String { item.id }
    let item: MediaItem
    let name: String
    let collection: String?
}

struct OrganizationUndo: Codable, Sendable {
    let itemIDs: Set<String>
    let previousNames: [String: String]
    let addedMemberships: [UUID: Set<String>]
    let createdCollections: Set<UUID>
}

enum OrganizationPlanner {
    static let tokens = ["{date}", "{type}", "{sequence}", "{original}"]
    static func validPattern(_ pattern: String) -> Bool {
        var remaining = pattern
        for token in tokens { remaining = remaining.replacingOccurrences(of: token, with: "") }
        return !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !remaining.contains("{") && !remaining.contains("}")
            && pattern.count <= 120
    }
    static func plan(
        items: [MediaItem], options: OrganizationOptions,
        descriptors: [String: VisualDescriptor], reservedNames: Set<String> = []
    ) -> [OrganizationChange] {
        guard !options.rename || validPattern(options.pattern) else { return [] }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        let month = DateFormatter()
        month.locale = day.locale
        month.timeZone = day.timeZone
        month.dateFormat = "yyyy-MM"
        var occupied = Set(reservedNames.map { $0.lowercased() })
        var nextSuffix: [String: Int] = [:]
        return items.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }.enumerated().map {
            index, item in
            let source = item.originalName ?? item.name
            let knownDate = item.date != .distantPast
            let date = knownDate ? day.string(from: item.date) : "Undated"
            let type: String
            switch item.kind {
            case .photo: type = "Photo"
            case .video: type = "Video"
            case .animated: type = "Animation"
            case .livePhoto: type = "LivePhoto"
            }
            var name = options.moveOriginals ? source : item.name
            if options.rename {
                let values = [
                    "{date}": date, "{type}": type,
                    "{sequence}": String(format: "%04d", index + 1),
                    "{original}": (source as NSString).deletingPathExtension,
                ]
                var stem = options.pattern
                for token in tokens { stem = stem.replacingOccurrences(of: token, with: values[token]!) }
                stem = sanitize(stem)
                let ext = (source as NSString).pathExtension
                let suffix = ext.isEmpty ? "" : ".\(ext)"
                name = stem + suffix
                let collisionKey = (stem + suffix).lowercased()
                var collision = nextSuffix[collisionKey] ?? 2
                while occupied.contains(name.lowercased()) {
                    name = "\(stem)-\(collision)\(suffix)"
                    collision += 1
                }
                nextSuffix[collisionKey] = collision
                occupied.insert(name.lowercased())
            }
            let collection: String?
            switch options.grouping {
            case .none: collection = nil
            case .month: collection = knownDate ? month.string(from: item.date) : "Undated"
            case .type: collection = item.kind.title
            case .name: collection = MosaicClusterBuilder.nameGroup(source)
            case .color: collection = descriptors[item.id]?.color ?? "Unsorted"
            case .theme: collection = descriptors[item.id]?.theme ?? "Unsorted"
            }
            return OrganizationChange(item: item, name: name, collection: collection)
        }
    }
    private static func sanitize(_ value: String) -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Media" : String(cleaned.prefix(180))
    }
}
