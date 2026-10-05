import Foundation
import NaturalLanguage
import Photos
import UIKit
import Vision

// All analysis uses small thumbnails. Photos requests never fetch iCloud originals,
// and Files are analyzed only when already local, so indexing never downloads media.
// The actor owns the persisted cache; decoding and Vision run concurrently outside it.
actor MosaicAnalysis {
    static let shared = MosaicAnalysis()
    private var cache: [String: VisualDescriptor] = [:]
    private var loaded = false
    private var dirty = false
    private let cacheURL = URL.cachesDirectory.appending(path: "Mosaic/visual-index-v2.plist")
    private let legacyURL = URL.cachesDirectory.appending(path: "Mosaic/visual-index.json")

    func cached() -> [String: VisualDescriptor] {
        if !loaded {
            // Binary plists store feature prints as raw bytes rather than base64 text.
            if let data = try? Data(contentsOf: cacheURL),
                let decoded = try? PropertyListDecoder().decode([String: VisualDescriptor].self, from: data)
            {
                cache = decoded
            }
            try? FileManager.default.removeItem(at: legacyURL)
            loaded = true
        }
        return cache
    }
    func store(_ descriptor: VisualDescriptor, for id: String) {
        _ = cached()
        cache[id] = descriptor
        dirty = true
    }
    func analyze(_ item: MediaItem, allowFileRead: Bool = false) async -> VisualDescriptor? {
        if let descriptor = cached()[item.id], descriptor.sourceModified == item.modified,
            descriptor.isCurrent
        {
            return descriptor
        }
        guard let descriptor = await Self.compute(item, allowFileRead: allowFileRead) else { return nil }
        store(descriptor, for: item.id)
        return descriptor
    }
    func save() {
        guard dirty else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(cache).write(to: cacheURL, options: .atomic)
            dirty = false
        } catch {
            // This is a rebuildable cache, not user-authored organization.
        }
    }
    func clear() {
        cache = [:]
        dirty = false
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: legacyURL)
    }

    // Loads a ~300 px thumbnail and derives every descriptor field from it.
    @concurrent static func compute(_ item: MediaItem, allowFileRead: Bool) async -> VisualDescriptor? {
        guard !Task.isCancelled, let image = await thumbnail(for: item, allowFileRead: allowFileRead),
            var descriptor = describe(image)
        else { return nil }
        let vision = classify(image)
        descriptor.labels = vision.labels.map(\.identifier)
        descriptor.theme = MediaTheme.theme(for: vision.labels)
        descriptor.feature = vision.feature
        // Vision can fail transiently (memory pressure) or entirely (simulators). Keep
        // the color result, but leave the entry stale so a later pass retries it.
        if vision.feature == nil { descriptor.version = 1 }
        descriptor.sourceModified = item.modified
        return descriptor
    }

    private static func thumbnail(for item: MediaItem, allowFileRead: Bool) async -> CGImage? {
        if !item.isPhotoLibrary {
            if let cached = await ThumbnailService.shared.cachedImage(for: item, pixels: 400)?.cgImage {
                return cached
            }
            guard allowFileRead || isLocalFile(item) else { return nil }
            return await ThumbnailService.shared.image(for: item, pixels: 400)?.cgImage
        }
        guard
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.photoIdentifier], options: nil)
                .firstObject
        else { return nil }
        let image: UIImage? = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = false
            options.resizeMode = .fast
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 300, height: 300), contentMode: .aspectFill,
                options: options
            ) { image, _ in continuation.resume(returning: image) }
        }
        return image?.cgImage
    }

    // Reading a cloud placeholder would trigger a provider download; local files are free.
    private static func isLocalFile(_ item: MediaItem) -> Bool {
        guard let access = try? FileAccess(item: item),
            let values = try? access.url.resourceValues(forKeys: [
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            ])
        else { return false }
        return withExtendedLifetime(access) {
            values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current
        }
    }

    // Scene labels and a feature print in one Vision pass. Either may be unavailable
    // (e.g. some simulators); color and hash analysis still succeed without them.
    static func classify(_ image: CGImage) -> (
        labels: [(identifier: String, confidence: Float)], feature: Data?
    ) {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let classify = VNClassifyImageRequest()
        let print = VNGenerateImageFeaturePrintRequest()
        try? handler.perform([classify])
        try? handler.perform([print])
        let labels = (classify.results ?? [])
            .filter { $0.confidence >= 0.15 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(10)
            .map { (identifier: $0.identifier, confidence: $0.confidence) }
        return (Array(labels), print.results?.first.flatMap(quantize))
    }

    static func quantize(_ observation: VNFeaturePrintObservation) -> Data? {
        guard observation.elementType == .float, observation.elementCount > 0 else { return nil }
        let values: [Float] = observation.data.withUnsafeBytes {
            Array($0.bindMemory(to: Float.self).prefix(observation.elementCount))
        }
        return quantize(values)
    }
    static func quantize(_ values: [Float]) -> Data? {
        let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return Data(
            values.map { UInt8(bitPattern: Int8(max(-127, min(127, ($0 / norm * 127).rounded())))) })
    }

    // A 24×24 sample yields a weighted hue histogram (dominant palette) and a 9×8
    // difference hash. Memory per analysis is independent of the source size.
    static func describe(_ image: CGImage) -> VisualDescriptor? {
        guard let pixels = sample(image, width: 24, height: 24),
            let small = sample(image, width: 9, height: 8)
        else { return nil }
        var hash: UInt64 = 0
        func luma(_ x: Int, _ y: Int) -> Int {
            let offset = (y * 9 + x) * 4
            return Int(small[offset]) * 299 + Int(small[offset + 1]) * 587 + Int(small[offset + 2]) * 114
        }
        for y in 0..<8 {
            for x in 0..<8 where luma(x, y) > luma(x + 1, y) { hash |= UInt64(1) << (y * 8 + x) }
        }
        // 12 hue buckets plus dark, light, and neutral.
        var weight = [Float](repeating: 0, count: 15)
        var sums = [(r: Float, g: Float, b: Float)](repeating: (0, 0, 0), count: 15)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Float(pixels[index]) / 255
            let g = Float(pixels[index + 1]) / 255
            let b = Float(pixels[index + 2]) / 255
            let (h, s, v) = hsb(r, g, b)
            let bucket: Int
            let w: Float
            if v < 0.16 {
                (bucket, w) = (12, 0.7)
            } else if s < 0.14 {
                (bucket, w) = (v > 0.82 ? 13 : 14, 0.7)
            } else {
                // Saturated pixels carry more perceptual weight than muted ones.
                (bucket, w) = (min(11, Int(h * 12)), 0.6 + s)
            }
            weight[bucket] += w
            sums[bucket].r += r * w
            sums[bucket].g += g * w
            sums[bucket].b += b * w
        }
        let total = weight.reduce(0, +)
        let ranked = weight.indices.filter { weight[$0] > 0 }.sorted { weight[$0] > weight[$1] }
        guard total > 0, let top = ranked.first else { return nil }
        func swatch(_ bucket: Int) -> (r: Float, g: Float, b: Float) {
            (sums[bucket].r / weight[bucket], sums[bucket].g / weight[bucket], sums[bucket].b / weight[bucket])
        }
        let palette = ranked.prefix(3).filter { $0 == top || weight[$0] >= total * 0.08 }.map { bucket in
            let color = swatch(bucket)
            return UInt32(color.r * 255) << 16 | UInt32(color.g * 255) << 8 | UInt32(color.b * 255)
        }
        let dominant = swatch(top)
        let (hue, saturation, brightness) = hsb(dominant.r, dominant.g, dominant.b)
        return VisualDescriptor(
            color: ColorFamily.name(hue: hue, saturation: saturation, brightness: brightness), hash: hash,
            version: VisualDescriptor.currentVersion, hue: hue, saturation: saturation,
            brightness: brightness, palette: palette)
    }

    private static func sample(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    static func hsb(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue
        guard delta > 0 else { return (0, 0, maxValue) }
        var hue: Float
        if maxValue == r {
            hue = (g - b) / delta
        } else if maxValue == g {
            hue = 2 + (b - r) / delta
        } else {
            hue = 4 + (r - g) / delta
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / maxValue, maxValue)
    }

    static func sentiments(items: [MediaItem], recognizedText: [String: String]) -> [String: String] {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        var result: [String: String] = [:]
        for item in items {
            let text =
                recognizedText[item.id].flatMap { $0.isEmpty ? nil : $0 }
                ?? (item.name as NSString).deletingPathExtension
            tagger.string = text
            guard !text.isEmpty else { continue }
            let score =
                tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore).0.flatMap {
                    Double($0.rawValue)
                } ?? 0
            result[item.id] = score > 0.25 ? "Positive" : score < -0.25 ? "Negative" : "Neutral"
        }
        return result
    }
}

// The library-wide index runs in the background whenever analysis is enabled, not
// only while the canvas is visible. Work is newest-first, bounded in concurrency,
// checkpointed to disk, paused in the background, and slowed under thermal pressure.
@MainActor @Observable
final class MosaicIndexer {
    static let shared = MosaicIndexer()
    private(set) var descriptors: [String: VisualDescriptor] = [:]
    // Bumped when descriptors change, throttled so the canvas re-projects in batches.
    private(set) var revision = 0
    private(set) var running = false
    private(set) var remaining = 0
    private(set) var total = 0
    private var task: Task<Void, Never>?
    private var priority: [MediaItem] = []
    private var attempted: Set<String> = []
    private var items: [MediaItem] = []
    private var loadedCache = false

    var progress: Double { total == 0 ? 1 : Double(total - remaining) / Double(total) }

    func loadCache() async {
        guard !loadedCache else { return }
        descriptors = await MosaicAnalysis.shared.cached()
        loadedCache = true
        revision += 1
    }

    func update(items: [MediaItem], enabled: Bool) async {
        await loadCache()
        self.items = items
        guard enabled else {
            stop()
            return
        }
        restart()
    }

    // A tapped item jumps the queue so its matches appear immediately.
    func prioritize(_ item: MediaItem) async -> VisualDescriptor? {
        await loadCache()
        if let existing = descriptors[item.id], existing.isCurrent,
            existing.sourceModified == item.modified
        {
            return existing
        }
        guard let descriptor = await MosaicAnalysis.shared.analyze(item, allowFileRead: true) else {
            return nil
        }
        descriptors[item.id] = descriptor
        revision += 1
        return descriptor
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
        Task { await MosaicAnalysis.shared.save() }
    }

    func reset() async {
        stop()
        await MosaicAnalysis.shared.clear()
        descriptors = [:]
        attempted = []
        revision += 1
    }

    private func restart() {
        task?.cancel()
        let pending = items.filter { item in
            guard !attempted.contains(item.id) else { return false }
            guard let existing = descriptors[item.id] else { return true }
            return !existing.isCurrent || existing.sourceModified != item.modified
        }
        .sorted { $0.date > $1.date }
        total = pending.count
        remaining = pending.count
        guard !pending.isEmpty else {
            running = false
            return
        }
        running = true
        task = Task { [weak self] in
            await self?.run(pending)
        }
    }

    private func run(_ pending: [MediaItem]) async {
        var lastPublish = ContinuousClock.now
        var sinceSave = 0
        var cursor = 0
        while cursor < pending.count, !Task.isCancelled {
            let width = Self.concurrency()
            let batch = Array(pending[cursor..<min(pending.count, cursor + width * 4)])
            cursor += batch.count
            let results = await withTaskGroup(of: (String, VisualDescriptor?).self) { group in
                var next = 0
                var collected: [(String, VisualDescriptor?)] = []
                func add() {
                    let item = batch[next]
                    next += 1
                    group.addTask(priority: .utility) {
                        (item.id, await MosaicAnalysis.compute(item, allowFileRead: false))
                    }
                }
                for _ in 0..<min(width, batch.count) { add() }
                for await result in group {
                    collected.append(result)
                    if next < batch.count, !Task.isCancelled { add() }
                }
                return collected
            }
            guard !Task.isCancelled else { break }
            for (id, descriptor) in results {
                attempted.insert(id)
                if let descriptor {
                    descriptors[id] = descriptor
                    await MosaicAnalysis.shared.store(descriptor, for: id)
                }
            }
            remaining = max(0, pending.count - cursor)
            sinceSave += results.count
            if sinceSave >= 400 {
                sinceSave = 0
                await MosaicAnalysis.shared.save()
            }
            if ContinuousClock.now - lastPublish > .milliseconds(1500) || remaining == 0 {
                lastPublish = .now
                revision += 1
            }
            if ProcessInfo.processInfo.thermalState == .serious {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        await MosaicAnalysis.shared.save()
        revision += 1
        if !Task.isCancelled { running = false }
    }

    private static func concurrency() -> Int {
        let info = ProcessInfo.processInfo
        if info.thermalState == .critical { return 1 }
        if info.isLowPowerModeEnabled || info.thermalState == .serious { return 1 }
        return min(4, max(2, info.activeProcessorCount / 2))
    }
}
