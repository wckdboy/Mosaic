import CoreGraphics
import Foundation
import Testing

@testable import Mosaic

// These tests exercise file safety and interoperability, using only temporary data
// and AWS's deliberately public example keys. They never contact a cloud service.
struct MediaModelTests {
    @Test(arguments: ["jpg", "jpeg", "png", "heic", "tiff", "bmp", "webp", "dng"])
    func imageFormats(_ ext: String) {
        #expect(MediaItem.kind(for: URL(fileURLWithPath: "sample.\(ext)")) == .photo)
    }

    @Test(arguments: ["mp4", "mov", "m4v", "mkv", "webm", "avi", "mts"])
    func videoContainers(_ ext: String) {
        #expect(MediaItem.kind(for: URL(fileURLWithPath: "sample.\(ext)")) == .video)
    }

    @Test func animationAndUnknown() {
        #expect(MediaItem.kind(for: URL(fileURLWithPath: "motion.GIF")) == .animated)
        #expect(MediaItem.kind(for: URL(fileURLWithPath: "motion.apng")) == .animated)
        #expect(MediaItem.kind(for: URL(fileURLWithPath: "notes.txt")) == nil)
    }
    @Test func invalidDurationsAreSafe() {
        #expect(MediaItem.timeLabel(.nan) == "0:00")
        #expect(MediaItem.timeLabel(.infinity) == "0:00")
        #expect(MediaItem.timeLabel(-3) == "0:00")
        #expect(MediaItem.timeLabel(3661) == "1:01:01")
    }
    @Test func naturalNameOrdering() {
        let items = ["image10.jpg", "image2.jpg", "image1.jpg"].map {
            MediaItem(id: $0, name: $0, kind: .photo, date: .distantPast)
        }
        #expect(MediaSort.name.sorted(items).map(\.name) == ["image1.jpg", "image2.jpg", "image10.jpg"])
    }
}

struct ArchiveTests {
    @Test func missingArchiveStartsEmpty() async throws {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "library.json")
        let archive = try await ArchiveRepository(url: url).load()
        #expect(archive.files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func roundTripAndReplacement() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = ArchiveRepository(url: folder.appending(path: "library.json"))
        var archive = LibraryArchive()
        archive.files = [
            MediaItem(
                id: "file:test", name: "image.gif", kind: .animated, date: .distantPast,
                bookmark: Data([1, 2, 3]))
        ]
        archive.favorites = ["file:test"]
        archive.collections = [MediaCollection(name: "Weekend", itemIDs: ["file:test"])]
        archive.playbackPositions = ["file:test": 42.5]
        try await repository.save(archive)
        let loaded = try await repository.load()
        #expect(loaded.files == archive.files)
        #expect(loaded.favorites == archive.favorites)
        #expect(loaded.collections == archive.collections)
        #expect(loaded.playbackPositions == archive.playbackPositions)
        try await repository.save(LibraryArchive())
        #expect(try await repository.load().files.isEmpty)
    }
    @Test func corruptArchiveIsNotOverwritten() async throws {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("broken json".utf8)
        try original.write(to: url)
        await #expect(throws: (any Error).self) { try await ArchiveRepository(url: url).load() }
        #expect(try Data(contentsOf: url) == original)
    }
    @Test func missingFileReferenceFails() {
        let item = MediaItem(id: "missing", name: "missing.jpg", kind: .photo, date: .distantPast)
        #expect(throws: (any Error).self) { try FileAccess(item: item) }
    }
}

struct S3Tests {
    // Canonical AWS vector: https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sigv4-query-string-auth.html
    @Test func matchesPublishedAWSSignature() throws {
        let connection = S3Connection(
            name: "Example", endpoint: "https://s3.amazonaws.com", bucket: "examplebucket",
            region: "us-east-1", pathStyle: false)
        let credentials = S3Credentials(
            accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        let date = try #require(ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z"))
        let url = try S3Signer.url(
            connection: connection, credentials: credentials, key: "test.txt", date: date, expires: 86400)
        #expect(url.host == "examplebucket.s3.amazonaws.com")
        #expect(
            url.absoluteString.hasSuffix(
                "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"))
    }
    @Test func encodingPreservesKeys() {
        #expect(S3Signer.encode("a b+c/æ.jpg") == "a%20b%2Bc%2F%C3%A6.jpg")
        #expect(S3Signer.encode("a b+c/æ.jpg", preserveSlash: true) == "a%20b%2Bc/%C3%A6.jpg")
        #expect(S3Signer.encode("100%.jpg") == "100%25.jpg")
    }
    @Test(arguments: [
        "http://storage.example.com", "https://user:pass@storage.example.com",
        "https://storage.example.com/path", "https://storage.example.com?secret=value",
    ])
    func rejectsInvalidEndpoints(_ endpoint: String) {
        let connection = S3Connection(name: "Test", endpoint: endpoint, bucket: "media", region: "us-east-1")
        #expect(throws: (any Error).self) {
            try S3Signer.url(
                connection: connection, credentials: S3Credentials(accessKey: "test", secretKey: "test"))
        }
    }
    @Test func pathStyleAndSessionToken() throws {
        let connection = S3Connection(
            name: "Test", endpoint: "https://storage.example.com:9443", bucket: "media", region: "auto")
        let url = try S3Signer.url(
            connection: connection,
            credentials: S3Credentials(accessKey: "test", secretKey: "test", sessionToken: "a+b/="),
            key: "photos/a b.jpg")
        #expect(url.absoluteString.contains("/media/photos/a%20b.jpg?"))
        #expect(url.absoluteString.contains("X-Amz-Security-Token=a%2Bb%2F%3D"))
        #expect(!url.absoluteString.contains("secretKey"))
    }
    @Test func parsesFoldersEscapedNamesAndPagination() throws {
        let xml = """
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <Contents><Key>photos/a &amp; b.jpg</Key><LastModified>2026-01-01T12:00:00.000Z</LastModified><Size>2048</Size></Contents>
              <Contents><Key>photos/</Key><Size>0</Size></Contents>
              <CommonPrefixes><Prefix>photos/trip/</Prefix></CommonPrefixes>
              <NextContinuationToken>token+/=</NextContinuationToken>
            </ListBucketResult>
            """
        let page = try S3ListingParser.parse(Data(xml.utf8))
        #expect(page.objects.count == 1)
        #expect(page.objects.first?.key == "photos/a & b.jpg")
        #expect(page.objects.first?.size == 2048)
        #expect(page.objects.first?.modified != .distantPast)
        #expect(page.folders == ["photos/trip/"])
        #expect(page.nextToken == "token+/=")
    }
    @Test func rejectsInvalidListings() {
        #expect(throws: (any Error).self) {
            try S3ListingParser.parse(Data("<Error><Message>Denied</Message></Error>".utf8))
        }
        #expect(throws: (any Error).self) { try S3ListingParser.parse(Data("not xml".utf8)) }
    }
}

struct SubtitleTests {
    @Test func parsesSRTAndStripsMarkup() {
        let cues = SubtitleCue.parse(
            "1\r\n00:00:01,250 --> 00:00:03,500\r\n<i>Hello</i>\r\nworld\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\nAgain"
        )
        #expect(cues.count == 2)
        #expect(cues.first == SubtitleCue(start: 1.25, end: 3.5, text: "Hello\nworld"))
    }
    @Test func parsesWebVTTAndRejectsInvalidCues() {
        let source =
            "WEBVTT\n\n00:01.000 --> 00:02.000 align:start\nCaption\n\n00:08.000 --> 00:04.000\nInvalid"
        #expect(SubtitleCue.parse(source) == [SubtitleCue(start: 1, end: 2, text: "Caption")])
        #expect(SubtitleCue.timestamp("00:99:01") == nil)
        #expect(SubtitleCue.timestamp("-01:02") == nil)
        #expect(SubtitleCue.timestamp("nonsense") == nil)
    }
}

struct FolderDiscoveryTests {
    @Test func discoversNestedMediaAndIgnoresOtherFiles() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: "Downloads/strange/deep/folder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["clip.mp4", "image.jpg", "animation.gif", "notes.txt"] {
            try Data().write(to: nested.appending(path: name))
        }
        let bookmark = try root.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let connection = FolderConnection(name: "Test", bookmark: bookmark)
        let result = try await FolderScanner.shared.scan(connection)
        #expect(!result.incomplete)
        #expect(Set(result.items.map(\.name)) == ["clip.mp4", "image.jpg", "animation.gif"])
        #expect(result.items.allSatisfy { $0.folderID == connection.id })
        let item = try #require(result.items.first)
        let access = try FileAccess(item: item)
        #expect(FileManager.default.fileExists(atPath: access.url.path))
        #expect(access.url.lastPathComponent == item.name)
    }
    @Test func rejectsTraversalOutsideGrantedFolder() throws {
        let root = URL.temporaryDirectory
        let bookmark = try root.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let item = MediaItem(
            id: "bad", name: "bad.jpg", kind: .photo, date: .distantPast, bookmark: bookmark,
            relativePath: "../bad.jpg")
        #expect(throws: (any Error).self) { try FileAccess(item: item) }
    }
}

struct MosaicGroupingTests {
    private func media(_ id: String, _ name: String) -> MediaItem {
        MediaItem(id: id, name: name, kind: .photo, date: .distantPast)
    }
    @Test func nameGroupingKeepsEveryItem() {
        let items = [media("1", "Trip_001.jpg"), media("2", "Trip-002.jpg"), media("3", "Receipt3.png")]
        let groups = MosaicClusterBuilder.clusters(
            items: items, mode: .name, descriptors: [:], sentiments: [:])
        #expect(groups.first(where: { $0.title == "Trip" })?.items.count == 2)
        #expect(groups.flatMap(\.items).count == items.count)
    }
    @Test func missingAnalysisRemainsVisible() {
        let items = [media("1", "a.jpg"), media("2", "b.jpg")]
        let groups = MosaicClusterBuilder.clusters(
            items: items, mode: .color, descriptors: ["1": VisualDescriptor(color: "Blue", hash: 0)],
            sentiments: [:])
        #expect(groups.last?.title == "Not analyzed")
        #expect(groups.flatMap(\.items).count == 2)
    }
    @Test func nearHashesClusterTogether() {
        let items = [media("1", "a.jpg"), media("2", "b.jpg"), media("3", "c.jpg")]
        let values = [
            "1": VisualDescriptor(color: "Blue", hash: 0), "2": VisualDescriptor(color: "Blue", hash: 3),
            "3": VisualDescriptor(color: "Red", hash: UInt64.max),
        ]
        let groups = MosaicClusterBuilder.clusters(
            items: items, mode: .similar, descriptors: values, sentiments: [:])
        #expect(groups.count == 2)
        #expect(groups.first?.items.count == 2)
    }
    @Test @MainActor func canvasOnlyReturnsVisibleTiles() {
        let layout = MosaicCanvasLayout()
        layout.clusters = [
            MosaicCluster(
                id: "test", title: "Test", items: (0..<10000).map { media(String($0), "image\($0).jpg") })
        ]
        layout.prepare()
        let visible =
            layout.layoutAttributesForElements(in: CGRect(x: 0, y: 0, width: 400, height: 800)) ?? []
        #expect(visible.count < 50)
        // The world is two-dimensional: roughly square rather than one tall column.
        let size = layout.collectionViewContentSize
        #expect(size.width > 8000 && size.height > 8000)
        #expect(max(size.width, size.height) / min(size.width, size.height) < 1.6)
    }
}

struct BoundaryTests {
    @Test func rejectsMalformedTimeComponents() {
        #expect(SubtitleCue.timestamp("oops:01:02") == nil)
        #expect(SubtitleCue.timestamp("01::02") == nil)
        #expect(MediaItem.timeLabel(Double.greatestFiniteMagnitude) == "0:00")
    }
    @Test func olderArchivesLoadWithoutOptionalFeatures() throws {
        let json = Data("{\"files\":[],\"favorites\":[],\"collections\":[],\"playbackPositions\":{}}".utf8)
        let archive = try JSONDecoder().decode(LibraryArchive.self, from: json)
        #expect(archive.folders == nil)
        #expect(archive.recognizedText == nil)
    }
}

// Discovery must cross media types while respecting filters and never presenting
// an unindexed asset as a visual match merely because its filename is similar.
struct DiscoveryTests {
    private func item(_ id: String, _ name: String, _ kind: MediaItem.Kind = .photo) -> MediaItem {
        MediaItem(id: id, name: name, kind: kind, date: .distantPast)
    }
    @Test func visualResultsExcludeSeedAndRankAcrossKinds() {
        let seed = item("seed", "sunset.jpg")
        let video = item("video", "movie.mp4", .video)
        let gif = item("gif", "loop.gif", .animated)
        let far = item("far", "unrelated.jpg")
        let descriptors = [
            "seed": VisualDescriptor(color: "Red", hash: 0),
            "video": VisualDescriptor(color: "Red", hash: 1),
            "gif": VisualDescriptor(color: "Red", hash: 7),
            "far": VisualDescriptor(color: "Blue", hash: .max),
        ]
        let matches = MosaicSimilarity.matches(
            seed: seed, items: [gif, far, seed, video], mode: .similar, descriptors: descriptors)
        #expect(matches.map(\.id) == ["video", "gif"])
    }
    @Test func unindexedSeedFallsBackToNamesOnly() {
        let seed = item("seed", "Trip_001.jpg")
        let related = item("related", "Trip_002.mov", .video)
        let other = item("other", "Receipt.jpg")
        #expect(
            MosaicSimilarity.matches(
                seed: seed, items: [seed, related, other], mode: .similar, descriptors: [:]
            ).map(\.id) == ["related"])
        #expect(
            MosaicSimilarity.matches(
                seed: seed, items: [related], mode: .similar,
                descriptors: ["seed": VisualDescriptor(color: "Blue", hash: 0)]
            ).isEmpty)
    }
    @Test func metadataFiltersCombineWithoutMediaReads() {
        let photo = item("photos:1", "Trip.mov", .video)
        let file = item("file:1", "Trip.mov", .video)
        let filter = MosaicFilter(query: "trip ocean", kind: .video, favoritesOnly: true, source: .photos)
        #expect(filter.matches(photo, favorites: [photo.id], text: [photo.id: "Ocean waves"]))
        #expect(!filter.matches(file, favorites: [file.id], text: [file.id: "Ocean waves"]))
        #expect(!filter.matches(photo, favorites: [], text: [photo.id: "Ocean waves"]))
        #expect(!filter.matches(photo, favorites: [photo.id], text: [:]))
    }
    @Test func colorAndSentimentRequireKnownMatchingDescriptors() {
        let seed = item("seed", "a.jpg")
        let match = item("match", "b.jpg")
        let unknown = item("unknown", "c.jpg")
        let items = [seed, match, unknown]
        #expect(
            MosaicSimilarity.matches(
                seed: seed, items: items, mode: .color,
                descriptors: [
                    "seed": VisualDescriptor(color: "Blue", hash: 0),
                    "match": VisualDescriptor(color: "Blue", hash: 1),
                ]
            ).map(\.id) == ["match"])
        #expect(
            MosaicSimilarity.matches(
                seed: seed, items: items, mode: .sentiment, descriptors: [:],
                sentiments: ["seed": "Positive", "match": "Positive"]
            ).map(\.id) == ["match"])
    }
}

struct OrganizationTests {
    @Test func namesPreserveExtensionsAndResolveCollisions() {
        let items = [
            MediaItem(id: "2", name: "b.JPG", kind: .photo, date: .distantPast),
            MediaItem(id: "1", name: "a.JPG", kind: .photo, date: .distantPast),
        ]
        let options = OrganizationOptions(rename: true, pattern: "Trip", grouping: .type)
        let plan = OrganizationPlanner.plan(
            items: items, options: options, descriptors: [:], reservedNames: ["trip.jpg"])
        #expect(plan.map(\.name) == ["Trip-2.JPG", "Trip-3.JPG"])
        #expect(plan.allSatisfy { $0.collection == "Photos" })
        #expect(items.first?.name == "b.JPG")
    }
    @Test func originalTokenDoesNotCompoundPreviousRenames() {
        let item = MediaItem(
            id: "1", name: "Renamed.jpg", originalName: "Source.jpg", kind: .photo, date: .distantPast)
        let options = OrganizationOptions(rename: true, pattern: "{original}_{sequence}", grouping: .month)
        let plan = OrganizationPlanner.plan(items: [item], options: options, descriptors: [:])
        #expect(plan.first?.name == "Source_0001.jpg")
        #expect(plan.first?.collection == "Undated")
        let physical = OrganizationPlanner.plan(
            items: [item], options: OrganizationOptions(moveOriginals: true, rename: false, grouping: .type),
            descriptors: [:])
        #expect(physical.first?.name == "Source.jpg")
        #expect(!OrganizationPlanner.validPattern("{unknown}"))
        #expect(!OrganizationPlanner.validPattern("   "))
    }
    @Test func folderOnlyPlansKeepNamesAndUseUnknownColorBucket() {
        let item = MediaItem(id: "1", name: "loop.gif", kind: .animated, date: .distantPast)
        let plan = OrganizationPlanner.plan(
            items: [item], options: OrganizationOptions(rename: false, grouping: .color), descriptors: [:])
        #expect(plan.first?.name == item.name)
        #expect(plan.first?.collection == "Unsorted")
    }
    @Test @MainActor func organizationUndoSurvivesReloadAndPreservesManualMemberships() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ArchiveRepository(url: directory.appending(path: "library.json"))
        let a = MediaItem(id: "file:a", name: "a.jpg", kind: .photo, date: .distantPast)
        let b = MediaItem(id: "file:b", name: "b.jpg", kind: .photo, date: .distantPast)
        var archive = LibraryArchive()
        archive.files = [a, b]
        archive.collections = [MediaCollection(name: "Photos", itemIDs: [b.id])]
        archive.displayNames = [a.id: "Earlier.jpg"]
        try await repository.save(archive)
        let store = LibraryStore(repository: repository)
        await store.start()
        let plan = OrganizationPlanner.plan(
            items: [a], options: OrganizationOptions(grouping: .type), descriptors: [:])
        store.applyOrganization(plan)
        await store.flush()
        let reloaded = LibraryStore(repository: repository)
        await reloaded.start()
        #expect(reloaded.canUndoOrganization)
        #expect(reloaded.collections.first?.itemIDs == [a.id, b.id])
        reloaded.undoOrganization()
        #expect(reloaded.items.first(where: { $0.id == a.id })?.name == "Earlier.jpg")
        #expect(reloaded.collections.first?.itemIDs == [b.id])
        #expect(!reloaded.canUndoOrganization)
        await reloaded.flush()
    }
}

struct FileOrganizationTests {
    private func fixture() throws -> (URL, MediaItem) {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appending(path: "Downloads"), withIntermediateDirectories: true)
        let url = root.appending(path: "Downloads/original.jpg")
        try Data("original bytes".utf8).write(to: url)
        let bookmark = try root.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = UUID()
        return (
            root,
            MediaItem(
                id: "folder:\(folder.uuidString):Downloads/original.jpg", name: "original.jpg", kind: .photo,
                date: .distantPast, bookmark: bookmark, fileURL: url, folderID: folder,
                relativePath: "Downloads/original.jpg")
        )
    }
    @Test func previewAvoidsExistingFilesAndSkipsPhotos() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Mosaic/Photos/new.jpg")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: destination)
        let photo = MediaItem(id: "photos:a", name: "a.jpg", kind: .photo, date: .distantPast)
        let result = await FileOrganizationService.shared.preview([
            OrganizationChange(item: item, name: "new.jpg", collection: "Photos"),
            OrganizationChange(item: photo, name: "new2.jpg", collection: "Photos"),
        ])
        #expect(result.moves.first?.after.relativePath == "Mosaic/Photos/new-2.jpg")
        #expect(result.skipped == 1)
        #expect(try Data(contentsOf: destination) == Data("existing".utf8))
    }
    @Test func moveAndReversePreserveBytes() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = await FileOrganizationService.shared.preview([
            OrganizationChange(item: item, name: "new.jpg", collection: "Photos")
        ])
        let move = try #require(preview.moves.first)
        try await FileOrganizationService.shared.move(move)
        #expect(!FileManager.default.fileExists(atPath: item.fileURL!.path))
        #expect(try Data(contentsOf: move.after.fileURL!) == Data("original bytes".utf8))
        try await FileOrganizationService.shared.move(move.reversed)
        #expect(try Data(contentsOf: item.fileURL!) == Data("original bytes".utf8))
    }
    @Test func raceCollisionNeverOverwrites() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = await FileOrganizationService.shared.preview([
            OrganizationChange(item: item, name: "new.jpg", collection: nil)
        ])
        let move = try #require(preview.moves.first)
        try Data("keep me".utf8).write(to: move.after.fileURL!)
        await #expect(throws: (any Error).self) { try await FileOrganizationService.shared.move(move) }
        #expect(try Data(contentsOf: item.fileURL!) == Data("original bytes".utf8))
        #expect(try Data(contentsOf: move.after.fileURL!) == Data("keep me".utf8))
    }
    @Test func rejectsSymlinkEscape() async throws {
        let (root, item) = try fixture()
        let outside = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "Mosaic"), withDestinationURL: outside)
        let result = await FileOrganizationService.shared.preview([
            OrganizationChange(item: item, name: "new.jpg", collection: "Photos")
        ])
        #expect(result.moves.isEmpty)
        #expect(result.issues.count == 1)
    }
    @Test @MainActor func fileMovesRemapOrganizationAndUndoAfterReload() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ArchiveRepository(url: root.appending(path: "archive.json"))
        var archive = LibraryArchive()
        archive.files = [item]
        archive.favorites = [item.id]
        archive.displayNames = [item.id: "Display.jpg"]
        archive.collections = [MediaCollection(name: "Keep", itemIDs: [item.id])]
        archive.playbackPositions = [item.id: 42]
        try await repository.save(archive)
        let store = LibraryStore(repository: repository)
        await store.start()
        let presented = try #require(store.items.first(where: { $0.id == item.id }))
        let preview = await FileOrganizationService.shared.preview([
            OrganizationChange(item: presented, name: "new.jpg", collection: "Photos")
        ])
        let move = try #require(preview.moves.first)
        let result = await store.moveOriginals(preview.moves)
        #expect(result.0 == 1 && result.1.isEmpty)
        #expect(store.favorites == [move.after.id])
        #expect(store.collections.first?.itemIDs == [move.after.id])
        #expect(store.position(for: move.after.id) == 42)
        let reloaded = LibraryStore(repository: repository)
        await reloaded.start()
        let undone = await reloaded.undoFileOrganization()
        #expect(undone.0 == 1 && undone.1.isEmpty)
        #expect(reloaded.favorites == [item.id])
        #expect(reloaded.items.first(where: { $0.id == item.id })?.name == "Display.jpg")
        #expect(try Data(contentsOf: item.fileURL!) == Data("original bytes".utf8))
    }
    @Test @MainActor func interruptedMoveRecoversBeforeScanning() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ArchiveRepository(url: root.appending(path: "archive.json"))
        let preview = await FileOrganizationService.shared.preview([
            OrganizationChange(item: item, name: "new.jpg", collection: nil)
        ])
        let move = try #require(preview.moves.first)
        var archive = LibraryArchive()
        archive.files = [item]
        archive.favorites = [item.id]
        archive.pendingFileMove = PendingFileMove(move: move, undoing: false)
        try await repository.save(archive)
        // Simulate process termination after moving bytes but before updating metadata.
        try await FileOrganizationService.shared.move(move)
        let store = LibraryStore(repository: repository)
        await store.start()
        #expect(store.archive.pendingFileMove == nil)
        #expect(store.favorites == [move.after.id])
        #expect(store.canUndoFileOrganization)
        #expect(store.archive.files.first?.id == move.after.id)
    }
}
