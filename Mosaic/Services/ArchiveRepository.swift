import Foundation

// A single actor serializes atomic writes, keeping disk I/O off the UI actor.
actor ArchiveRepository {
    private let url: URL
    init(url: URL? = nil) {
        self.url = url ?? URL.applicationSupportDirectory.appending(path: "Mosaic/library.json")
    }
    func load() throws -> LibraryArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return LibraryArchive() }
        return try JSONDecoder().decode(LibraryArchive.self, from: Data(contentsOf: url))
    }
    func save(_ archive: LibraryArchive) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// The lifetime of this object matches an open viewer or a thumbnail request.
// Balancing security scope matters when a file comes from an external provider.
final class FileAccess: @unchecked Sendable {
    let url: URL
    private let scoped: Bool
    private let scopeURL: URL
    init(item: MediaItem) throws {
        let root: URL
        if let bookmark = item.bookmark {
            var stale = false
            root = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
        } else if let original = item.fileURL {
            root = original
        } else {
            throw CocoaError(.fileNoSuchFile)
        }
        scopeURL = root
        let granted = root.startAccessingSecurityScopedResource()
        do {
            if let relative = item.relativePath {
                url = try FileOrganizationService.confined(relative, root: root)
            } else {
                url = root
            }
            scoped = granted
        } catch {
            if granted { root.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
    deinit { if scoped { scopeURL.stopAccessingSecurityScopedResource() } }
}
