import Photos
import UIKit

// Loads a single display or export image without ever requesting an iCloud original
// during browsing. Exports opt into network access because the person explicitly
// asked to create something from the media.
enum MediaImageLoader {
    static func image(for item: MediaItem, pixels: Int, allowNetwork: Bool = true) async -> UIImage? {
        let pixels = max(64, min(pixels, 4096))
        if item.isPhotoLibrary {
            guard
                let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [item.photoIdentifier], options: nil
                ).firstObject
            else { return nil }
            let request = PhotoImageRequest()
            return await withTaskCancellationHandler {
                await request.load(asset, pixels: pixels, allowNetwork: allowNetwork)
            } onCancel: {
                request.cancel()
            }
        }
        return await ThumbnailService.shared.image(for: item, pixels: pixels)
    }
}

// PhotoKit may deliver a degraded image and then a final one. A continuation can
// only be resumed once, so a small lock-protected box keeps the final result and
// lets cancellation complete the request early.
private final class PhotoImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID: PHImageRequestID?

    func load(_ asset: PHAsset, pixels: Int, allowNetwork: Bool) async -> UIImage? {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = allowNetwork
            let request = PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: pixels, height: pixels),
                contentMode: .aspectFit, options: options
            ) { [weak self] image, info in
                guard let self else { return }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                if degraded { return }
                self.finish(image)
            }
            lock.lock()
            if self.continuation == nil {
                PHImageManager.default().cancelImageRequest(request)
            } else {
                self.requestID = request
            }
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        let request = requestID
        requestID = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let request { PHImageManager.default().cancelImageRequest(request) }
        continuation?.resume(returning: nil)
    }

    private func finish(_ image: UIImage?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.requestID = nil
        lock.unlock()
        continuation?.resume(returning: image)
    }
}
