import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// Advanced playback remains one tap away without crowding the transport controls.
struct PlaybackOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var tools: PlaybackTools
    @Bindable var loader: MediaLoader
    @State private var importingSubtitles = false
    @State private var jumpTime = ""
    let lockControls: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Picker("Speed", selection: Binding(get: { tools.speed }, set: { tools.setSpeed($0) })) {
                        ForEach([Float(0.25), 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3], id: \.self) {
                            Text(String(format: "%g×", $0)).tag($0)
                        }
                    }
                    Toggle("Fill screen", isOn: $tools.fill)
                    Toggle("Repeat video", isOn: $loader.loop)
                    Button("Lock controls", systemImage: "lock") {
                        dismiss()
                        lockControls()
                    }
                }
                Section("Precision") {
                    HStack {
                        TextField("Jump to 1:23 or 83 seconds", text: $jumpTime).keyboardType(
                            .numbersAndPunctuation)
                        Button("Go") {
                            let seconds = Double(jumpTime) ?? SubtitleCue.timestamp(jumpTime)
                            if let seconds {
                                tools.seek(to: seconds)
                                dismiss()
                            }
                        }.disabled(Double(jumpTime) == nil && SubtitleCue.timestamp(jumpTime) == nil)
                    }
                    HStack {
                        Button("Previous frame", systemImage: "backward.frame") { tools.stepFrame(-1) }
                        Spacer()
                        Button("Next frame", systemImage: "forward.frame") { tools.stepFrame(1) }
                    }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    Button(
                        tools.loopStart == nil
                            ? "Set repeat start (A)"
                            : tools.loopEnd == nil ? "Set repeat end (B)" : "Clear A–B repeat"
                    ) { tools.setLoopPoint() }
                    if let start = tools.loopStart {
                        LabeledContent(
                            "A–B repeat",
                            value:
                                "\(MediaItem.timeLabel(start)) → \(tools.loopEnd.map(MediaItem.timeLabel) ?? "…")"
                        )
                    }
                }
                Section("Sleep timer") {
                    Menu(
                        tools.sleepDeadline.map {
                            "Stops at \($0.formatted(date: .omitted, time: .shortened))"
                        } ?? "Off"
                    ) {
                        Button("Off") { tools.setSleepTimer(minutes: nil) }
                        ForEach([5, 15, 30, 60, 90], id: \.self) { minutes in
                            Button("\(minutes) minutes") { tools.setSleepTimer(minutes: minutes) }
                        }
                    }
                }
                if let group = tools.audioGroup, !group.options.isEmpty {
                    Section("Audio track") {
                        ForEach(group.options, id: \.self) { option in
                            Button {
                                tools.selectAudio(option)
                            } label: {
                                HStack {
                                    Text(option.displayName)
                                    Spacer()
                                    if tools.isSelected(option, group: group) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
                Section("Subtitles") {
                    if let group = tools.subtitleGroup {
                        Button("Off") { tools.selectSubtitle(nil) }
                        ForEach(group.options, id: \.self) { option in
                            Button {
                                tools.selectSubtitle(option)
                                tools.subtitles = []
                                tools.subtitleName = nil
                            } label: {
                                HStack {
                                    Text(option.displayName)
                                    Spacer()
                                    if tools.isSelected(option, group: group) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    Button("Open subtitle file…", systemImage: "doc.badge.plus") { importingSubtitles = true }
                    if let name = tools.subtitleName {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                        Toggle("Show captions", isOn: $tools.subtitlesEnabled)
                        Stepper(
                            "Delay: \(tools.subtitleDelay, specifier: "%.1f") s", value: $tools.subtitleDelay,
                            in: -30...30, step: 0.1)
                        Button("Remove subtitle file") {
                            tools.subtitles = []
                            tools.subtitleName = nil
                        }
                    }
                    if let message = tools.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.accentColor).navigationTitle("Playback").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $importingSubtitles, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { Task { await tools.loadSubtitles(from: url) } }
            }
        }.presentationDetents([.medium, .large])
    }
}
