import AVKit
import ImageIO
import PhotosUI
import SwiftUI

// AVKit owns transport, subtitle/audio selection, HDR, AirPlay, speed, and PiP.
// Retaining native controls also preserves VoiceOver and system playback gestures.
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

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool
    init(image: UIImage, isZoomed: Binding<Bool> = .constant(false)) {
        self.image = image
        _isZoomed = isZoomed
    }
    func makeCoordinator() -> Coordinator { Coordinator(isZoomed: $isZoomed) }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.delegate = context.coordinator
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.image = image
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        ])
        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(tap)
        scroll.accessibilityLabel = "Photo. Pinch or double-tap to zoom."
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        if context.coordinator.imageView.image !== image {
            context.coordinator.imageView.image = image
            scroll.setZoomScale(1, animated: false)
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        let isZoomed: Binding<Bool>
        init(isZoomed: Binding<Bool>) { self.isZoomed = isZoomed }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            isZoomed.wrappedValue = scrollView.zoomScale > 1.01
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
                scroll.zoom(
                    to: CGRect(
                        x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width,
                        height: size.height), animated: true)
            }
        }
    }
}

struct LivePhotoSurface: UIViewRepresentable {
    let photo: PHLivePhoto
    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }
    func updateUIView(_ view: PHLivePhotoView, context: Context) { view.livePhoto = photo }
}

// Decode one animation frame at a time, sized for display. This avoids retaining
// every decompressed frame and keeps GIF/APNG centered like every other image.
struct AnimatedImageSurface: View {
    let url: URL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame: UIImage?
    @State private var failed = false
    private var animationKey: String { "\(url.absoluteString)-\(scenePhase)-\(reduceMotion)" }
    var body: some View {
        Group {
            if let frame {
                Image(uiImage: frame).resizable().scaledToFit()
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
            let decoder = await Task.detached { AnimationDecoder(url: url) }.value
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
    private var index = 0
    init(url: URL) {
        source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
    func nextFrame() -> (image: UIImage?, delay: Double) {
        guard let source, CGImageSourceGetCount(source) > 0 else { return (nil, 0.1) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let delay =
            (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
            ?? (png?[kCGImagePropertyAPNGDelayTime] as? Double) ?? 0.1
        let image = CGImageSourceCreateThumbnailAtIndex(
            source, index,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        index = (index + 1) % CGImageSourceGetCount(source)
        return (image.map { UIImage(cgImage: $0) }, delay.isFinite ? max(0.02, delay) : 0.1)
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
