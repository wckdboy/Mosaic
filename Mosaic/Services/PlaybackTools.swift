import AVFoundation
import Observation

// Transport state is separate from media loading. One periodic observer tracks the
// clock, buffering, A–B loop, and external captions; detach balances every
// registration. Scrubbing chases the finger with tolerant seeks and settles with
// one precise seek, so dragging stays fluid even on long or remote files.
@MainActor @Observable
final class PlaybackTools {
    var currentTime: Double = 0
    var duration: Double = 0
    var buffered: Double = 0
    var isPlaying = false
    var isBuffering = false
    var muted = false
    var speed: Float = 1
    var fill = false
    var scrubbing = false
    var scrubTime: Double = 0
    var boosting = false
    var loopStart: Double?
    var loopEnd: Double?
    var sleepDeadline: Date?
    var subtitles: [SubtitleCue] = []
    var subtitleName: String?
    var subtitleDelay: Double = 0
    var subtitlesEnabled = true
    var audioGroup: AVMediaSelectionGroup?
    var subtitleGroup: AVMediaSelectionGroup?
    var message: String?
    private(set) var attached = false
    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var sleepTask: Task<Void, Never>?
    private var groupTask: Task<Void, Never>?
    private var seekingLoop = false
    private var selectionVersion = 0
    // Chase-seek state: at most one seek in flight, the latest target queued.
    private var seekInFlight = false
    private var pendingSeek: Double?
    private var settling = false
    private var resumeAfterScrub = false

    var displayTime: Double { scrubbing ? scrubTime : currentTime }

    var caption: String? {
        guard subtitlesEnabled else { return nil }
        let time = currentTime - subtitleDelay
        // Binary search limits work even for multi-hour subtitle files.
        var lower = 0
        var upper = subtitles.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if subtitles[middle].start <= time { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0, time < subtitles[lower - 1].end else { return nil }
        return subtitles[lower - 1].text
    }

    func attach(_ player: AVPlayer?) {
        detach()
        guard let player else { return }
        self.player = player
        attached = true
        player.isMuted = muted
        player.defaultRate = speed
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self, self.player === player else { return }
                self.isPlaying = status != .paused
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
        }
        groupTask = Task {
            guard let item = player.currentItem else { return }
            let audio = try? await item.asset.loadMediaSelectionGroup(for: .audible)
            let captions = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled else { return }
            audioGroup = audio
            subtitleGroup = captions
        }
    }
    func detach() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player = nil
        attached = false
        // The sleep timer outlives paging: it pauses whichever video is playing when
        // it fires. Closing the viewer cancels it explicitly.
        groupTask?.cancel()
        audioGroup = nil
        subtitleGroup = nil
        loopStart = nil
        loopEnd = nil
        subtitles = []
        subtitleName = nil
        currentTime = 0
        duration = 0
        buffered = 0
        isPlaying = false
        isBuffering = false
        scrubbing = false
        boosting = false
        seekingLoop = false
        seekInFlight = false
        pendingSeek = nil
        settling = false
    }
    private func tick(_ seconds: Double) {
        guard seconds.isFinite, let item = player?.currentItem else { return }
        // A late tick from before a seek would make the scrubber jump backwards.
        if !scrubbing && !settling && currentTime != seconds { currentTime = seconds }
        let length = item.duration.seconds
        let total = length.isFinite ? max(0, length) : 0
        if duration != total { duration = total }
        let loaded = PlaybackMath.bufferedEnd(
            at: seconds,
            ranges: item.loadedTimeRanges.map { range in
                let value = range.timeRangeValue
                return (value.start.seconds, value.end.seconds)
            })
        if abs(buffered - loaded) > 0.05 { buffered = loaded }
        if let start = loopStart, let end = loopEnd, seconds >= end, !seekingLoop {
            seekingLoop = true
            player?.seek(
                to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] _ in
                Task { @MainActor in self?.seekingLoop = false }
            }
        }
    }

    // MARK: Transport

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            // Replaying from the end should not require a manual scrub to zero.
            if duration > 0, currentTime >= duration - 0.25 { seek(to: 0) }
            player.playImmediately(atRate: speed)
        } else {
            player.pause()
        }
    }
    func pause() { player?.pause() }
    func skip(by seconds: Double) {
        seek(to: (scrubbing ? scrubTime : currentTime) + seconds)
    }
    func setMuted(_ value: Bool) {
        muted = value
        player?.isMuted = value
    }
    func setSpeed(_ value: Float) {
        speed = value
        player?.defaultRate = value
        if player?.rate != 0, !boosting { player?.rate = value }
    }
    // Press-and-hold doubles speed temporarily; release restores the chosen rate.
    func beginBoost() {
        guard let player, isPlaying, !boosting else { return }
        boosting = true
        player.rate = max(2, speed)
    }
    func endBoost() {
        guard boosting else { return }
        boosting = false
        if let player, player.rate != 0 { player.rate = speed }
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite, let player else { return }
        let target = PlaybackMath.clamp(seconds, duration: duration)
        currentTime = target
        settling = true
        pendingSeek = nil
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor in if finished { self?.settling = false } }
        }
    }

    // MARK: Scrubbing

    func beginScrub() {
        guard let player, !scrubbing else { return }
        scrubbing = true
        scrubTime = currentTime
        resumeAfterScrub = player.timeControlStatus != .paused
        endBoost()
        player.pause()
    }
    func scrub(to seconds: Double) {
        guard scrubbing, seconds.isFinite else { return }
        scrubTime = PlaybackMath.clamp(seconds, duration: duration)
        pendingSeek = scrubTime
        if !seekInFlight { chase() }
    }
    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        seek(to: scrubTime)
        if resumeAfterScrub { player?.playImmediately(atRate: speed) }
        resumeAfterScrub = false
    }
    private func chase() {
        guard let target = pendingSeek, let player else {
            seekInFlight = false
            return
        }
        pendingSeek = nil
        seekInFlight = true
        // Keyframe-tolerant seeks keep the preview frame moving under the finger.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                if self.scrubbing { self.chase() }
            }
        }
    }

    // MARK: Advanced

    func stepFrame(_ count: Int) {
        player?.pause()
        player?.currentItem?.step(byCount: count)
    }
    func setLoopPoint() {
        if loopStart == nil {
            loopStart = currentTime
        } else if loopEnd == nil, let start = loopStart, currentTime > start + 0.25 {
            loopEnd = currentTime
        } else {
            loopStart = nil
            loopEnd = nil
        }
    }
    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes else {
            sleepDeadline = nil
            return
        }
        sleepDeadline = Date().addingTimeInterval(Double(minutes * 60))
        sleepTask = Task {
            do { try await Task.sleep(for: .seconds(minutes * 60)) } catch { return }
            player?.pause()
            sleepDeadline = nil
        }
    }
    func selectAudio(_ option: AVMediaSelectionOption) {
        if let audioGroup {
            player?.currentItem?.select(option, in: audioGroup)
            selectionVersion += 1
        }
    }
    func selectSubtitle(_ option: AVMediaSelectionOption?) {
        if let subtitleGroup {
            player?.currentItem?.select(option, in: subtitleGroup)
            selectionVersion += 1
        }
    }
    func isSelected(_ option: AVMediaSelectionOption, group: AVMediaSelectionGroup) -> Bool {
        _ = selectionVersion
        return player?.currentItem?.currentMediaSelection.selectedMediaOption(in: group) == option
    }
    var subtitlesOff: Bool {
        _ = selectionVersion
        let embedded = subtitleGroup.flatMap {
            player?.currentItem?.currentMediaSelection.selectedMediaOption(in: $0)
        }
        return embedded == nil && (subtitles.isEmpty || !subtitlesEnabled)
    }
    func loadSubtitles(from url: URL) async {
        do {
            let cues = try await Task.detached {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= 5 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                let text = try String(contentsOf: url, encoding: .utf8)
                return SubtitleCue.parse(text)
            }.value
            guard !cues.isEmpty else {
                message = "No valid SRT or WebVTT captions were found."
                return
            }
            subtitles = cues
            subtitleName = url.lastPathComponent
            subtitleDelay = 0
            subtitlesEnabled = true
            selectSubtitle(nil)
        } catch { message = "Could not read subtitles. Use a UTF-8 SRT or WebVTT file." }
    }
}

// Pure transport geometry and formatting, kept separate so it is unit-testable.
enum PlaybackMath {
    enum Zone: Equatable { case leading, center, trailing }

    // Double-tap regions follow the video app convention: outer thirds skip.
    static func zone(x: Double, width: Double) -> Zone {
        guard width > 0, x.isFinite else { return .center }
        let fraction = x / width
        return fraction < 1.0 / 3 ? .leading : fraction > 2.0 / 3 ? .trailing : .center
    }
    static func clamp(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
    }
    static func fraction(of seconds: Double, duration: Double) -> Double {
        guard duration > 0, duration.isFinite, seconds.isFinite else { return 0 }
        return min(1, max(0, seconds / duration))
    }
    static func time(at x: Double, width: Double, duration: Double) -> Double {
        guard width > 0, x.isFinite else { return 0 }
        return fraction(of: x / width * duration, duration: duration) * max(0, duration)
    }
    static func remainingLabel(_ seconds: Double, duration: Double) -> String {
        "-" + MediaItem.timeLabel(max(0, duration - clamp(seconds, duration: duration)))
    }
    // Only the loaded range that contains the playhead is meaningful to the viewer.
    static func bufferedEnd(at seconds: Double, ranges: [(start: Double, end: Double)]) -> Double {
        ranges.filter { $0.start.isFinite && $0.end.isFinite && $0.start <= seconds + 0.5 && $0.end >= seconds }
            .map(\.end).max() ?? 0
    }
}
