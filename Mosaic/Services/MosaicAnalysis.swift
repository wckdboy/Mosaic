import Foundation
import NaturalLanguage
import Photos
import UIKit

// All analysis uses small thumbnails. Photos requests never fetch iCloud originals;
// file-provider media is excluded from automatic analysis to avoid hidden downloads.
actor MosaicAnalysis {
    static let shared = MosaicAnalysis()
    private var cache: [String: VisualDescriptor] = [:]
    private var loaded = false
    private let cacheURL = URL.cachesDirectory.appending(path: "Mosaic/visual-index.json")

    func cached() -> [String: VisualDescriptor] {
        if !loaded {
            if let data = try? Data(contentsOf: cacheURL),
                let decoded = try? JSONDecoder().decode([String: VisualDescriptor].self, from: data)
            {
                cache = decoded
            }
            loaded = true
        }
        return cache
    }
    func analyze(_ item: MediaItem, allowFileRead: Bool = false) async -> VisualDescriptor? {
        _ = cached()
        if let descriptor = cache[item.id], descriptor.sourceModified == item.modified { return descriptor }
        if !item.isPhotoLibrary {
            // Files already viewed in the gallery can reuse a memory-cached thumbnail.
            // An uncached cloud file remains unclassified until the user opens it.
            guard !Task.isCancelled else { return nil }
            // A Find similar tap authorizes loading this single reference thumbnail.
            let image =
                allowFileRead
                ? await ThumbnailService.shared.image(for: item, pixels: 400)
                : await ThumbnailService.shared.cachedImage(for: item, pixels: 400)
            guard let image,
                let cg = image.cgImage,
                var descriptor = Self.describe(cg)
            else { return nil }
            descriptor.sourceModified = item.modified
            cache[item.id] = descriptor
            return descriptor
        }
        guard !Task.isCancelled,
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.photoIdentifier], options: nil)
                .firstObject
        else { return nil }
        let image: UIImage? = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = false
            options.resizeMode = .fast
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 96, height: 96), contentMode: .aspectFill,
                options: options
            ) { image, _ in continuation.resume(returning: image) }
        }
        guard !Task.isCancelled, let cg = image?.cgImage, var descriptor = Self.describe(cg) else {
            return nil
        }
        descriptor.sourceModified = item.modified
        cache[item.id] = descriptor
        return descriptor
    }
    func save() {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            // This is a rebuildable cache, not user-authored organization.
        }
    }
    func clear() {
        cache = [:]
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // Sampling into 9×8 pixels computes average color and a horizontal difference
    // hash in the same tiny buffer. Memory per analysis is independent of source size.
    static func describe(_ image: CGImage) -> VisualDescriptor? {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var red = 0
        var green = 0
        var blue = 0
        var hash: UInt64 = 0
        func luma(_ x: Int, _ y: Int) -> Int {
            let offset = (y * width + x) * 4
            return Int(pixels[offset]) * 299 + Int(pixels[offset + 1]) * 587 + Int(pixels[offset + 2]) * 114
        }
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                red += Int(pixels[offset])
                green += Int(pixels[offset + 1])
                blue += Int(pixels[offset + 2])
                if x < 8 && luma(x, y) > luma(x + 1, y) { hash |= UInt64(1) << (y * 8 + x) }
            }
        }
        let scale = CGFloat(width * height * 255)
        let color = UIColor(
            red: CGFloat(red) / scale, green: CGFloat(green) / scale, blue: CGFloat(blue) / scale, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        let name: String
        if brightness < 0.16 {
            name = "Dark"
        } else if saturation < 0.13 {
            name = brightness > 0.8 ? "Light" : "Neutral"
        } else {
            switch hue * 360 {
            case 15..<45: name = "Orange"
            case 45..<75: name = "Yellow"
            case 75..<165: name = "Green"
            case 165..<200: name = "Cyan"
            case 200..<260: name = "Blue"
            case 260..<320: name = "Purple"
            default: name = "Red"
            }
        }
        return VisualDescriptor(color: name, hash: hash)
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
