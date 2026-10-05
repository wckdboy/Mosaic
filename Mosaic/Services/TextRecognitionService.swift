import Photos
import UIKit
import Vision

// Recognition is explicitly requested in Settings. It runs on this actor, reads
// local thumbnails only, and never sends images to a model provider or downloads iCloud originals.
actor TextRecognitionService {
    static let shared = TextRecognitionService()
    func text(in item: MediaItem) async -> String? {
        guard !Task.isCancelled, item.kind != .video else { return nil }
        let image: UIImage?
        if item.isPhotoLibrary {
            guard
                let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.photoIdentifier], options: nil)
                    .firstObject
            else { return nil }
            image = await withCheckedContinuation { continuation in
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = false
                PHImageManager.default().requestImage(
                    for: asset, targetSize: CGSize(width: 1600, height: 1600), contentMode: .aspectFit,
                    options: options
                ) { image, _ in continuation.resume(returning: image) }
            }
        } else {
            image = await ThumbnailService.shared.image(for: item, pixels: 1600)
        }
        guard !Task.isCancelled, let cgImage = image?.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            // Keep the index bounded even for unusually dense documents.
            return String(
                (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
                    separator: " "
                ).prefix(12000))
        } catch { return nil }
    }
}
