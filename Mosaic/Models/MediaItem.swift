import Foundation
import UniformTypeIdentifiers

// References point at the original media; only organization and bookmarks are persisted.
struct MediaItem: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case photo, video, animated, livePhoto
        var title: String {
            switch self {
            case .photo: "Photos"
            case .video: "Videos"
            case .animated: "Animated"
            case .livePhoto: "Live Photos"
            }
        }
        var symbol: String {
            switch self {
            case .photo: "photo"
            case .video: "play.rectangle"
            case .animated: "square.stack.3d.forward.dottedline"
            case .livePhoto: "livephoto"
            }
        }
    }
    var id: String
    // Original name is retained when presenting a local display-name override.
    var name: String
    var originalName: String?
    var kind: Kind
    var date: Date
    var duration: Double = 0
    var width: Int = 0
    var height: Int = 0
    var bookmark: Data?
    var fileURL: URL?
    var folderID: UUID?
    var relativePath: String?
    var modified: Date?
    var thumbnailKey: String { "\(id)-\(modified?.timeIntervalSince1970 ?? 0)" }
    var isPhotoLibrary: Bool { id.hasPrefix("photos:") }
    var photoIdentifier: String { String(id.dropFirst(7)) }
    var format: String { (name as NSString).pathExtension.uppercased() }
    var durationLabel: String { Self.timeLabel(duration) }

    static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let value = Int(seconds)
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }

    static func kind(for url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if ext == "gif" || ext == "apng" { return .animated }
        let type = UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true { return .photo }
        if type?.conforms(to: .movie) == true
            || ["mkv", "webm", "avi", "wmv", "flv", "ts", "m2ts", "mts", "vob", "ogv"].contains(ext)
        {
            return .video
        }
        return nil
    }
}

struct MediaCollection: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var itemIDs: Set<String> = []
}

struct LibraryArchive: Codable, Sendable {
    var files: [MediaItem] = []
    var folders: [FolderConnection]? = []
    var favorites: Set<String> = []
    var collections: [MediaCollection] = []
    var playbackPositions: [String: Double] = [:]
    // Optional for backward-compatible decoding of libraries created before text search.
    var recognizedText: [String: String]? = [:]
    var displayNames: [String: String]? = [:]
    var organizationUndo: OrganizationUndo?
    var fileOrganizationUndo: [FileMoveRecord]?
    var pendingFileMove: PendingFileMove?
}

enum MediaSort: String, CaseIterable {
    case newest = "Newest first"
    case oldest = "Oldest first"
    case name = "Name"
    func sorted(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted {
            switch self {
            case .newest: $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
            case .oldest: $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
            case .name:
                $0.name == $1.name
                    ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }
}
