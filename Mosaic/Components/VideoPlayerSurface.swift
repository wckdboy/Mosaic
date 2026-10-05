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
    var onTap: () -> Void = {}
    var onDoubleTap: (PlaybackMath.Zone) -> Void = { _ in }
    var onHold: (Bool) -> Void = { _ in }
    var onPinch: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        let coordinator = context.coordinator
        coordinator.surface = self
        let double = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        single.require(toFail: double)
        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.4
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))
        for recognizer in [double, single, hold, pinch] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        pictureInPicture.attach(view.playerLayer)
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Video"
        view.accessibilityHint = "Double-tap to show or hide controls."
        return view
    }
    func updateUIView(_ view: PlayerLayerView, context: Context) {
        context.coordinator.surface = self
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if view.playerLayer.videoGravity != gravity {
            // Gravity is implicitly animated by Core Animation; that matches a pinch.
            view.playerLayer.videoGravity = gravity
        }
        view.gestureRecognizers?.forEach { $0.isEnabled = enabled }
    }
    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.surface?.pictureInPicture.detach(view.playerLayer)
        view.playerLayer.player = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: VideoPlayerSurface?
        @MainActor @objc func tap(_ recognizer: UITapGestureRecognizer) { surface?.onTap() }
        @MainActor @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let x = recognizer.location(in: view).x
            surface?.onDoubleTap(PlaybackMath.zone(x: x, width: view.bounds.width))
        }
        @MainActor @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began: surface?.onHold(true)
            case .ended, .cancelled, .failed: surface?.onHold(false)
            default: break
            }
        }
        @MainActor @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            if recognizer.scale > 1.08 { surface?.onPinch(true) } else if recognizer.scale < 0.92 {
                surface?.onPinch(false)
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
