import AVFoundation
import ImageIO
import Photos
import UIKit

// File thumbnails are decoded serially on this actor and bounded by a cost-based cache.
// The Photos manager provides its own optimized, cancellable thumbnail pipeline.
actor ThumbnailService {
    static let shared = ThumbnailService()
    private let cache = NSCache<NSString, UIImage>()
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
        guard !Task.isCancelled, let access = try? FileAccess(item: item) else { return nil }
        let image: UIImage?
        if item.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: access.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: pixels, height: pixels)
            if let result = try? await generator.image(at: .zero) {
                image = UIImage(cgImage: result.image)
            } else {
                image = nil
            }
        } else {
            image = Self.downsample(url: access.url, pixels: pixels)
        }
        if let image {
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

@MainActor final class PhotoThumbnailRequest {
    static let manager = PHCachingImageManager()
    private var request: PHImageRequestID?
    func load(_ item: MediaItem, pixels: Int, completion: @escaping (UIImage?) -> Void) {
        cancel()
        guard
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.photoIdentifier], options: nil)
                .firstObject
        else {
            completion(nil)
            return
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        // Browsing must not download an entire iCloud library. The viewer requests originals.
        options.isNetworkAccessAllowed = false
        request = Self.manager.requestImage(
            for: asset, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFill,
            options: options
        ) { image, _ in
            Task { @MainActor in completion(image) }
        }
    }
    func cancel() {
        if let request { Self.manager.cancelImageRequest(request) }
        request = nil
    }
}
