import AVFoundation
import Observation

// Transport enhancements are separate from media loading. One observer tracks the
// clock, A–B loop, and external captions; detach always balances its registration.
@MainActor @Observable
final class PlaybackTools {
    var currentTime: Double = 0
    var duration: Double = 0
    var speed: Float = 1
    var fill = false
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
    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var sleepTask: Task<Void, Never>?
    private var groupTask: Task<Void, Never>?
    private var seekingLoop = false
    private var selectionVersion = 0

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
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
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
        player = nil
        sleepTask?.cancel()
        sleepDeadline = nil
        groupTask?.cancel()
        audioGroup = nil
        subtitleGroup = nil
        loopStart = nil
        loopEnd = nil
        subtitles = []
        subtitleName = nil
        currentTime = 0
        duration = 0
        speed = 1
        seekingLoop = false
    }
    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        let length = player?.currentItem?.duration.seconds ?? 0
        duration = length.isFinite ? max(0, length) : 0
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
    func setSpeed(_ value: Float) {
        speed = value
        player?.defaultRate = value
        if player?.rate != 0 { player?.rate = value }
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = min(max(0, seconds), duration > 0 ? duration : seconds)
        player?.seek(
            to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero,
            toleranceAfter: .zero)
    }
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
            selectSubtitle(nil)
        } catch { message = "Could not read subtitles. Use a UTF-8 SRT or WebVTT file." }
    }
}
