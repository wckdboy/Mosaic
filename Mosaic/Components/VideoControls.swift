import AVFoundation
import SwiftUI

// Each control reads PlaybackTools in its own view, so the 10 Hz clock only
// re-renders the scrubber and captions, never the whole viewer hierarchy.
struct VideoTransport: View {
    let tools: PlaybackTools
    let skipInterval: Int
    let onInteract: () -> Void
    var body: some View {
        HStack(spacing: 40) {
            GlassCircleButton(
                title: "Back \(skipInterval) seconds", symbol: "gobackward.\(skipInterval)", size: 26,
                diameter: 60
            ) {
                tools.skip(by: -Double(skipInterval))
                onInteract()
            }
            ZStack {
                if tools.scrubbing {
                    Text(MediaItem.timeLabel(tools.scrubTime))
                        .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        .frame(width: 84, height: 84).glassEffect(.regular, in: .circle)
                        .accessibilityHidden(true)
                } else if tools.isBuffering {
                    ProgressView().controlSize(.large).tint(.white)
                        .frame(width: 84, height: 84).glassEffect(.regular, in: .circle)
                        .accessibilityLabel("Buffering")
                } else {
                    GlassCircleButton(
                        title: tools.isPlaying ? "Pause" : "Play",
                        symbol: tools.isPlaying ? "pause.fill" : "play.fill", size: 34, diameter: 84
                    ) {
                        tools.togglePlay()
                        onInteract()
                    }
                    .accessibilityIdentifier("viewer.playPause")
                }
            }
            GlassCircleButton(
                title: "Forward \(skipInterval) seconds", symbol: "goforward.\(skipInterval)", size: 26,
                diameter: 60
            ) {
                tools.skip(by: Double(skipInterval))
                onInteract()
            }
        }
        .foregroundStyle(.white)
    }
}

// The whole glass disc is the hit target, not just the glyph inside it.
struct GlassCircleButton: View {
    let title: String
    let symbol: String
    var size: CGFloat = 20
    var diameter: CGFloat = 44
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter).contentShape(.circle)
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(title)
    }
}

// A tall invisible hit area around a thin track: easy to grab, quiet to look at.
// Touching anywhere jumps there; dragging chases with tolerant seeks.
struct VideoScrubber: View {
    let tools: PlaybackTools
    let skipInterval: Int
    let onInteract: () -> Void
    @AppStorage("showRemainingTime") private var showRemaining = true
    var body: some View {
        let time = tools.displayTime
        let duration = tools.duration
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let progress = PlaybackMath.fraction(of: time, duration: duration)
                let loaded = PlaybackMath.fraction(of: tools.buffered, duration: duration)
                let knob: CGFloat = tools.scrubbing ? 20 : 12
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(0.32)).frame(width: width * loaded)
                    Capsule().fill(.white).frame(width: width * progress)
                }
                .frame(height: tools.scrubbing ? 8 : 4)
                .overlay(alignment: .leading) {
                    Circle().fill(.white).frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.3), radius: 3)
                        .offset(x: min(max(0, width * progress - knob / 2), width - knob))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            tools.beginScrub()
                            tools.scrub(
                                to: PlaybackMath.time(
                                    at: value.location.x, width: width, duration: duration))
                            onInteract()
                        }
                        .onEnded { _ in
                            tools.endScrub()
                            onInteract()
                        }
                )
                .animation(.spring(duration: 0.2), value: tools.scrubbing)
            }
            .frame(height: 36)
            HStack {
                Text(MediaItem.timeLabel(time))
                Spacer()
                Text(
                    showRemaining
                        ? PlaybackMath.remainingLabel(time, duration: duration)
                        : MediaItem.timeLabel(duration)
                )
                .onTapGesture { showRemaining.toggle() }
            }
            .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
        }
        .shadow(color: .black.opacity(0.35), radius: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(MediaItem.timeLabel(time)) of \(MediaItem.timeLabel(duration))")
        .accessibilityIdentifier("viewer.scrubber")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: tools.skip(by: Double(skipInterval))
            case .decrement: tools.skip(by: -Double(skipInterval))
            @unknown default: break
            }
            onInteract()
        }
    }
}

// Frequently changed video settings stay one tap away; the rest live in Playback options.
struct VideoQuickRow: View {
    @Bindable var tools: PlaybackTools
    let pictureInPicture: PictureInPictureModel
    let onOpenSubtitles: () -> Void
    let onInteract: () -> Void
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    private var speedLabel: String { String(format: "%g×", tools.speed) }
    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Picker(
                    "Speed",
                    selection: Binding(
                        get: { tools.speed },
                        set: {
                            tools.setSpeed($0)
                            onInteract()
                        })
                ) {
                    ForEach(Self.speeds, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
            } label: {
                Text(speedLabel).font(.footnote.weight(.bold)).monospacedDigit()
                    .frame(minWidth: 44, minHeight: 36).padding(.horizontal, 4)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .accessibilityLabel("Playback speed").accessibilityValue(speedLabel)
            captionsMenu
            Spacer()
            if PictureInPictureModel.isSupported {
                iconButton(
                    pictureInPicture.isActive ? "Exit Picture in Picture" : "Picture in Picture",
                    symbol: pictureInPicture.isActive ? "pip.exit" : "pip.enter"
                ) { pictureInPicture.toggle() }
                .disabled(!pictureInPicture.isPossible)
            }
            iconButton(
                tools.muted ? "Unmute" : "Mute",
                symbol: tools.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            ) { tools.setMuted(!tools.muted) }
            .accessibilityIdentifier("viewer.mute")
        }
        .buttonStyle(.plain).font(.body.weight(.semibold)).foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 4)
    }
    // The label, not just the glyph, carries the 44-point hit target.
    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteract()
        } label: {
            Image(systemName: symbol).contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44).contentShape(.rect)
        }
        .accessibilityLabel(title)
    }
    private var captionsMenu: some View {
        Menu {
            if let group = tools.subtitleGroup, !group.options.isEmpty {
                Picker(
                    "Subtitles",
                    selection: Binding<AVMediaSelectionOption?>(
                        get: { group.options.first { tools.isSelected($0, group: group) } },
                        set: { option in
                            tools.selectSubtitle(option)
                            if option != nil {
                                tools.subtitles = []
                                tools.subtitleName = nil
                            }
                            onInteract()
                        })
                ) {
                    Text("Off").tag(AVMediaSelectionOption?.none)
                    ForEach(group.options, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
            }
            if let name = tools.subtitleName {
                Toggle(name, systemImage: "captions.bubble", isOn: $tools.subtitlesEnabled)
            }
            Button("Open subtitle file…", systemImage: "doc.badge.plus") { onOpenSubtitles() }
            if let group = tools.audioGroup, group.options.count > 1 {
                Picker(
                    "Audio",
                    selection: Binding<AVMediaSelectionOption?>(
                        get: { group.options.first { tools.isSelected($0, group: group) } },
                        set: { option in
                            if let option { tools.selectAudio(option) }
                            onInteract()
                        })
                ) {
                    ForEach(group.options, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
            }
        } label: {
            Image(systemName: tools.subtitlesOff ? "captions.bubble" : "captions.bubble.fill")
                .frame(width: 44, height: 44).contentShape(.rect)
        }
        .accessibilityLabel("Subtitles and audio")
    }
}

// External SRT/WebVTT captions render above the controls, never under them.
struct CaptionOverlay: View {
    let tools: PlaybackTools
    let raised: Bool
    var body: some View {
        if let caption = tools.caption {
            Text(caption).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.7), in: .rect(cornerRadius: 8))
                // Clears the bottom control cluster (transport, quick row, scrubber, actions).
                .padding(.horizontal, 24).padding(.bottom, raised ? 300 : 40)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: raised)
        }
    }
}

// Double-tap feedback accumulates like a video app: "« 30 s" after three taps.
struct SkipFeedback: Equatable {
    let id = UUID()
    let zone: PlaybackMath.Zone
    let seconds: Int
}

struct SkipFeedbackBadge: View {
    let feedback: SkipFeedback
    var body: some View {
        let forward = feedback.zone == .trailing
        Label(
            "\(feedback.seconds) s",
            systemImage: forward ? "forward.fill" : "backward.fill"
        )
        .labelStyle(SkipLabelStyle(forward: forward))
        .font(.headline).monospacedDigit().foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .accessibilityHidden(true)
    }
    private struct SkipLabelStyle: LabelStyle {
        let forward: Bool
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) {
                if forward {
                    configuration.title
                    configuration.icon
                } else {
                    configuration.icon
                    configuration.title
                }
            }
        }
    }
}
