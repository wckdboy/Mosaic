import AVFoundation
import ImageIO
import Photos
import UIKit

// File thumbnails share an actor-owned decode budget and cost-based cache.
// The Photos manager provides its own optimized, cancellable thumbnail pipeline.
actor ThumbnailService {
    static let shared = ThumbnailService()
    private let cache = NSCache<NSString, UIImage>()
    private var activeDecodes = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // Actor reentrancy alone does not limit asynchronous AVAssetImageGenerator
    // work. Cap simultaneous decodes so fast flings cannot launch dozens of videos.
    private func acquireDecode() async {
        if activeDecodes < 3 {
            activeDecodes += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func releaseDecode() {
        if waiters.isEmpty { activeDecodes -= 1 } else { waiters.removeFirst().resume() }
    }
    init() {
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 400
    }

    func cachedImage(for item: MediaItem, pixels: Int) -> UIImage? {
        cache.object(forKey: "\(item.thumbnailKey)-\(pixels)" as NSString)
    }

    func image(for item: MediaItem, pixels: Int) async -> UIImage? {
        let key = "\(item.thumbnailKey)-\(pixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        await acquireDecode()
        defer { releaseDecode() }
        guard !Task.isCancelled else { return nil }
        // A previous request may have filled this entry while we waited.
        if let cached = cache.object(forKey: key) { return cached }
        guard let access = try? FileAccess(item: item) else { return nil }
        let image: UIImage?
        if item.kind == .video {
            let request = VideoThumbnailRequest(url: access.url, pixels: pixels)
            let result = try? await withTaskCancellationHandler {
                try await request.image()
            } onCancel: {
                request.cancel()
            }
            if let result {
                image = UIImage(cgImage: result)
            } else {
                image = nil
            }
        } else {
            image = Self.downsample(url: access.url, pixels: pixels)
        }
        if let image, !Task.isCancelled {
            cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        }
        withExtendedLifetime(access) {}
        return image
    }

    nonisolated static func downsample(url: URL, pixels: Int) -> UIImage? {
        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let cg = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

// AVFoundation's generator supports cancellation of an outstanding asynchronous
// request. Configure it before publication, then expose only image/cancel: no
// mutable generator settings cross the thumbnail actor's suspension boundary.
private final class VideoThumbnailRequest: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    init(url: URL, pixels: Int) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
    }
    func image() async throws -> CGImage { try await generator.image(at: .zero).image }
    func cancel() { generator.cancelAllCGImageGeneration() }
}

@MainActor final class PhotoThumbnailRequest {
    static let manager = PHCachingImageManager()
    private var request: PHImageRequestID?
    private var generation = UUID()
    func load(_ item: MediaItem, pixels: Int, completion: @escaping (UIImage?) -> Void) {
        cancel()
        let token = generation
        guard
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.photoIdentifier], options: nil)
                .firstObject
        else {
            completion(nil)
            return
        }
        request = Self.manager.requestImage(
            for: asset, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFill,
            options: Self.options
        ) { [weak self] image, _ in
            Task { @MainActor in
                guard self?.generation == token else { return }
                completion(image)
            }
        }
    }
    // Prefetching must use the same size, mode, and options as load() to hit the cache.
    static var options: PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        // Browsing must not download an entire iCloud library. The viewer requests originals.
        options.isNetworkAccessAllowed = false
        return options
    }
    private static func assets(_ items: [MediaItem]) -> [PHAsset] {
        let ids = items.filter(\.isPhotoLibrary).map(\.photoIdentifier)
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        return result.objects(at: IndexSet(integersIn: 0..<result.count))
    }
    static func prefetch(_ items: [MediaItem], pixels: Int) {
        let assets = assets(items)
        guard !assets.isEmpty else { return }
        manager.startCachingImages(
            for: assets, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFill,
            options: options)
    }
    static func cancelPrefetch(_ items: [MediaItem], pixels: Int) {
        let assets = assets(items)
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(
            for: assets, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFill,
            options: options)
    }
    func cancel() {
        generation = UUID()
        if let request { Self.manager.cancelImageRequest(request) }
        request = nil
    }
}
