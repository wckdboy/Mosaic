import Foundation
import Testing

@testable import Mosaic

// Intercepts test requests locally. It intentionally omits Content-Length so the
// implementation must enforce its budget on actual received chunks.
final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let count = request.url!.path == "/large" ? 8 : 1
        for _ in 0..<count { client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct HardeningTests {
    private func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral
        value.protocolClasses = [FixtureURLProtocol.self]
        return value
    }
    @Test func streamedLimitRejectsUnknownLengthAndRemovesPartialFile() async throws {
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let request = URLRequest(url: URL(string: "https://fixture.invalid/large")!)
        await #expect(throws: (any Error).self) {
            _ = try await BoundedTransfer.read(request, limit: 16, to: file, configuration: configuration())
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
    @Test func boundedSmallResponseIsDelivered() async throws {
        let request = URLRequest(url: URL(string: "https://fixture.invalid/small")!)
        let data = try await BoundedTransfer.read(request, limit: 8, configuration: configuration())
        #expect(data == Data(repeating: 65, count: 8))
    }
    @Test func responseBudgetRejectsOverflowAndNegativeSizes() {
        #expect(!BoundedTransfer.fits(received: Int.max, incoming: 1, limit: Int.max))
        #expect(!BoundedTransfer.fits(received: 0, incoming: -1, limit: 100))
        #expect(BoundedTransfer.fits(received: 60, incoming: 40, limit: 100))
    }
    @Test func listingsRejectNestedRootsAndExcessiveNesting() {
        #expect(throws: (any Error).self) {
            try S3ListingParser.parse(Data("<wrong><ListBucketResult/></wrong>".utf8))
        }
        let deep =
            "<ListBucketResult>" + String(repeating: "<x>", count: 30) + String(repeating: "</x>", count: 30)
            + "</ListBucketResult>"
        #expect(throws: (any Error).self) { try S3ListingParser.parse(Data(deep.utf8)) }
        let large =
            "<ListBucketResult><Contents><Key>" + String(repeating: "x", count: 70000)
            + "</Key></Contents></ListBucketResult>"
        #expect(throws: (any Error).self) { try S3ListingParser.parse(Data(large.utf8)) }
    }
    @Test func fileReadsRejectSymlinkEscape() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let outside = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: outside.appending(path: "private.jpg"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "escape"), withDestinationURL: outside)
        let bookmark = try root.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let item = MediaItem(
            id: "escape", name: "private.jpg", kind: .photo, date: .distantPast, bookmark: bookmark,
            relativePath: "escape/private.jpg")
        #expect(throws: (any Error).self) { try FileAccess(item: item) }
    }
    @Test @MainActor func cancelledLoadCannotOverwriteNewViewerState() async {
        let loader = MediaLoader()
        let unavailable = MediaItem(id: "bad", name: "bad.jpg", kind: .photo, date: .distantPast)
        let task = Task { await loader.load(unavailable, position: 0, autoplay: false) }
        await Task.yield()
        task.cancel()
        loader.stop()
        await task.value
        #expect(loader.error == nil)
        #expect(loader.player == nil)
    }
}
