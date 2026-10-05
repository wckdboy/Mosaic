import Foundation
import Observation
import Photos

// Main-actor source of truth. Media bytes, directory traversal, decoding, and disk
// writes are delegated to actors so browsing can remain responsive.
@MainActor @Observable
final class LibraryStore {
    private(set) var photos: [MediaItem] = [] { didSet { rebuildItems() } }
    private(set) var archive = LibraryArchive() {
        didSet {
            // Favorites, positions, and collections change often and never affect items.
            if oldValue.files != archive.files || oldValue.displayNames != archive.displayNames {
                rebuildItems()
            }
        }
    }
    private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var isLoading = false
    private(set) var isImporting = false
    private(set) var isReady = false
    private(set) var scanningFolders = false
    private(set) var organizingFiles = false
    var canUndoFileOrganization: Bool { !(archive.fileOrganizationUndo ?? []).isEmpty }
    var folders: [FolderConnection] { archive.folders ?? [] }
    private(set) var indexing = false
    private(set) var indexedCount = 0
    private var indexTask: Task<Void, Never>?
    var recognizedText: [String: String] { archive.recognizedText ?? [:] }
    var message: String?
    var storageFailed = false
    private let repository: ArchiveRepository
    private let isolated: Bool
    private var changeObserver: PhotoChanges?
    private var saveTask: Task<Void, Never>?
    // Stored rather than computed: views read this on every render, and rebuilding
    // a large library array per body evaluation is measurable during scrolling.
    private(set) var items: [MediaItem] = []
    private func rebuildItems() {
        let source = photos + archive.files
        guard let names = archive.displayNames, !names.isEmpty else {
            items = source
            return
        }
        items = source.map { item in
            guard let name = names[item.id] else { return item }
            var presented = item
            presented.originalName = item.name
            presented.name = name
            return presented
        }
    }
    var canUndoOrganization: Bool { archive.organizationUndo != nil }
    var favorites: Set<String> { archive.favorites }
    var collections: [MediaCollection] { archive.collections }
    var hasPhotoAccess: Bool { authorization == .authorized || authorization == .limited }

    init(repository: ArchiveRepository = ArchiveRepository(), isolated: Bool = false) {
        self.repository = repository
        self.isolated = isolated
    }

    // Restore metadata before allowing mutations; otherwise a fast tap could be lost.
    func start() async {
        guard !isReady else { return }
        do { archive = try await repository.load() } catch {
            storageFailed = true
            message =
                "Your saved library could not be read. It has been left untouched. \(error.localizedDescription)"
        }
        if isolated {
            isReady = true
            return
        }
        changeObserver = PhotoChanges { [weak self] in Task { @MainActor in await self?.refreshPhotos() } }
        if let changeObserver { PHPhotoLibrary.shared().register(changeObserver) }
        await recoverFileMove()
        isReady = true
        await refreshPhotos()
        await refreshFolders()
    }

    func connectPhotos() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await refreshPhotos()
    }

    func refreshPhotos() async {
        guard !isolated else { return }
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard hasPhotoAccess, !isLoading else {
            if !hasPhotoAccess { photos = [] }
            return
        }
        isLoading = true
        photos = await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: options)
            var result: [MediaItem] = []
            result.reserveCapacity(assets.count)
            assets.enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image || asset.mediaType == .video else { return }
                let resource = PHAssetResource.assetResources(for: asset).first
                let name = resource?.originalFilename ?? "Untitled"
                let kind: MediaItem.Kind =
                    asset.mediaType == .video
                    ? .video
                    : asset.mediaSubtypes.contains(.photoLive)
                        ? .livePhoto : MediaItem.kind(for: URL(fileURLWithPath: name)) ?? .photo
                result.append(
                    MediaItem(
                        id: "photos:\(asset.localIdentifier)", name: name, kind: kind,
                        date: asset.creationDate ?? .distantPast, duration: asset.duration,
                        width: asset.pixelWidth, height: asset.pixelHeight, modified: asset.modificationDate))
            }
            return result
        }.value
        isLoading = false
    }

    func openFiles(_ urls: [URL]) async {
        guard !isImporting, !organizingFiles else { return }
        isImporting = true
        let result = await Task.detached(priority: .userInitiated) { () -> ([MediaItem], [String]) in
            var files: [MediaItem] = []
            var failures: [String] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard let kind = MediaItem.kind(for: url) else {
                        failures.append(url.lastPathComponent)
                        continue
                    }
                    let bookmark = try url.bookmarkData(
                        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    let values = try url.resourceValues(forKeys: [
                        .creationDateKey, .contentModificationDateKey, .isRegularFileKey,
                    ])
                    guard values.isRegularFile == true else {
                        failures.append(url.lastPathComponent)
                        continue
                    }
                    files.append(
                        MediaItem(
                            id: "file:\(url.standardizedFileURL.path)", name: url.lastPathComponent,
                            kind: kind, date: values.creationDate ?? Date(), bookmark: bookmark, fileURL: url,
                            modified: values.contentModificationDate))
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            return (files, failures)
        }.value
        for item in result.0 {
            if let index = archive.files.firstIndex(where: { $0.id == item.id }) {
                archive.files[index] = item
            } else {
                archive.files.append(item)
            }
        }
        persist()
        if !result.1.isEmpty { message = "Could not open: " + result.1.joined(separator: ", ") }
        isImporting = false
    }

    func connectFolder(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            if archive.folders == nil { archive.folders = [] }
            // Resolve existing bookmarks to avoid indexing the same root twice.
            let alreadyConnected = folders.contains { folder in
                var stale = false
                return
                    (try? URL(
                        resolvingBookmarkData: folder.bookmark, options: .withoutUI,
                        bookmarkDataIsStale: &stale))?.standardizedFileURL == url.standardizedFileURL
            }
            guard !alreadyConnected else { return }
            archive.folders?.append(FolderConnection(name: url.lastPathComponent, bookmark: bookmark))
            persist()
            await refreshFolders()
        } catch { message = "Could not connect this folder. \(error.localizedDescription)" }
    }

    // Called at startup, foreground entry, pull-to-refresh, and manual refresh.
    // Directory listing reads metadata only; thumbnails remain lazy and on demand.
    func refreshFolders() async {
        guard !isolated else { return }
        guard !scanningFolders, !organizingFiles, archive.pendingFileMove == nil, !folders.isEmpty else {
            return
        }
        scanningFolders = true
        defer { scanningFolders = false }
        for folder in folders {
            do {
                let result = try await FolderScanner.shared.scan(folder)
                guard folders.contains(where: { $0.id == folder.id }) else { continue }
                if !result.incomplete { archive.files.removeAll { $0.folderID == folder.id } }
                var known = Set(archive.files.map(\.id))
                for item in result.items where !known.contains(item.id) {
                    archive.files.append(item)
                    known.insert(item.id)
                }
                if result.incomplete {
                    message =
                        "Some items in \(folder.name) could not be read. Reconnect the provider and refresh."
                }
            } catch { message = "\(folder.name) is unavailable. Its previous index is preserved." }
        }
        persist()
    }
    func disconnectFolder(_ folder: FolderConnection) {
        guard !organizingFiles else { return }
        archive.folders?.removeAll { $0.id == folder.id }
        archive.files.removeAll { $0.folderID == folder.id }
        persist()
    }

    // One archive mutation commits names and collection memberships together. The
    // persisted inverse stores only changes made by this batch, preserving existing
    // collection memberships when the user undoes it later.
    func applyOrganization(_ changes: [OrganizationChange]) {
        guard !changes.isEmpty, !storageFailed else { return }
        let available = Set(items.map(\.id))
        let changes = changes.filter { available.contains($0.id) }
        let ids = Set(changes.map(\.id))
        let previous = (archive.displayNames ?? [:]).filter { ids.contains($0.key) }
        var added: [UUID: Set<String>] = [:]
        var created: Set<UUID> = []
        var collectionIndex: [String: Int] = [:]
        for index in archive.collections.indices {
            let key = archive.collections[index].name.lowercased()
            if collectionIndex[key] == nil { collectionIndex[key] = index }
        }
        if archive.displayNames == nil { archive.displayNames = [:] }
        for change in changes {
            archive.displayNames?[change.id] = change.name
            guard let destination = change.collection else { continue }
            let index: Int
            if let existing = collectionIndex[destination.lowercased()] {
                index = existing
            } else {
                archive.collections.append(MediaCollection(name: destination))
                index = archive.collections.count - 1
                created.insert(archive.collections[index].id)
                collectionIndex[destination.lowercased()] = index
            }
            if !archive.collections[index].itemIDs.contains(change.id) {
                archive.collections[index].itemIDs.insert(change.id)
                added[archive.collections[index].id, default: []].insert(change.id)
            }
        }
        archive.organizationUndo = OrganizationUndo(
            itemIDs: ids, previousNames: previous,
            addedMemberships: added, createdCollections: created)
        persist()
    }
    func undoOrganization() {
        guard let undo = archive.organizationUndo else { return }
        for id in undo.itemIDs { archive.displayNames?.removeValue(forKey: id) }
        archive.displayNames?.merge(undo.previousNames) { _, old in old }
        for index in archive.collections.indices {
            archive.collections[index].itemIDs.subtract(
                undo.addedMemberships[archive.collections[index].id] ?? [])
        }
        archive.collections.removeAll { undo.createdCollections.contains($0.id) && $0.itemIDs.isEmpty }
        archive.organizationUndo = nil
        persist()
    }

    // Persist the intent before touching a provider, then checkpoint each result.
    // This bounds crash recovery to one move and keeps successful partial batches undoable.
    func moveOriginals(_ moves: [FileMoveRecord], undoing: Bool = false) async -> (Int, [String]) {
        guard !organizingFiles, !scanningFolders, !storageFailed, archive.pendingFileMove == nil else {
            return (0, ["A scan or another file operation is in progress. Try again shortly."])
        }
        organizingFiles = true
        defer { organizingFiles = false }
        var completed = 0
        var failures: [String] = []
        await flush()
        if !undoing { archive.fileOrganizationUndo = [] }
        archive.organizationUndo = nil
        for move in moves {
            guard !Task.isCancelled else { break }
            archive.pendingFileMove = PendingFileMove(move: move, undoing: undoing)
            do { try await repository.save(archive) } catch {
                failures.append("Could not save the move journal. Originals were left in place.")
                archive.pendingFileMove = nil
                break
            }
            do {
                try await FileOrganizationService.shared.move(move)
                remapFile(move)
                finishFileMove(move, undoing: undoing)
                completed += 1
            } catch { failures.append("\(move.before.name): \(error.localizedDescription)") }
            archive.pendingFileMove = nil
            do { try await repository.save(archive) } catch {
                failures.append(
                    "The file result could not be saved. Reopen Mosaic to recover the move journal.")
                // Preserve the in-memory journal too, blocking additional moves until recovery.
                archive.pendingFileMove = PendingFileMove(move: move, undoing: undoing)
                break
            }
        }
        return (completed, failures)
    }
    func undoFileOrganization() async -> (Int, [String]) {
        await moveOriginals((archive.fileOrganizationUndo ?? []).reversed().map(\.reversed), undoing: true)
    }
    private func finishFileMove(_ move: FileMoveRecord, undoing: Bool) {
        if undoing {
            archive.fileOrganizationUndo?.removeAll { $0.after.id == move.before.id }
        } else {
            if archive.fileOrganizationUndo == nil { archive.fileOrganizationUndo = [] }
            if archive.fileOrganizationUndo?.contains(where: { $0.id == move.id }) != true {
                archive.fileOrganizationUndo?.append(move)
            }
        }
    }
    func retryFileRecovery() async { await recoverFileMove() }
    private func recoverFileMove() async {
        guard let pending = archive.pendingFileMove else { return }
        do {
            switch try await FileOrganizationService.shared.recovery(pending.move) {
            case .moved:
                remapFile(pending.move)
                finishFileMove(pending.move, undoing: pending.undoing)
            case .unchanged: break
            case .ambiguous:
                message =
                    "An interrupted file move needs attention. Both paths, or neither path, exist. Reconnect the folder and inspect it in Files before organizing again."
                return
            }
            archive.pendingFileMove = nil
            try await repository.save(archive)
        } catch {
            archive.pendingFileMove = pending
            message =
                "Reconnect the folder to recover an interrupted file move. \(error.localizedDescription)"
        }
    }
    private func remapFile(_ move: FileMoveRecord) {
        let old = move.before.id
        let new = move.after.id
        archive.files.removeAll { $0.id == old || $0.id == new }
        var source = move.after
        source.name = source.originalName ?? source.name
        source.originalName = nil
        archive.files.append(source)
        if archive.favorites.remove(old) != nil { archive.favorites.insert(new) }
        for index in archive.collections.indices {
            if archive.collections[index].itemIDs.remove(old) != nil {
                archive.collections[index].itemIDs.insert(new)
            }
        }
        if let value = archive.playbackPositions.removeValue(forKey: old) {
            archive.playbackPositions[new] = value
        }
        if let value = archive.recognizedText?.removeValue(forKey: old) {
            archive.recognizedText?[new] = value
        }
        // A real rename becomes the visible name; Undo restores the prior override.
        archive.displayNames?.removeValue(forKey: old)
        archive.displayNames?.removeValue(forKey: new)
        if move.after.originalName != nil { archive.displayNames?[new] = move.after.name }
    }

    func toggleFavorite(_ id: String) {
        if archive.favorites.contains(id) {
            archive.favorites.remove(id)
        } else {
            archive.favorites.insert(id)
        }
        persist()
    }
    func createCollection(_ name: String, items: Set<String> = []) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        archive.collections.append(MediaCollection(name: cleaned, itemIDs: items))
        persist()
    }
    func add(_ ids: Set<String>, to collection: MediaCollection) {
        guard let index = archive.collections.firstIndex(where: { $0.id == collection.id }) else { return }
        archive.collections[index].itemIDs.formUnion(ids)
        persist()
    }
    func remove(_ ids: Set<String>, from collection: MediaCollection) {
        guard let index = archive.collections.firstIndex(where: { $0.id == collection.id }) else { return }
        archive.collections[index].itemIDs.subtract(ids)
        persist()
    }
    func deleteCollection(_ collection: MediaCollection) {
        archive.collections.removeAll { $0.id == collection.id }
        persist()
    }
    func forgetFile(_ item: MediaItem) {
        archive.files.removeAll { $0.id == item.id }
        archive.favorites.remove(item.id)
        archive.playbackPositions.removeValue(forKey: item.id)
        archive.recognizedText?.removeValue(forKey: item.id)
        archive.displayNames?.removeValue(forKey: item.id)
        for index in archive.collections.indices { archive.collections[index].itemIDs.remove(item.id) }
        persist()
    }
    func rememberPosition(_ seconds: Double, for id: String) {
        guard seconds.isFinite, seconds >= 0 else { return }
        archive.playbackPositions[id] = seconds
        persist()
    }
    func position(for id: String) -> Double { archive.playbackPositions[id] ?? 0 }

    // A foreground batch is bounded to 500 previously unindexed Photos items. Files
    // providers may download on read, so cloud-backed Files are deliberately excluded.
    func indexPhotoText() {
        guard !indexing else { return }
        let pending = photos.filter { $0.kind != .video && recognizedText[$0.id] == nil }.prefix(500)
        indexing = true
        indexedCount = 0
        indexTask = Task {
            for item in pending {
                guard !Task.isCancelled else { break }
                if let text = await TextRecognitionService.shared.text(in: item), !Task.isCancelled {
                    if archive.recognizedText == nil { archive.recognizedText = [:] }
                    archive.recognizedText?[item.id] = text
                    indexedCount += 1
                }
            }
            persist()
            indexing = false
        }
    }
    func stopIndexing() { indexTask?.cancel() }
    func clearTextIndex() {
        indexTask?.cancel()
        archive.recognizedText = [:]
        persist()
    }
    func flush() async { await saveTask?.value }

    private func persist() {
        // File operations checkpoint the same archive directly after each move.
        guard !storageFailed, !organizingFiles else { return }
        let snapshot = archive
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            do { try await repository.save(snapshot) } catch {
                message = "Changes could not be saved. \(error.localizedDescription)"
            }
        }
    }
}

private final class PhotoChanges: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let changed: @Sendable () -> Void
    init(changed: @escaping @Sendable () -> Void) { self.changed = changed }
    func photoLibraryDidChange(_ changeInstance: PHChange) { changed() }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
}
