import AVKit
import SwiftUI
import UIKit

// A bare AVPlayerLayer lets the viewer draw one set of floating controls over
// full-bleed video instead of stacking its chrome on top of AVKit's. UIKit gesture
// recognizers resolve tap vs. double-tap vs. hold precisely, which SwiftUI's
// composed gestures cannot do without delaying or swallowing the pager drag.
struct VideoPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var fill = false
    var enabled = true
    let pictureInPicture: PictureInPictureModel
    var isZoomed: Binding<Bool> = .constant(false)
    var onTap: () -> Void = {}
    var onDoubleTap: (PlaybackMath.Zone) -> Void = { _ in }
    var onHold: (Bool) -> Void = { _ in }
    var onZoomInteraction: (Bool) -> Void = { _ in }
    var onFillChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }
    // The player layer sits inside the shared zoom container: pinch zooms and pans the
    // picture, and "fill" is simply the zoom that covers the screen.
    func makeUIView(context: Context) -> ZoomScrollView {
        let layerView = PlayerLayerView()
        layerView.playerLayer.player = player
        layerView.playerLayer.videoGravity = .resizeAspect
        let view = ZoomScrollView(content: layerView)
        // Double-tap skips in video, so the container's own taps stay off.
        view.doubleTap.isEnabled = false
        view.singleTap.isEnabled = false
        let coordinator = context.coordinator
        coordinator.surface = self
        let double = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        single.require(toFail: double)
        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.4
        for recognizer in [double, single, hold] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        coordinator.observe(player, in: view)
        pictureInPicture.attach(layerView.playerLayer)
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Video"
        view.accessibilityIdentifier = "viewer.video"
        view.accessibilityHint = "Double-tap to show or hide controls. Pinch to zoom."
        apply(to: view, coordinator: coordinator, animated: false)
        return view
    }
    func updateUIView(_ view: ZoomScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.surface = self
        if let layerView = view.content as? PlayerLayerView, layerView.playerLayer.player !== player {
            layerView.playerLayer.player = player
            coordinator.observe(player, in: view)
        }
        apply(to: view, coordinator: coordinator, animated: true)
        view.gestureRecognizers?.forEach { recognizer in
            if recognizer !== view.doubleTap && recognizer !== view.singleTap { recognizer.isEnabled = enabled }
        }
    }
    private func apply(to view: ZoomScrollView, coordinator: Coordinator, animated: Bool) {
        let binding = isZoomed
        view.onZoomChange = { zoomed in if binding.wrappedValue != zoomed { binding.wrappedValue = zoomed } }
        view.onInteraction = onZoomInteraction
        let fillChanged = onFillChange
        view.onFillChange = { [weak coordinator] fill in
            coordinator?.appliedFill = fill
            fillChanged(fill)
        }
        if coordinator.appliedFill != fill {
            coordinator.appliedFill = fill
            view.setFill(fill, animated: animated && !UIAccessibility.isReduceMotionEnabled)
        }
    }
    static func dismantleUIView(_ view: ZoomScrollView, coordinator: Coordinator) {
        coordinator.sizeObservation = nil
        if let layerView = view.content as? PlayerLayerView {
            coordinator.surface?.pictureInPicture.detach(layerView.playerLayer)
            layerView.playerLayer.player = nil
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: VideoPlayerSurface?
        var appliedFill: Bool?
        var sizeObservation: NSKeyValueObservation?
        // The fitted frame follows the video's real aspect ratio once it is known.
        @MainActor func observe(_ player: AVPlayer, in view: ZoomScrollView) {
            sizeObservation = player.currentItem?.observe(\.presentationSize, options: [.initial, .new]) {
                [weak view] item, _ in
                let size = item.presentationSize
                Task { @MainActor in
                    guard let view, size.width > 0, size.height > 0 else { return }
                    view.naturalSize = size
                }
            }
        }
        @MainActor @objc func tap(_ recognizer: UITapGestureRecognizer) { surface?.onTap() }
        @MainActor @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let x = recognizer.location(in: view).x - view.bounds.minX
            surface?.onDoubleTap(PlaybackMath.zone(x: x, width: view.bounds.width))
        }
        @MainActor @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began: surface?.onHold(true)
            case .ended, .cancelled, .failed: surface?.onHold(false)
            default: break
            }
        }
        // The page drag lives in SwiftUI; never let these recognizers block it.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { !(other is UITapGestureRecognizer) }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer {
        // layerClass guarantees the type.
        layer as! AVPlayerLayer  // swiftlint:disable:this force_cast
    }
}

// Owns the system PiP controller for the current player layer. Automatic start lets
// leaving the app continue a playing video in a floating window.
@MainActor @Observable
final class PictureInPictureModel: NSObject, AVPictureInPictureControllerDelegate {
    private(set) var isPossible = false
    private(set) var isActive = false
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(_ layer: AVPlayerLayer) {
        guard Self.isSupported, controller?.playerLayer !== layer else { return }
        detachController()
        guard let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        self.controller = controller
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
            [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
    }
    func detach(_ layer: AVPlayerLayer) {
        guard controller?.playerLayer === layer else { return }
        detachController()
    }
    private func detachController() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        controller?.stopPictureInPicture()
        controller?.delegate = nil
        controller = nil
        isPossible = false
        isActive = false
    }
    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in self.isActive = true }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in self.isActive = false }
    }
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        // The viewer stays presented while PiP runs, so its inline layer is ready.
        completionHandler(true)
    }
}
