import AVKit
import ImageIO
import PhotosUI
import SwiftUI

// AVKit's stock controller remains for simple single-item surfaces such as S3
// streaming. The library viewer uses VideoPlayerSurface with Mosaic's own controls.
struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var fill = false
    var locked = false
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        controller.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        controller.speeds = [0.5, 0.75, 1, 1.25, 1.5, 2].map {
            AVPlaybackSpeed(rate: Float($0), localizedName: "\($0)×")
        }
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        controller.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        controller.showsPlaybackControls = !locked
        controller.view.isUserInteractionEnabled = !locked
    }
}

// One zoom container for every media kind: content is aspect-fitted and centered,
// pinches zoom up to 8× with rubber-banding, and pans stay inside the media. It
// reports zoom state (paging is disabled while zoomed) and pinch interaction (so a
// two-finger pinch can never be mistaken for a page swipe or swipe-to-close).
final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let content: UIView
    var naturalSize: CGSize = .zero {
        didSet { if naturalSize != oldValue { needsFit = true; setNeedsLayout() } }
    }
    // Video keeps "fill" across rotation by re-zooming after each fit.
    var keepsFill = false
    var onTap: (() -> Void)?
    var onZoomChange: ((Bool) -> Void)?
    var onInteraction: ((Bool) -> Void)?
    var onFillChange: ((Bool) -> Void)?
    let doubleTap = UITapGestureRecognizer()
    let singleTap = UITapGestureRecognizer()
    private var needsFit = true
    private var fittedBounds = CGSize.zero
    private var reportedZoom = false

    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 8
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        addSubview(content)
        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
        addGestureRecognizer(doubleTap)
        singleTap.addTarget(self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }
    required init?(coder: NSCoder) { fatalError("Storyboard initialization is not supported") }

    // "Fill" is a baseline, not a zoom: it must not lock paging or swipe-to-close.
    var isZoomedIn: Bool { zoomScale > (keepsFill ? fillScale : minimumZoomScale) + 0.01 }
    // The scale at which the fitted content covers the whole viewport.
    var fillScale: CGFloat {
        let size = content.bounds.size
        guard size.width > 0, size.height > 0 else { return 1 }
        return max(bounds.width / size.width, bounds.height / size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsFit || bounds.size != fittedBounds { fit() }
    }
    private func fit() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        needsFit = false
        fittedBounds = bounds.size
        zoomScale = 1
        var size = bounds.size
        if naturalSize.width > 0, naturalSize.height > 0 {
            let scale = min(bounds.width / naturalSize.width, bounds.height / naturalSize.height)
            size = CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
        }
        content.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centerContent()
        if keepsFill { zoomScale = fillScale }
        report()
    }
    func setFill(_ fill: Bool, animated: Bool) {
        keepsFill = fill
        setZoomScale(fill ? fillScale : 1, animated: animated)
        report()
    }
    private func centerContent() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        if contentInset != inset { contentInset = inset }
    }
    private func report() {
        let zoomed = isZoomedIn
        // At the fill baseline the content overflows, but drags belong to paging.
        let pans = zoomed || !keepsFill
        if panGestureRecognizer.isEnabled != pans { panGestureRecognizer.isEnabled = pans }
        guard zoomed != reportedZoom else { return }
        reportedZoom = zoomed
        onZoomChange?(zoomed)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        report()
    }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { onInteraction?(true) }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if keepsFill, scale <= minimumZoomScale + 0.01 {
            keepsFill = false
            onFillChange?(false)
        }
        report()
        onInteraction?(false)
    }

    @objc private func handleSingleTap() { onTap?() }
    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if isZoomedIn {
            keepsFill = false
            setZoomScale(1, animated: true)
        } else {
            let point = recognizer.location(in: content)
            let scale: CGFloat = max(2.5, fillScale)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(
                to: CGRect(
                    x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width,
                    height: size.height),
                animated: true)
        }
    }
}

// Callbacks shared by every zoomable surface; all optional.
struct ZoomCallbacks {
    var isZoomed: Binding<Bool> = .constant(false)
    var onTap: (() -> Void)?
    var onInteraction: ((Bool) -> Void)?
    @MainActor func attach(to view: ZoomScrollView) {
        let binding = isZoomed
        view.onZoomChange = { zoomed in if binding.wrappedValue != zoomed { binding.wrappedValue = zoomed } }
        view.onTap = onTap
        view.onInteraction = onInteraction
    }
}

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var callbacks = ZoomCallbacks()
    // Animated images replace frames continuously and must keep the user's zoom.
    var resetsZoomOnChange = true
    init(
        image: UIImage, isZoomed: Binding<Bool> = .constant(false), resetsZoomOnChange: Bool = true,
        onInteraction: ((Bool) -> Void)? = nil, onTap: (() -> Void)? = nil
    ) {
        self.image = image
        self.resetsZoomOnChange = resetsZoomOnChange
        callbacks = ZoomCallbacks(isZoomed: isZoomed, onTap: onTap, onInteraction: onInteraction)
    }
    func makeUIView(context: Context) -> ZoomScrollView {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        let view = ZoomScrollView(content: imageView)
        view.naturalSize = image.size
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Photo. Pinch or double-tap to zoom."
        view.accessibilityIdentifier = "viewer.zoomable"
        callbacks.attach(to: view)
        return view
    }
    func updateUIView(_ view: ZoomScrollView, context: Context) {
        callbacks.attach(to: view)
        guard let imageView = view.content as? UIImageView, imageView.image !== image else { return }
        imageView.image = image
        if resetsZoomOnChange || view.naturalSize != image.size {
            view.naturalSize = image.size
            view.setZoomScale(1, animated: false)
        }
    }
}

struct LivePhotoSurface: UIViewRepresentable {
    let photo: PHLivePhoto
    var callbacks = ZoomCallbacks()
    init(
        photo: PHLivePhoto, isZoomed: Binding<Bool> = .constant(false),
        onInteraction: ((Bool) -> Void)? = nil, onTap: (() -> Void)? = nil
    ) {
        self.photo = photo
        callbacks = ZoomCallbacks(isZoomed: isZoomed, onTap: onTap, onInteraction: onInteraction)
    }
    func makeUIView(context: Context) -> ZoomScrollView {
        let live = PHLivePhotoView()
        live.contentMode = .scaleAspectFit
        let view = ZoomScrollView(content: live)
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Live Photo. Touch and hold to play; pinch to zoom."
        callbacks.attach(to: view)
        return view
    }
    func updateUIView(_ view: ZoomScrollView, context: Context) {
        callbacks.attach(to: view)
        guard let live = view.content as? PHLivePhotoView, live.livePhoto !== photo else { return }
        live.livePhoto = photo
        view.naturalSize = photo.size
    }
}

// Frames are decoded at display size. Short animations are cached after the first
// loop so playback stops re-decoding (the main cost of GIFs); long ones stream.
struct AnimatedImageSurface: View {
    let url: URL
    var isZoomed: Binding<Bool> = .constant(false)
    var onInteraction: ((Bool) -> Void)?
    var onTap: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var frame: UIImage?
    @State private var failed = false
    private var animationKey: String { "\(url.absoluteString)-\(scenePhase)-\(reduceMotion)" }
    var body: some View {
        Group {
            if let frame {
                ZoomableImage(
                    image: frame, isZoomed: isZoomed, resetsZoomOnChange: false, onInteraction: onInteraction,
                    onTap: onTap)
            } else if failed {
                ContentUnavailableView("Unable to decode animation", systemImage: "photo")
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Animated image")
        .task(id: animationKey) {
            guard scenePhase == .active else { return }
            // Display-sized decoding: a phone never needs a 2048 px GIF frame.
            let pixels = Int(min(1400, max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * displayScale))
            let decoder = await Task.detached { AnimationDecoder(url: url, pixels: pixels) }.value
            repeat {
                guard !Task.isCancelled else { return }
                let next = await decoder.nextFrame()
                guard !Task.isCancelled else { return }
                guard let image = next.image else {
                    failed = true
                    return
                }
                frame = image
                if reduceMotion { return }
                do { try await Task.sleep(for: .seconds(next.delay)) } catch { return }
            } while !Task.isCancelled
        }
    }
}

// ImageIO handles compositing/disposal; the actor keeps decoding off the UI thread.
private actor AnimationDecoder {
    private let source: CGImageSource?
    private let pixels: Int
    private var index = 0
    private var cache: [(UIImage, Double)] = []
    private var cacheBytes = 0
    private var caching = true
    private static let cacheLimit = 48 * 1024 * 1024
    init(url: URL, pixels: Int) {
        source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        self.pixels = pixels
    }
    func nextFrame() -> (image: UIImage?, delay: Double) {
        guard let source else { return (nil, 0.1) }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return (nil, 0.1) }
        if cache.count == count {
            let frame = cache[index]
            index = (index + 1) % count
            return frame
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let rawDelay =
            (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
            ?? (png?[kCGImagePropertyAPNGDelayTime] as? Double) ?? 0.1
        let delay = rawDelay.isFinite ? max(0.02, rawDelay) : 0.1
        let cg = CGImageSourceCreateThumbnailAtIndex(
            source, index,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        let image = cg.map { UIImage(cgImage: $0) }
        if caching, let cg, cache.count == index {
            cacheBytes += cg.bytesPerRow * cg.height
            if cacheBytes <= Self.cacheLimit {
                cache.append((UIImage(cgImage: cg), delay))
            } else {
                caching = false
                cache = []
            }
        }
        index = (index + 1) % count
        return (image, delay)
    }
}

// The system share sheet owns destinations and their associated permission flows.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
