import Foundation

// Swift surface for the Rust engine. The C ABI speaks JSON so layout, curation,
// and index schemas can evolve without fragile mirrored structs in a header. All
// payloads are small and local; media bytes never cross this boundary.
//
// The index is incremental: descriptors are projected once in Rust and stored as a
// compact signature, which keeps 50,000-photo libraries searchable in milliseconds.

struct MosaicCoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum MosaicCoreBridge {
    static let version: String = {
        guard let pointer = mosaic_core_version() else { return "unknown" }
        defer { mosaic_string_free(pointer) }
        return String(cString: pointer)
    }()

    static func collage(_ request: CoreCollageRequest) throws -> CoreCollageLayout {
        try call(request, function: mosaic_collage_layout)
    }

    static func book(_ request: CoreBookRequest) throws -> CoreBookPlan {
        try call(request, function: mosaic_book_plan)
    }

    private static func call<Request: Encodable, Response: Decodable>(
        _ request: Request,
        function: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    ) throws -> Response {
        let data = try encoder.encode(request)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MosaicCoreError(message: "Could not encode the engine request.")
        }
        let pointer = json.withCString { function($0) }
        return try decode(pointer, as: Response.self)
    }

    static func decode<Response: Decodable>(
        _ pointer: UnsafeMutablePointer<CChar>?, as type: Response.Type
    ) throws -> Response {
        guard let pointer else {
            throw MosaicCoreError(message: "The engine returned no response.")
        }
        defer { mosaic_string_free(pointer) }
        let data = Data(String(cString: pointer).utf8)
        let envelope: CoreEnvelope<Response>
        do {
            envelope = try decoder.decode(CoreEnvelope<Response>.self, from: data)
        } catch {
            throw MosaicCoreError(
                message: "The engine response could not be read. \(error.localizedDescription)")
        }
        guard envelope.ok, let result = envelope.result else {
            throw MosaicCoreError(message: envelope.error ?? "The engine could not complete this request.")
        }
        return result
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

private struct CoreEnvelope<Value: Decodable>: Decodable {
    let ok: Bool
    let error: String?
    let result: Value?
}

// MARK: - Collage

struct CoreLayoutItem: Codable, Sendable {
    var id: String
    var width: Int
    var height: Int
    var date: Double
    var favorite: Bool
    var quality: Double
}

struct CoreCollageRequest: Codable, Sendable {
    var count: Int
    var aspect: Double
    var style: String
    var seed: UInt64
    var spacing: Double
    var padding: Double
    var items: [CoreLayoutItem]
}

struct CoreCollageCell: Codable, Sendable, Identifiable {
    var id: String?
    var index: Int
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var rotation: Double
    var z: Int
    var role: String
    var focusX: Double
    var focusY: Double
}

struct CoreCollageLayout: Codable, Sendable {
    var style: String
    var aspect: Double
    var width: Double
    var height: Double
    var seed: UInt64
    var cells: [CoreCollageCell]
}

// MARK: - Photobook

struct CoreBookItem: Codable, Sendable {
    var id: String
    var date: Double
    var width: Int
    var height: Int
    var theme: String?
    var color: String
    var favorite: Bool
    var quality: Double
    var latitude: Double? = nil
    var longitude: Double? = nil
    var place: String? = nil
}

struct CoreBookRequest: Codable, Sendable {
    var items: [CoreBookItem]
    var pageAspect: Double
    var spread: Bool
    var style: String
    var seed: UInt64
    var includeCover: Bool
    var title: String
    var subtitle: String
    var maxPerPage: Int
    var spacing: Double
    var padding: Double
    var coverID: String? = nil
}

struct CoreBookCell: Codable, Sendable, Identifiable {
    var id: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var rotation: Double
    var z: Int
    var focusX: Double
    var focusY: Double
}

struct CoreBookPage: Codable, Sendable, Identifiable {
    var index: Int
    var kind: String
    var title: String
    var subtitle: String
    var eventIndex: Int?
    var startDate: Double?
    var endDate: Double?
    var layout: String
    var spreadIndex: Int
    var side: String
    var cells: [CoreBookCell]
    var id: Int { index }
}

struct CoreBookEvent: Codable, Sendable, Identifiable {
    var index: Int
    var title: String
    var startDate: Double
    var endDate: Double
    var itemCount: Int
    var pageStart: Int
    var pageCount: Int
    var place: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var id: Int { index }
}

struct CoreBookPlan: Codable, Sendable {
    var title: String
    var subtitle: String
    var pageAspect: Double
    var spread: Bool
    var seed: UInt64
    var pageCount: Int
    var photoCount: Int
    var events: [CoreBookEvent]
    var pages: [CoreBookPage]
}

// MARK: - Index

struct CoreIndexItem: Codable, Sendable {
    var id: String
    var name: String
    var date: Double
    var width: Int
    var height: Int
    var favorite: Bool
    var kind: String
    var color: String
    var theme: String?
    var labels: [String]
    var hash: String
    var feature: String?
    var meaning: String?
    var palette: [UInt32]
    var quality: Double
    var detailed: Bool
    var sourceModified: Double?
}

struct CoreUpsertResult: Codable, Sendable {
    var count: Int
    var added: Int
    var updated: Int
}

struct CoreQueryRequest: Codable, Sendable {
    var id: String?
    var feature: String?
    var meaning: String?
    var limit: Int
    var ids: [String]?
    var excludeIds: [String]
    var minSimilarity: Double
    var mode: String
    var kinds: [String]?
    var dateFrom: Double?
    var dateTo: Double?
    var projectionSeed: UInt64?
}

struct CoreQueryResult: Codable, Sendable, Identifiable {
    var id: String
    var similarity: Float
    var visual: Float?
    var semantic: Float?
}

struct CoreClusterRequest: Codable, Sendable {
    var mode: String
    var budget: Int
    var threshold: Double
    var ids: [String]?
}

struct CoreCluster: Codable, Sendable, Identifiable {
    var id: String
    var title: String
    var itemIds: [String]
}

struct CoreSelectRequest: Codable, Sendable {
    var count: Int
    var ids: [String]?
    var excludeIds: [String]
    var diversity: Double
    var includeFavorites: Bool
    var kinds: [String]?
    var minGapSeconds: Double
    var dateFrom: Double?
    var dateTo: Double?
    var seed: UInt64
    var prefilter: Int?
    var preferRecent: Bool
    var queryMeaning: String? = nil
    var queryWeight: Double = 0.4
}

struct CoreSelection: Codable, Sendable, Identifiable {
    var id: String
    var score: Float
    var reason: String
}

struct CoreDuplicateRequest: Codable, Sendable {
    var threshold: Double
    var maxGapSeconds: Double
    var minGroup: Int
    var limit: Int
}

struct CoreDuplicateGroup: Codable, Sendable, Identifiable {
    var itemIds: [String]
    var similarity: Float
    var id: String { itemIds.first ?? UUID().uuidString }
}

struct CoreStats: Codable, Sendable {
    var count: Int
    var analyzed: Int
    var semantic: Int
    var averageQuality: Float
    var oldest: Double?
    var newest: Double?
    var featureDimension: Int
    var estimatedBytes: Int
    var inserted: UInt64
    var updated: UInt64
    var removed: UInt64
}

/// A pointer-owning box outside the actor. Putting the free in a final class's
/// deinit keeps the opaque C pointer out of the actor's nonisolated deinit.
private final class MosaicIndexHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init?() {
        guard let pointer = mosaic_index_new() else { return nil }
        self.pointer = pointer
    }

    deinit {
        mosaic_index_free(pointer)
    }
}

/// Owning wrapper around the opaque Rust index handle.
actor MosaicCoreIndex {
    static let shared = MosaicCoreIndex()
    private let handle: MosaicIndexHandle?

    init() {
        handle = MosaicIndexHandle()
    }

    var isAvailable: Bool { handle != nil }

    func upsert(_ items: [CoreIndexItem]) throws -> CoreUpsertResult {
        try call(EnvelopeRequest(items: items), function: mosaic_index_upsert)
    }

    func remove(_ ids: [String]) throws {
        struct Request: Encodable { let ids: [String] }
        struct Response: Decodable { let removed: Int }
        let _: Response = try call(Request(ids: ids), function: mosaic_index_remove)
    }

    func clear() throws {
        let _: EmptyResponse = try callNoInput(mosaic_index_clear)
    }

    func query(_ request: CoreQueryRequest) throws -> [CoreQueryResult] {
        struct Response: Decodable { let results: [CoreQueryResult] }
        let response: Response = try call(request, function: mosaic_index_query)
        return response.results
    }

    func clusters(_ request: CoreClusterRequest) throws -> [CoreCluster] {
        struct Response: Decodable { let clusters: [CoreCluster] }
        let response: Response = try call(request, function: mosaic_index_clusters)
        return response.clusters
    }

    func select(_ request: CoreSelectRequest) throws -> [CoreSelection] {
        struct Response: Decodable { let selected: [CoreSelection] }
        let response: Response = try call(request, function: mosaic_index_select)
        return response.selected
    }

    func duplicates(_ request: CoreDuplicateRequest) throws -> [CoreDuplicateGroup] {
        struct Response: Decodable { let groups: [CoreDuplicateGroup] }
        let response: Response = try call(request, function: mosaic_index_duplicates)
        return response.groups
    }

    func stats() throws -> CoreStats {
        try call(EmptyRequest(), function: mosaic_index_stats)
    }

    private struct EmptyRequest: Encodable {}
    private struct EmptyResponse: Decodable {}
    private struct EnvelopeRequest: Encodable { let items: [CoreIndexItem] }

    private func call<Request: Encodable, Response: Decodable>(
        _ request: Request,
        function: (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    ) throws -> Response {
        guard let handle else {
            throw MosaicCoreError(message: "The visual index is unavailable.")
        }
        let data = try MosaicCoreBridge.encoder.encode(request)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MosaicCoreError(message: "Could not encode the index request.")
        }
        let pointer = json.withCString { function(handle.pointer, $0) }
        return try MosaicCoreBridge.decode(pointer, as: Response.self)
    }

    private func callNoInput<Response: Decodable>(
        _ function: (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    ) throws -> Response {
        guard let handle else {
            throw MosaicCoreError(message: "The visual index is unavailable.")
        }
        return try MosaicCoreBridge.decode(function(handle.pointer), as: Response.self)
    }
}

// MARK: - High-level sync + curation

/// Keeps the Rust index aligned with the Swift source of truth without resending the
/// whole library. A fingerprint per item makes favorite, metadata, and analysis
/// changes incremental; 50k unchanged items cost one dictionary comparison.
actor MosaicCoreStore {
    static let shared = MosaicCoreStore()
    private let index = MosaicCoreIndex()
    private var fingerprints: [String: Fingerprint] = [:]
    private var known: Set<String> = []
    private(set) var lastSyncedCount = 0
    private(set) var lastSyncDate: Date?

    private struct Fingerprint: Equatable {
        var modified: Double?
        var version: Int
        var detailed: Bool
        var favorite: Bool
        var featureCount: Int
        var meaningCount: Int
        var hash: UInt64
    }

    private func fingerprint(
        _ item: MediaItem, descriptor: VisualDescriptor?, favorite: Bool
    ) -> Fingerprint {
        Fingerprint(
            modified: item.modified?.timeIntervalSince1970,
            version: descriptor?.version ?? 0,
            detailed: descriptor?.detailed ?? false,
            favorite: favorite,
            featureCount: descriptor?.feature?.count ?? 0,
            meaningCount: descriptor?.meaning?.count ?? 0,
            hash: descriptor?.hash ?? 0)
    }

    @discardableResult
    func sync(
        items: [MediaItem], descriptors: [String: VisualDescriptor], favorites: Set<String>
    ) async -> Int {
        var seen = Set<String>()
        seen.reserveCapacity(items.count)
        var changed = 0
        // Keep at most a few hundred base64 features in memory. A 50k first sync
        // would otherwise build ~130 MB of strings before the first upsert.
        var batch: [(String, CoreIndexItem, Fingerprint)] = []
        batch.reserveCapacity(320)
        for item in items {
            seen.insert(item.id)
            let descriptor = descriptors[item.id]
            let favorite = favorites.contains(item.id)
            let fingerprint = fingerprint(item, descriptor: descriptor, favorite: favorite)
            guard fingerprints[item.id] != fingerprint else { continue }
            batch.append(
                (item.id, coreItem(item, descriptor: descriptor, favorite: favorite), fingerprint))
            changed += 1
            if batch.count >= 320 {
                await flush(&batch)
            }
        }
        await flush(&batch)
        let removed = known.subtracting(seen)
        if !removed.isEmpty {
            for chunk in Array(removed).chunked(into: 500) {
                try? await index.remove(chunk)
            }
            for id in removed { fingerprints.removeValue(forKey: id) }
        }
        known = seen
        lastSyncedCount = known.count
        lastSyncDate = Date()
        return changed
    }

    /// Upsert a bounded batch and only mark fingerprints as synced when the engine
    /// accepted them. A failed chunk is retried on the next sync.
    private func flush(
        _ batch: inout [(String, CoreIndexItem, Fingerprint)]
    ) async {
        guard !batch.isEmpty else { return }
        let entries = batch
        batch.removeAll(keepingCapacity: true)
        do {
            _ = try await index.upsert(entries.map(\.1))
            for entry in entries { fingerprints[entry.0] = entry.2 }
        } catch {
            for entry in entries { fingerprints.removeValue(forKey: entry.0) }
        }
    }

    /// Incremental path for descriptors published while analysis is running. It
    /// never removes library items and never holds more than one batch of base64
    /// features, so a publish cannot copy the whole descriptor dictionary.
    @discardableResult
    func upsert(
        descriptors: [String: VisualDescriptor], items: [MediaItem], favorites: Set<String>
    ) async -> Int {
        guard !descriptors.isEmpty else { return 0 }
        let wanted = Set(descriptors.keys)
        var lookup: [String: MediaItem] = [:]
        lookup.reserveCapacity(wanted.count)
        for item in items where wanted.contains(item.id) { lookup[item.id] = item }
        var batch: [(String, CoreIndexItem, Fingerprint)] = []
        batch.reserveCapacity(320)
        var changed = 0
        for id in descriptors.keys.sorted() {
            guard let item = lookup[id], let descriptor = descriptors[id] else { continue }
            let favorite = favorites.contains(id)
            let fingerprint = fingerprint(item, descriptor: descriptor, favorite: favorite)
            guard fingerprints[id] != fingerprint else { continue }
            batch.append(
                (id, coreItem(item, descriptor: descriptor, favorite: favorite), fingerprint))
            known.insert(id)
            changed += 1
            if batch.count >= 320 { await flush(&batch) }
        }
        await flush(&batch)
        lastSyncedCount = known.count
        lastSyncDate = Date()
        return changed
    }

    func clear() async {
        try? await index.clear()
        fingerprints.removeAll()
        known.removeAll()
        lastSyncedCount = 0
    }

    func select(
        items: [MediaItem], descriptors: [String: VisualDescriptor], favorites: Set<String>,
        count: Int, diversity: Double = 0.62, minGapSeconds: Double = 0,
        preferRecent: Bool = true, kinds: [String]? = nil, seed: UInt64 = 1,
        ids: [String]? = nil, story: String = ""
    ) async throws -> [CoreSelection] {
        await sync(items: items, descriptors: descriptors, favorites: favorites)
        let storyVector = MediaSemantics.vector(for: MediaSemantics.words(story))?
            .base64EncodedString()
        return try await index.select(
            CoreSelectRequest(
                count: count, ids: ids, excludeIds: [], diversity: diversity,
                includeFavorites: true, kinds: kinds, minGapSeconds: minGapSeconds,
                dateFrom: nil, dateTo: nil, seed: seed, prefilter: nil,
                preferRecent: preferRecent, queryMeaning: storyVector,
                queryWeight: storyVector == nil ? 0 : 0.4))
    }

    func query(
        seed id: String, items: [MediaItem], descriptors: [String: VisualDescriptor],
        favorites: Set<String>, limit: Int = 120, mode: String = "combined"
    ) async throws -> [CoreQueryResult] {
        await sync(items: items, descriptors: descriptors, favorites: favorites)
        return try await index.query(
            CoreQueryRequest(
                id: id, feature: nil, meaning: nil, limit: limit, ids: nil,
                excludeIds: [], minSimilarity: 0, mode: mode, kinds: nil,
                dateFrom: nil, dateTo: nil, projectionSeed: nil))
    }

    func clusters(
        mode: String, items: [MediaItem], descriptors: [String: VisualDescriptor],
        favorites: Set<String>, budget: Int = 40, threshold: Double = 0.55,
        syncItems: [MediaItem]? = nil, ids: [String]? = nil
    ) async throws -> [CoreCluster] {
        await sync(
            items: syncItems ?? items, descriptors: descriptors, favorites: favorites)
        return try await index.clusters(
            CoreClusterRequest(mode: mode, budget: budget, threshold: threshold, ids: ids))
    }

    func duplicates(
        items: [MediaItem], descriptors: [String: VisualDescriptor], favorites: Set<String>,
        threshold: Double = 0.9, maxGapSeconds: Double = 900, limit: Int = 200
    ) async throws -> [CoreDuplicateGroup] {
        await sync(items: items, descriptors: descriptors, favorites: favorites)
        return try await index.duplicates(
            CoreDuplicateRequest(
                threshold: threshold, maxGapSeconds: maxGapSeconds, minGroup: 2, limit: limit))
    }

    func stats() async throws -> CoreStats {
        try await index.stats()
    }

    private func coreItem(
        _ item: MediaItem, descriptor: VisualDescriptor?, favorite: Bool
    ) -> CoreIndexItem {
        let megapixels = Double(item.width * item.height) / 1_000_000
        let resolution = min(1, max(0, log10(max(megapixels, 0.1)) / 1.3))
        let labels = min(1, Double(descriptor?.labels?.count ?? 0) / 8)
        let quality = min(
            1,
            resolution * 0.55 + labels * 0.15 + (descriptor?.detailed == true ? 0.08 : 0))
        return CoreIndexItem(
            id: item.id,
            name: item.name,
            date: item.date.timeIntervalSince1970,
            width: item.width,
            height: item.height,
            favorite: favorite,
            kind: item.kind.rawValue,
            color: descriptor?.color ?? "Not analyzed",
            theme: descriptor?.theme,
            labels: descriptor?.labels ?? [],
            hash: String(descriptor?.hash ?? 0),
            feature: descriptor?.feature?.base64EncodedString(),
            meaning: descriptor?.meaning?.base64EncodedString(),
            palette: descriptor?.palette ?? [],
            quality: quality,
            detailed: descriptor?.detailed ?? false,
            sourceModified: item.modified?.timeIntervalSince1970
        )
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
