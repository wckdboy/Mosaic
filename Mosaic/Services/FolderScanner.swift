import Foundation
import ImageIO

// iOS grants access to user-selected directory trees, never the whole filesystem.
// Store one root bookmark per tree so descendants retain the same authorization.
struct FolderConnection: Identifiable, Codable, Sendable, Hashable {
    var id = UUID()
    let name: String
    let bookmark: Data
}

struct FolderScan: Sendable {
    var items: [MediaItem]
    var incomplete: Bool
}

actor FolderScanner {
    static let shared = FolderScanner()

    func scan(_ folder: FolderConnection) throws -> FolderScan {
        var stale = false
        let root = try URL(
            resolvingBookmarkData: folder.bookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey,
        ]
        // An error leaves the previous index intact instead of treating an offline
        // provider as an empty folder and removing the user's references.
        var incomplete = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    incomplete = true
                    return true
                })
        else { throw CocoaError(.fileReadNoPermission) }
        var items: [MediaItem] = []
        for case let url as URL in enumerator {
            if Task.isCancelled {
                incomplete = true
                break
            }
            guard let kind = MediaItem.kind(for: url) else { continue }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let rootPath =
                    root.standardizedFileURL.path.hasSuffix("/")
                    ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
                guard url.standardizedFileURL.path.hasPrefix(rootPath) else { continue }
                let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count))
                items.append(
                    MediaItem(
                        id: "folder:\(folder.id.uuidString):\(relative)", name: url.lastPathComponent,
                        kind: kind,
                        date: values.creationDate ?? values.contentModificationDate ?? .distantPast,
                        bookmark: folder.bookmark, fileURL: url, folderID: folder.id, relativePath: relative,
                        modified: values.contentModificationDate))
            } catch { incomplete = true }
        }
        return FolderScan(items: items, incomplete: incomplete)
    }
}
