import Photos
import UIKit

// Far zoom draws one bitmap of the whole world instead of thousands of live cells:
// every item first as its dominant color, then progressively as a tiny thumbnail.
// Rendering is off the main thread, cancellable, capped at 2048 px, and runs at most
// once per projection, so zooming and panning the overview only rescale a texture.
final class CanvasMapView: UIImageView {
    private var task: Task<Void, Never>?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleToFill
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
        alpha = 0
        // Always beneath tiles and island labels, whatever order UIKit inserts views in.
        layer.zPosition = -1
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Overview of all media"
        accessibilityHint = "Tap to zoom in"
    }
    required init?(coder: NSCoder) { fatalError("Storyboard initialization is not supported") }

    func reset() {
        task?.cancel()
        task = nil
        image = nil
    }
    func render(frames: [[CGRect]], clusters: [MosaicCluster], tints: [String: UInt32], world: CGSize) {
        task?.cancel()
        var entries: [CanvasMapRenderer.Entry] = []
        for (section, sectionFrames) in frames.enumerated() where clusters.indices.contains(section) {
            let items = clusters[section].items
            for (index, frame) in sectionFrames.enumerated() where items.indices.contains(index) {
                entries.append(.init(frame: frame, item: items[index], tint: tints[items[index].id]))
            }
        }
        task = Task { [weak self] in
            // Debounced: typing a search while zoomed out must not restart the render per keystroke.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            for await image in CanvasMapRenderer.render(entries, world: world) {
                guard !Task.isCancelled else { return }
                self?.image = image
            }
        }
    }
}

enum CanvasMapRenderer {
    struct Entry: Sendable {
        let frame: CGRect
        let item: MediaItem
        let tint: UInt32?
    }
    static let maxSide: CGFloat = 2048

    static func render(_ entries: [Entry], world: CGSize) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                defer { continuation.finish() }
                guard world.width > 0, world.height > 0, !entries.isEmpty else { return }
                let k = min(1, maxSide / max(world.width, world.height))
                let width = max(1, Int(world.width * k))
                let height = max(1, Int(world.height * k))
                guard
                    let context = CGContext(
                        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue)
                else { return }
                context.interpolationQuality = .low
                // Layout coordinates are top-left based; Core Graphics is bottom-left.
                func target(_ frame: CGRect) -> CGRect {
                    CGRect(
                        x: frame.minX * k, y: CGFloat(height) - frame.maxY * k, width: frame.width * k,
                        height: frame.height * k)
                }
                for entry in entries {
                    let tint = entry.tint ?? 0x9A9A9A
                    context.setFillColor(
                        red: CGFloat((tint >> 16) & 255) / 255, green: CGFloat((tint >> 8) & 255) / 255,
                        blue: CGFloat(tint & 255) / 255, alpha: 1)
                    context.fill(target(entry.frame))
                }
                if let image = context.makeImage() { continuation.yield(UIImage(cgImage: image)) }
                // Thumbnails are a refinement: skip them when tiles are too small to show
                // one, and whenever the device is warm (re-checked every batch below).
                func cool() -> Bool {
                    ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.fair.rawValue
                }
                guard MosaicCanvasLayout.unit * k >= 4, cool() else { return }
                let pixels = max(24, min(160, Int(MosaicCanvasLayout.unit * k * 2)))
                let options = PHImageRequestOptions()
                options.isSynchronous = true
                // Synchronous .fastFormat requests fail with "no resource matching spec";
                // synchronous opportunistic delivers one small, locally cached image.
                options.deliveryMode = .opportunistic
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = false
                let manager = PHImageManager.default()
                var lastYield = ContinuousClock.now
                let photos = entries.filter(\.item.isPhotoLibrary)
                for start in stride(from: 0, to: photos.count, by: 400) {
                    guard !Task.isCancelled, cool() else { break }
                    let batch = photos[start..<min(photos.count, start + 400)]
                    let fetched = PHAsset.fetchAssets(
                        withLocalIdentifiers: batch.map(\.item.photoIdentifier), options: nil)
                    var assets: [String: PHAsset] = [:]
                    fetched.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
                    for entry in batch {
                        guard !Task.isCancelled else { return }
                        guard let asset = assets[entry.item.photoIdentifier] else { continue }
                        var thumbnail: CGImage?
                        manager.requestImage(
                            for: asset, targetSize: CGSize(width: pixels, height: pixels),
                            contentMode: .aspectFill, options: options
                        ) { image, _ in thumbnail = image?.cgImage }
                        guard let thumbnail else { continue }
                        draw(thumbnail, filling: target(entry.frame), in: context)
                    }
                    if ContinuousClock.now - lastYield > .milliseconds(500), let image = context.makeImage() {
                        lastYield = .now
                        continuation.yield(UIImage(cgImage: image))
                    }
                }
                if let image = context.makeImage() { continuation.yield(UIImage(cgImage: image)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func draw(_ image: CGImage, filling rect: CGRect, in context: CGContext) {
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.saveGState()
        context.clip(to: rect)
        context.draw(
            image,
            in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        context.restoreGState()
    }
}
