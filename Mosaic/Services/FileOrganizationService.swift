import Foundation

// A durable journal records both references before a provider move starts. The
// store reconciles an interrupted move on launch before allowing another batch.
struct FileMoveRecord: Codable, Sendable, Identifiable {
    var id: String { before.id }
    let before: MediaItem
    let after: MediaItem
    var reversed: FileMoveRecord { FileMoveRecord(before: after, after: before) }
}
struct PendingFileMove: Codable, Sendable {
    let move: FileMoveRecord
    let undoing: Bool
}
struct FileMovePreview: Sendable {
    var moves: [FileMoveRecord] = []
    var issues: [String] = []
    var skipped = 0
}

actor FileOrganizationService {
    static let shared = FileOrganizationService()
    enum Recovery { case unchanged, moved, ambiguous }

    func preview(_ changes: [OrganizationChange]) -> FileMovePreview {
        var result = FileMovePreview()
        var reserved: Set<String> = []
        for change in changes {
            let item = change.item
            guard let folderID = item.folderID, let bookmark = item.bookmark, let relative = item.relativePath
            else {
                result.skipped += 1
                continue
            }
            do {
                let root = try Self.resolve(bookmark)
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                _ = try Self.confined(relative, root: root)
                let parent =
                    change.collection.map { "Mosaic/\(Self.safeComponent($0))" }
                    ?? (relative as NSString).deletingLastPathComponent
                let sourceExtension = (change.name as NSString).pathExtension
                let sourceStem = (change.name as NSString).deletingPathExtension
                let filename =
                    Self.safeComponent(sourceStem) + (sourceExtension.isEmpty ? "" : ".\(sourceExtension)")
                let stem = (filename as NSString).deletingPathExtension
                let ext = (filename as NSString).pathExtension
                let suffix = ext.isEmpty ? "" : ".\(ext)"
                var destination = parent.isEmpty ? filename : "\(parent)/\(filename)"
                var attempt = 2
                while destination != relative {
                    let url = try Self.confined(destination, root: root)
                    let key = "\(folderID):\(destination.lowercased())"
                    if !FileManager.default.fileExists(atPath: url.path) && !reserved.contains(key) { break }
                    let name = "\(stem)-\(attempt)\(suffix)"
                    destination = parent.isEmpty ? name : "\(parent)/\(name)"
                    attempt += 1
                }
                guard destination != relative else { continue }
                reserved.insert("\(folderID):\(destination.lowercased())")
                var after = item
                after.id = "folder:\(folderID.uuidString):\(destination)"
                after.name = (destination as NSString).lastPathComponent
                after.originalName = nil
                after.relativePath = destination
                after.fileURL = try Self.confined(destination, root: root)
                result.moves.append(FileMoveRecord(before: item, after: after))
            } catch { result.issues.append("\(item.name): \(error.localizedDescription)") }
        }
        return result
    }

    // Refuse traversal and symlink escapes on both preview and commit. A provider
    // may reject writes; errors are reported individually and no destination is replaced.
    func move(_ record: FileMoveRecord) throws { try Self.performMove(record) }

    // NSFileCoordinator invokes its accessor synchronously. Keeping this operation
    // independent of actor state avoids transferring actor isolation into Foundation.
    private static func performMove(_ record: FileMoveRecord) throws {
        guard let bookmark = record.before.bookmark,
            let oldPath = record.before.relativePath, let newPath = record.after.relativePath,
            record.before.folderID != nil, record.before.folderID == record.after.folderID
        else { throw CocoaError(.fileWriteNoPermission) }
        let root = try Self.resolve(bookmark)
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let source = try Self.confined(oldPath, root: root)
        let destination = try Self.confined(newPath, root: root)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing, error: &coordinationError
        ) { from, to in
            do {
                // Validate again inside coordination and reject a changed source.
                guard from.standardizedFileURL == source.standardizedFileURL,
                    to.standardizedFileURL == destination.standardizedFileURL
                else { throw CocoaError(.fileWriteUnknown) }
                _ = try Self.confined(oldPath, root: root)
                _ = try Self.confined(newPath, root: root)
                let values = try from.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                if let expected = record.before.modified, let actual = values.contentModificationDate,
                    abs(expected.timeIntervalSince(actual)) > 0.001
                {
                    throw CocoaError(.fileReadUnknown)
                }
                guard !FileManager.default.fileExists(atPath: to.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try FileManager.default.createDirectory(
                    at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                coordinator.item(at: from, willMoveTo: to)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError { throw error }
    }
    func recovery(_ record: FileMoveRecord) throws -> Recovery {
        guard let bookmark = record.before.bookmark, let old = record.before.relativePath,
            let new = record.after.relativePath
        else { return .ambiguous }
        let root = try Self.resolve(bookmark)
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let source = FileManager.default.fileExists(atPath: try Self.confined(old, root: root).path)
        let destination = FileManager.default.fileExists(atPath: try Self.confined(new, root: root).path)
        if source && !destination { return .unchanged }
        if !source && destination { return .moved }
        return .ambiguous
    }
    private static func resolve(_ bookmark: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
    }
    static func confined(_ relative: String, root: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..")
        else { throw CocoaError(.fileReadInvalidFileName) }
        // resolvingSymlinksInPath may leave the whole path unresolved when its
        // leaf does not exist. Check every ancestor, including dangling links.
        var ancestor = root
        for component in relative.split(separator: "/") {
            ancestor.append(path: String(component))
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: ancestor.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw CocoaError(.fileWriteNoPermission)
                }
            } catch let error as CocoaError
                where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
            {
                // New destination directories are valid, but existing links are not.
            }
        }
        let url = root.appending(path: relative).standardizedFileURL
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(base) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return url
    }
    private static func safeComponent(_ value: String) -> String {
        let cleaned = value.components(
            separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        )
        .joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "Media" : String(cleaned.prefix(220))
    }
}
