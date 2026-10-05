import AVFoundation
import Photos
import UIKit

// Resolves one media reference into a display surface. Generation tokens discard
// late PhotoKit callbacks after paging; stop balances observers, files, and scopes.
@MainActor @Observable
final class MediaLoader {
    var image: UIImage?
    var livePhoto: PHLivePhoto?
    var animatedURL: URL?
    var player: AVPlayer?
    var error: String?
    var loading = true
    var preparingShare = false
    var shareError: String?
    var progress: Double = 0
    var fileURL: URL?
    private var access: FileAccess?
    private var request: PHImageRequestID?
    private var temporaryURL: URL?
    private var statusObservation: NSKeyValueObservation?
    private var ended: NSObjectProtocol?
    private var generation = UUID()
    var loop = false

    func load(_ item: MediaItem, position: Double, autoplay: Bool) async {
        let token = UUID()
        generation = token
        loading = true
        error = nil
        if item.isPhotoLibrary {
            guard
                let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.photoIdentifier], options: nil)
                    .firstObject
            else {
                fail("This item is no longer available in Photos.")
                return
            }
            if item.kind == .video {
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.progressHandler = { [weak self] value, _, _, _ in
                    Task { @MainActor in self?.progress = value }
                }
                request = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) {
                    [weak self] playerItem, info in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        if let playerItem {
                            self.configure(playerItem, position: position, autoplay: autoplay)
                        } else {
                            self.fail(
                                "Video could not be loaded. Check your connection if it is stored in iCloud.")
                        }
                    }
                }
            } else if item.kind == .livePhoto {
                let options = PHLivePhotoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                request = PHImageManager.default().requestLivePhoto(
                    for: asset, targetSize: CGSize(width: 2000, height: 2000), contentMode: .aspectFit,
                    options: options
                ) { [weak self] photo, info in
                    guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.livePhoto = photo
                        self.loading = false
                        if photo == nil { self.fail("Live Photo could not be loaded.") }
                    }
                }
            } else if item.kind == .animated {
                // Stream the original resource to disk; a large GIF must never be
                // materialized as one Data buffer before frame decoding begins.
                guard
                    let resource = PHAssetResource.assetResources(for: asset).first(where: {
                        $0.type == .photo || $0.type == .fullSizePhoto
                    })
                else {
                    fail("Animation could not be loaded.")
                    return
                }
                let url = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(
                    (item.name as NSString).pathExtension)
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                do {
                    try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<Void, Error>) in
                        PHAssetResourceManager.default().writeData(
                            for: resource, toFile: url, options: options
                        ) { error in
                            if let error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume()
                            }
                        }
                    }
                    guard generation == token, !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: url)
                        return
                    }
                    temporaryURL = url
                    animatedURL = url
                    fileURL = url
                    loading = false
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    if generation == token { fail("Animation could not be loaded.") }
                }
            } else {
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                request = PHImageManager.default().requestImage(
                    for: asset, targetSize: CGSize(width: 3200, height: 3200), contentMode: .aspectFit,
                    options: options
                ) { [weak self] image, info in
                    guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.image = image
                        self.loading = false
                        if image == nil {
                            self.fail(
                                "Photo could not be loaded. Check your connection if it is stored in iCloud.")
                        }
                    }
                }
            }
        } else {
            do {
                let access = try await Task.detached { try FileAccess(item: item) }.value
                guard generation == token, !Task.isCancelled else { return }
                self.access = access
                fileURL = access.url
                if item.kind == .video {
                    configure(AVPlayerItem(url: access.url), position: position, autoplay: autoplay)
                } else if item.kind == .animated {
                    animatedURL = access.url
                    loading = false
                } else {
                    let image = await Task.detached {
                        ThumbnailService.downsample(url: access.url, pixels: 4096)
                    }.value
                    guard generation == token else { return }
                    self.image = image
                    loading = false
                    if image == nil {
                        fail("iOS could not decode this image. You can open the original in another app.")
                    }
                }
            } catch {
                fail(
                    "This file could not be opened. Reconnect its provider or open it again from Files. \(error.localizedDescription)"
                )
            }
        }
    }

    func configure(_ item: AVPlayerItem, position: Double, autoplay: Bool) {
        let player = AVPlayer(playerItem: item)
        self.player = player
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* Playback still works without audio session customization. */  }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player?.currentItem === item else { return }
                if item.status == .failed {
                    self.fail(
                        "This video’s container or codec is not supported by the native player. Open the original in another app."
                    )
                } else if item.status == .readyToPlay {
                    self.loading = false
                }
            }
        }
        ended = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.loop {
                    await self.player?.seek(to: .zero)
                    self.player?.play()
                }
            }
        }
        Task { [weak self] in
            if position > 0, let duration = try? await item.asset.load(.duration),
                position < duration.seconds - 2
            {
                await player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
            }
            guard self?.player === player else { return }
            if autoplay { player.play() }
        }
    }
    // Export only after Share is tapped. The resource manager writes directly to
    // disk rather than loading a full-resolution video into memory.
    func prepareShare(_ item: MediaItem) async -> Bool {
        if fileURL != nil { return true }
        guard item.isPhotoLibrary, !preparingShare,
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.photoIdentifier], options: nil)
                .firstObject,
            let resource = PHAssetResource.assetResources(for: asset).first(where: {
                item.kind == .video
                    ? $0.type == .video || $0.type == .fullSizeVideo
                    : $0.type == .photo || $0.type == .fullSizePhoto
            })
        else { return image != nil }
        preparingShare = true
        shareError = nil
        defer { preparingShare = false }
        let token = generation
        let target = URL.temporaryDirectory.appending(path: UUID().uuidString).appendingPathExtension(
            (resource.originalFilename as NSString).pathExtension)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options) {
                    error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            guard generation == token else {
                try? FileManager.default.removeItem(at: target)
                return false
            }
            temporaryURL = target
            fileURL = target
            return true
        } catch {
            try? FileManager.default.removeItem(at: target)
            shareError = "The original could not be prepared for sharing. Check your connection."
            return false
        }
    }

    func fail(_ message: String) {
        error = message
        loading = false
    }
    func stop() {
        generation = UUID()
        if let request { PHImageManager.default().cancelImageRequest(request) }
        request = nil
        player?.pause()
        player = nil
        statusObservation = nil
        if let ended { NotificationCenter.default.removeObserver(ended) }
        ended = nil
        image = nil
        livePhoto = nil
        animatedURL = nil
        fileURL = nil
        access = nil
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        temporaryURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
