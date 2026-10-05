import AVFoundation
import SwiftUI

// The viewer owns one active media load and one transport controller. Paging saves
// position, cancels the old load, and releases its file-provider security scope.
struct MediaViewer: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let items: [MediaItem]
    let initialID: String
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index: Int
    @State private var playback = PlaybackTools()
    @State private var locked = false
    @State private var isZoomed = false
    @State private var surfaceSize = CGSize.zero
    @State private var dragOffset = CGSize.zero
    @AppStorage("galleryDirection") private var galleryDirection = "vertical"
    @AppStorage("skipInterval") private var skipInterval = 10
    @State private var loader = MediaLoader()
    @State private var loadedID: String?
    @State private var mediaTask: Task<Void, Never>?
    private enum Sheet: String, Identifiable {
        case info, organize, share, playback, similar
        var id: String { rawValue }
    }
    @State private var sheet: Sheet?
    @State private var hiddenControls = false
    @AppStorage("autoplay") private var autoplay = true
    @AppStorage("resumePlayback") private var resumePlayback = true
    private var item: MediaItem? { items.indices.contains(index) ? items[index] : nil }

    init(items: [MediaItem], initialID: String) {
        self.items = items
        self.initialID = initialID
        _index = State(initialValue: items.firstIndex(where: { $0.id == initialID }) ?? 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item {
                media
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGSize.self) {
                        $0.size
                    } action: {
                        surfaceSize = $0
                    }
                    .offset(dragOffset)
                    .contentShape(Rectangle())
                    .simultaneousGesture(swipeGesture)
                    .overlay(alignment: .bottom) {
                        if let caption = playback.caption {
                            Text(caption).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                                .foregroundStyle(.white).padding(8).background(
                                    .black.opacity(0.75), in: .rect(cornerRadius: 8)
                                )
                                .padding(.horizontal, 24).padding(.bottom, 70).allowsHitTesting(false)
                        }
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded { if item.kind != .video && !locked { hiddenControls.toggle() } }
                    )
                if loader.loading {
                    ProgressView(loader.progress > 0 ? "Loading \(Int(loader.progress * 100))%" : "Opening…")
                        .tint(.white).foregroundStyle(.white).padding(24).background(
                            .black.opacity(0.6), in: .rect(cornerRadius: 20))
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { if !hiddenControls && !locked { topBar } }
        .safeAreaInset(edge: .bottom, spacing: 0) { if !hiddenControls && !locked { bottomBar } }
        .preferredColorScheme(.dark)
        .statusBarHidden(hiddenControls)
        .overlay(alignment: .topTrailing) {
            if locked {
                Button("Unlock", systemImage: "lock.open") { locked = false }
                    .buttonStyle(.glass).padding(20)
            }
        }
        .onChange(of: loader.player) { _, player in playback.attach(player) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { savePosition() } }
        .task(id: item?.id) {
            guard let item, loadedID != item.id else { return }
            loadedID = item.id
            // The load belongs to the viewer session, not a transient SwiftUI
            // appearance task that a full-screen options panel can cancel.
            mediaTask?.cancel()
            mediaTask = Task {
                await loader.load(
                    item, position: resumePlayback ? store.position(for: item.id) : 0, autoplay: autoplay)
            }
        }
        .onDisappear {
            // A presented panel must retain playback, scopes and prepared share files.
            guard sheet == nil else { return }
            loadedID = nil
            mediaTask?.cancel()
            savePosition()
            playback.detach()
            loader.stop()
        }
        .fullScreenCover(item: $sheet) { destination in
            switch destination {
            case .similar: if let item { SimilarMediaView(seed: item) }
            case .info: if let item { metadata(item) }
            case .organize: if let item { OrganizeSheet(selection: [item.id]) }
            case .share:
                if let url = loader.fileURL {
                    ShareSheet(items: [url])
                } else if let image = loader.image {
                    ShareSheet(items: [image])
                }
            case .playback: PlaybackOptionsView(tools: playback, loader: loader) { locked = true }
            }
        }
        .accessibilityAction(named: "Next item") { move(1) }
        .accessibilityAction(named: "Previous item") { move(-1) }
    }
    @ViewBuilder private var media: some View {
        if let error = loader.error {
            ContentUnavailableView {
                Label("Unable to open media", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                if loader.fileURL != nil {
                    Button("Open in another app", systemImage: "square.and.arrow.up") { sheet = .share }
                        .buttonStyle(.glass)
                }
            }
        } else if let player = loader.player {
            NativeVideoPlayer(player: player, fill: playback.fill, locked: locked)
        } else if let photo = loader.livePhoto {
            LivePhotoSurface(photo: photo)
        } else if let url = loader.animatedURL {
            AnimatedImageSurface(url: url)
        } else if let image = loader.image {
            ZoomableImage(image: image, isZoomed: $isZoomed)
        }
    }
    private var topBar: some View {
        HStack(spacing: 16) {
            Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).buttonStyle(.glass)
                .buttonBorderShape(.circle).controlSize(.large)
            VStack(spacing: 3) {
                Text(item?.date.formatted(date: .abbreviated, time: .omitted) ?? "").font(
                    .subheadline.weight(.semibold))
                Text(item?.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity)
            if item?.kind == .video {
                Button("Playback options", systemImage: "slider.horizontal.3") { sheet = .playback }
                    .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
            }
            Menu {
                Button("Add to collection", systemImage: "rectangle.stack.badge.plus") { sheet = .organize }
                Button("Details", systemImage: "info.circle") { sheet = .info }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Media options").buttonStyle(.glass)
            .buttonBorderShape(.circle).controlSize(.large)
        }.padding(.horizontal, 18).padding(.vertical, 12).background(.black)
    }
    private var bottomBar: some View {
        VStack(spacing: 16) {
            if item?.kind == .video, loader.player != nil {
                HStack(spacing: 24) {
                    Button("Back \(skipInterval) seconds", systemImage: "gobackward.\(skipInterval)") {
                        seek(-Double(skipInterval))
                    }
                    Button(loader.loop ? "Loop on" : "Loop off", systemImage: "repeat") {
                        loader.loop.toggle()
                    }
                    .foregroundStyle(loader.loop ? Color.accentColor : .white)
                    Button("Forward \(skipInterval) seconds", systemImage: "goforward.\(skipInterval)") {
                        seek(Double(skipInterval))
                    }
                }.labelStyle(.iconOnly).buttonStyle(MediaControlButtonStyle()).font(.title3).padding(8)
                    .glassEffect()
            }
            HStack {
                Button("Previous", systemImage: "chevron.left") { move(-1) }.disabled(index == 0)
                Spacer()
                Button("Share", systemImage: "square.and.arrow.up") {
                    if let item { Task { if await loader.prepareShare(item) { sheet = .share } } }
                }.disabled(loader.preparingShare || loader.loading)
                    .overlay { if loader.preparingShare { ProgressView() } }
                Spacer()
                Button(
                    store.favorites.contains(item?.id ?? "") ? "Unfavorite" : "Favorite",
                    systemImage: store.favorites.contains(item?.id ?? "") ? "heart.fill" : "heart"
                ) {
                    if let item { store.toggleFavorite(item.id) }
                }
                Spacer()
                Button("Find similar", systemImage: "square.on.square") {
                    loader.player?.pause()
                    sheet = .similar
                }
                Spacer()
                Button("Next", systemImage: "chevron.right") { move(1) }.disabled(index + 1 >= items.count)
            }.labelStyle(.iconOnly).font(.title3).buttonStyle(MediaControlButtonStyle()).padding(18)
                .glassEffect()
            if let shareError = loader.shareError {
                Text(shareError).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(index + 1) of \(items.count)").font(.caption2).foregroundStyle(.secondary)
                .monospacedDigit()
        }.padding(.horizontal, 20).padding(.bottom, 8).padding(.top, 12).background(.black)
    }
    // Only the configured axis pages. Zoomed images retain pan gestures, and the
    // video transport's bottom region retains scrubbing instead of changing media.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard canSwipe(value), item?.kind != .video, !reduceMotion else { return }
                dragOffset =
                    galleryDirection == "horizontal"
                    ? CGSize(width: value.translation.width * 0.25, height: 0)
                    : CGSize(width: 0, height: value.translation.height * 0.25)
            }
            .onEnded { value in
                defer { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { dragOffset = .zero } }
                guard canSwipe(value) else { return }
                let distance =
                    galleryDirection == "horizontal" ? value.translation.width : value.translation.height
                let crossAxis =
                    galleryDirection == "horizontal" ? value.translation.height : value.translation.width
                if abs(distance) > 70 && abs(distance) > abs(crossAxis) * 1.5 { move(distance < 0 ? 1 : -1) }
            }
    }
    private func canSwipe(_ value: DragGesture.Value) -> Bool {
        guard !locked, !isZoomed, sheet == nil else { return false }
        if item?.kind == .video { return value.startLocation.y < surfaceSize.height * 0.65 }
        return true
    }

    private func savePosition() {
        guard let item, let player = loader.player else { return }
        let time = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        store.rememberPosition(duration.isFinite && time >= duration - 2 ? 0 : time, for: item.id)
    }
    private func move(_ offset: Int) {
        guard items.indices.contains(index + offset) else { return }
        mediaTask?.cancel()
        savePosition()
        playback.detach()
        loader.stop()
        isZoomed = false
        index += offset
    }
    private func seek(_ seconds: Double) {
        guard let player = loader.player else { return }
        let target = max(0, player.currentTime().seconds + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }
    private func metadata(_ item: MediaItem) -> some View {
        NavigationStack {
            Form {
                Section("Media") {
                    LabeledContent("Name", value: item.name)
                    if let original = item.originalName {
                        LabeledContent("Original filename", value: original)
                    }
                    LabeledContent("Type", value: item.kind.title)
                    LabeledContent("Created", value: item.date.formatted())
                    if item.width > 0 {
                        LabeledContent("Dimensions", value: "\(item.width) × \(item.height)")
                    }
                    if item.duration > 0 { LabeledContent("Duration", value: item.durationLabel) }
                    LabeledContent("Source", value: item.isPhotoLibrary ? "Photos" : "Files")
                }
                if item.kind == .livePhoto { Text("Touch and hold the photo to play its motion and sound.") }
            }.navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { sheet = nil } }
        }.presentationDetents([.medium, .large])
    }
}
