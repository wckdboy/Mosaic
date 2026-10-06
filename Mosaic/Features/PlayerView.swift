import AVFoundation
import SwiftUI

// The viewer owns one active media load and one transport controller. Neighbors
// are drawn from cached thumbnails, so paging follows the finger immediately while
// only the settled page decodes full media or holds an AVPlayer. Chrome floats over
// full-bleed media and fades away during playback; swipe down closes, up shows details.
struct MediaViewer: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let items: [MediaItem]
    let initialID: String
    private var compactHeight: Bool { verticalSizeClass == .compact }
    @State private var index: Int
    @State private var loader = MediaLoader()
    @State private var playback = PlaybackTools()
    @State private var pictureInPicture = PictureInPictureModel()
    @State private var loadedID: String?
    @State private var mediaTask: Task<Void, Never>?
    @State private var chromeVisible = true
    @State private var interaction = 0
    @State private var locked = false
    @State private var isZoomed = false
    // True while two fingers are pinching, before zoom state settles.
    @State private var zoomInteracting = false
    @State private var pageOffset: CGFloat = 0
    @State private var dismissOffset = CGSize.zero
    @State private var dragAxis: DragAxis?
    @GestureState private var dragging = false
    @State private var closing = false
    @State private var skipFeedback: SkipFeedback?
    @State private var showSpinner = false
    @State private var sheet: Sheet?
    @State private var similarSeed: MediaItem?
    @State private var importingSubtitles = false
    @AppStorage("skipInterval") private var skipInterval = 10
    @AppStorage("autoplay") private var autoplay = true
    @AppStorage("resumePlayback") private var resumePlayback = true
    private enum Sheet: String, Identifiable {
        case info, organize, share, playback
        var id: String { rawValue }
    }
    private enum DragAxis { case horizontal, down, up }
    private struct AutoHideKey: Equatable {
        let visible: Bool
        let playing: Bool
        let scrubbing: Bool
        let interaction: Int
        let blocked: Bool
    }
    private let pageGap: CGFloat = 16
    private var item: MediaItem? { items.indices.contains(index) ? items[index] : nil }
    private var isVideo: Bool { item?.kind == .video }
    private var pagingEnabled: Bool {
        !locked && !isZoomed && !zoomInteracting && !playback.scrubbing && !playback.boosting && sheet == nil && !closing
    }

    init(items: [MediaItem], initialID: String) {
        self.items = items
        self.initialID = initialID
        _index = State(initialValue: items.firstIndex(where: { $0.id == initialID }) ?? 0)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(backdropOpacity).ignoresSafeArea()
            GeometryReader { geometry in pager(geometry.size) }
                .ignoresSafeArea()
            chrome
            overlays
        }
        // The clear presentation background reveals the library during a swipe-down,
        // so assistive technologies must be told the library behind is out of reach.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        .statusBarHidden(!chromeVisible || locked)
        .persistentSystemOverlays(chromeVisible && !locked ? .automatic : .hidden)
        .onChange(of: loader.player) { _, player in playback.attach(player) }
        .onChange(of: playback.isPlaying) { _, playing in
            // A finished video brings its controls back for replay or the next item.
            if !playing, playback.duration > 0, playback.currentTime >= playback.duration - 0.3 {
                setChrome(true)
            }
        }
        .onChange(of: dragging) { _, active in
            // A system-cancelled drag never reaches onEnded; settle it here instead.
            guard !active, dragAxis != nil else { return }
            dragAxis = nil
            withAnimation(snap) {
                pageOffset = 0
                dismissOffset = .zero
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { savePosition() }
            // PiP continues in the background; otherwise playback stops with the app.
            if phase == .background && !pictureInPicture.isActive { playback.pause() }
        }
        .task(id: item?.id) {
            guard let item, loadedID != item.id else { return }
            loadedID = item.id
            // The load belongs to the viewer session, not a transient SwiftUI
            // appearance task that a presented panel can cancel.
            mediaTask?.cancel()
            mediaTask = Task {
                await loader.load(
                    item, position: resumePlayback ? store.position(for: item.id) : 0, autoplay: autoplay)
            }
        }
        .task(id: loader.loading) {
            // Fast local loads never flash a spinner over the preview.
            showSpinner = false
            guard loader.loading else { return }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            showSpinner = loader.loading
        }
        .task(id: autoHideKey) {
            guard shouldAutoHide else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if shouldAutoHide { setChrome(false) }
        }
        .task(id: skipFeedback?.id) {
            guard skipFeedback != nil else { return }
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            withAnimation(.easeOut(duration: 0.2)) { skipFeedback = nil }
        }
        .task {
            // Background analysis yields the CPU and Neural Engine while media is on
            // screen; decoding video and indexing together is what warms a phone.
            MosaicIndexer.shared.hold()
            defer { MosaicIndexer.shared.release() }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        }
        .onDisappear {
            // A presented panel must retain playback, scopes and prepared share files.
            guard sheet == nil, similarSeed == nil else { return }
            loadedID = nil
            mediaTask?.cancel()
            savePosition()
            playback.detach()
            loader.stop()
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .info: if let item { metadata(item) }
            case .organize: if let item { OrganizeSheet(selection: [item.id]) }
            case .share:
                Group {
                    if let url = loader.fileURL {
                        ShareSheet(items: [url])
                    } else if let image = loader.image {
                        ShareSheet(items: [image])
                    }
                }
                .presentationDetents([.medium, .large]).ignoresSafeArea()
            case .playback: PlaybackOptionsView(tools: playback, loader: loader) { lock() }
            }
        }
        .fullScreenCover(item: $similarSeed) { SimilarMediaView(seed: $0) }
        .fileImporter(isPresented: $importingSubtitles, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await playback.loadSubtitles(from: url) } }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: playback.boosting) { _, new in new }
    }

    // MARK: Pager

    private func pager(_ size: CGSize) -> some View {
        let stride = size.width + pageGap
        let range = items.isEmpty ? [] : Array(max(0, index - 1)...min(items.count - 1, index + 1))
        return ZStack {
            ForEach(range, id: \.self) { position in
                Group {
                    if position == index { currentPage } else { ViewerPreview(item: items[position]) }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
                .offset(x: CGFloat(position - index) * stride + pageOffset)
                .accessibilityHidden(position != index)
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(dismissScale(size))
        .offset(dismissOffset)
        .contentShape(Rectangle())
        .simultaneousGesture(pageDrag(size), including: pagingEnabled ? .all : .subviews)
        .accessibilityScrollAction { edge in
            switch edge {
            case .trailing, .bottom: page(1, stride: stride)
            case .leading, .top: page(-1, stride: stride)
            }
        }
    }

    @ViewBuilder private var currentPage: some View {
        if let item {
            ZStack {
                if !mediaReady { ViewerPreview(item: item).onTapGesture { toggleChrome() } }
                media(item)
                if showSpinner && loader.error == nil {
                    ProgressView(
                        loader.progress > 0 ? "Downloading \(Int(loader.progress * 100))%" : "Opening…"
                    )
                    .tint(.white).foregroundStyle(.white).font(.footnote)
                    .padding(18).glassEffect(.regular, in: .rect(cornerRadius: 18))
                    .allowsHitTesting(false)
                }
            }
        }
    }
    private var mediaReady: Bool {
        if loader.player != nil { return !loader.loading }
        return loader.image != nil || loader.livePhoto != nil || loader.animatedURL != nil
            || loader.error != nil
    }

    @ViewBuilder private func media(_ item: MediaItem) -> some View {
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
            .contentShape(Rectangle()).onTapGesture { toggleChrome() }
        } else if let player = loader.player {
            VideoPlayerSurface(
                player: player, fill: playback.fill, enabled: !locked,
                pictureInPicture: pictureInPicture,
                isZoomed: $isZoomed,
                onTap: { toggleChrome() },
                onDoubleTap: { doubleTap($0) },
                onHold: { holding in
                    if holding { playback.beginBoost() } else { playback.endBoost() }
                },
                onZoomInteraction: { zoomInteraction($0) }
            )
            .opacity(loader.loading ? 0 : 1)
        } else if let photo = loader.livePhoto {
            LivePhotoSurface(
                photo: photo, isZoomed: $isZoomed, onInteraction: { zoomInteraction($0) }
            ) { toggleChrome() }
        } else if let url = loader.animatedURL {
            AnimatedImageSurface(
                url: url, isZoomed: $isZoomed, onInteraction: { zoomInteraction($0) }, onTap: { toggleChrome() })
        } else if let image = loader.image {
            ZoomableImage(image: image, isZoomed: $isZoomed, onInteraction: { zoomInteraction($0) }) {
                toggleChrome()
            }
        }
    }

    // One drag, locked to an axis at its start: horizontal pages, down dismisses,
    // up opens details. Zoomed images keep their own pan and never page.
    private func pageDrag(_ size: CGSize) -> some Gesture {
        let stride = size.width + pageGap
        return DragGesture(minimumDistance: 12)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                guard pagingEnabled else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if dragAxis == nil {
                    dragAxis = abs(dx) > abs(dy) ? .horizontal : dy > 0 ? .down : .up
                    if dragAxis == .down { playback.endBoost() }
                }
                switch dragAxis {
                case .horizontal:
                    let atEdge = (index == 0 && dx > 0) || (index == items.count - 1 && dx < 0)
                    pageOffset = atEdge ? dx * 0.3 : dx
                case .down:
                    dismissOffset = CGSize(width: dx * 0.6, height: max(0, dy))
                case .up, nil: break
                }
            }
            .onEnded { value in
                let axis = dragAxis
                dragAxis = nil
                // A pinch that began as a drag must settle in place, never page or close.
                guard pagingEnabled else {
                    withAnimation(snap) {
                        pageOffset = 0
                        dismissOffset = .zero
                    }
                    return
                }
                switch axis {
                case .horizontal:
                    let travel = value.translation.width
                    let predicted = value.predictedEndTranslation.width
                    let direction =
                        travel < -size.width * 0.22 || predicted < -size.width * 0.5
                        ? 1 : travel > size.width * 0.22 || predicted > size.width * 0.5 ? -1 : 0
                    if direction != 0, items.indices.contains(index + direction) {
                        page(direction, stride: stride)
                    } else {
                        withAnimation(snap) { pageOffset = 0 }
                    }
                case .down:
                    if value.translation.height > 110 || value.predictedEndTranslation.height > 320 {
                        close(height: size.height)
                    } else {
                        withAnimation(snap) { dismissOffset = .zero }
                    }
                case .up:
                    if value.translation.height < -70 || value.predictedEndTranslation.height < -200 {
                        sheet = .info
                    }
                case nil: break
                }
            }
    }
    private func zoomInteraction(_ active: Bool) {
        zoomInteracting = active
        guard active, dragAxis != nil else { return }
        dragAxis = nil
        withAnimation(snap) {
            pageOffset = 0
            dismissOffset = .zero
        }
    }
    private var snap: Animation? { reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.05) }
    private var backdropOpacity: Double {
        closing ? 0 : 1 - min(0.85, Double(dismissOffset.height) / 420)
    }
    private func dismissScale(_ size: CGSize) -> CGFloat {
        1 - min(0.25, max(0, dismissOffset.height) / max(1, size.height) * 0.5)
    }

    // MARK: Chrome

    @ViewBuilder private var chrome: some View {
        if locked {
            VStack {
                HStack {
                    Spacer()
                    Button("Unlock", systemImage: "lock.open") { unlock() }
                        .buttonStyle(.glass).controlSize(.large).padding(20)
                }
                Spacer()
            }
        } else if chromeVisible && dismissOffset == .zero && !closing {
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if isVideo && playback.attached && loader.error == nil {
                    VideoTransport(tools: playback, skipInterval: skipInterval) { poke() }
                }
                Spacer(minLength: 0)
                bottomBar
            }
            .background {
                VStack {
                    LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 160)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        .frame(height: isVideo ? 260 : 180)
                }
                .ignoresSafeArea().allowsHitTesting(false)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var overlays: some View {
        if isVideo {
            CaptionOverlay(tools: playback, raised: chromeVisible && !locked)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        if let skipFeedback {
            SkipFeedbackBadge(feedback: skipFeedback)
                .frame(
                    maxWidth: .infinity,
                    alignment: skipFeedback.zone == .leading
                        ? .leading : skipFeedback.zone == .trailing ? .trailing : .center
                )
                .padding(.horizontal, 36).allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
        if playback.boosting {
            Label("2× speed", systemImage: "forward.fill").font(.subheadline.weight(.semibold))
                .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 12)
                .allowsHitTesting(false).transition(.opacity)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("Close", systemImage: "xmark") { close(height: nil) }
                .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
            Spacer(minLength: 0)
            moreMenu
        }
        .overlay {
            VStack(spacing: 2) {
                if !compactHeight, let item {
                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline.weight(.semibold))
                }
                Text(item?.name ?? "").accessibilityIdentifier("viewer.filename").font(.caption)
                    .accessibilityLabel("Filename").accessibilityValue(item?.name ?? "")
                    .foregroundStyle(.white.opacity(0.75)).lineLimit(1).truncationMode(.middle)
                if items.count > 1 && !compactHeight {
                    Text("\(index + 1) of \(items.count)").font(.caption2).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .foregroundStyle(.white).shadow(color: .black.opacity(0.4), radius: 4)
            .padding(.horizontal, 64)
        }
        .padding(.horizontal, 16).padding(.top, compactHeight ? 4 : 8)
    }

    private var moreMenu: some View {
        Menu {
            if compactHeight {
                Button("Share", systemImage: "square.and.arrow.up") { share() }
                Button(favoriteTitle, systemImage: isFavorite ? "heart.slash" : "heart") { toggleFavorite() }
                Button("Find similar", systemImage: "square.on.square") { findSimilar() }
                Button("Details", systemImage: "info.circle") { sheet = .info }
            }
            Button("Add to collection", systemImage: "rectangle.stack.badge.plus") { sheet = .organize }
            if isVideo && playback.attached {
                Section {
                    Toggle("Repeat", systemImage: "repeat", isOn: $loader.loop)
                    Toggle(
                        "Fill screen", systemImage: "arrow.up.left.and.arrow.down.right",
                        isOn: $playback.fill)
                    Button("Lock controls", systemImage: "lock") { lock() }
                    Button("Playback options", systemImage: "slider.horizontal.3") { sheet = .playback }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Media options").buttonStyle(.glass).buttonBorderShape(.circle)
        .controlSize(.large)
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if isVideo && playback.attached && loader.error == nil {
                VideoQuickRow(
                    tools: playback, pictureInPicture: pictureInPicture,
                    onOpenSubtitles: { importingSubtitles = true }, onInteract: { poke() })
                VideoScrubber(tools: playback, skipInterval: skipInterval) { poke() }
                    .padding(.bottom, compactHeight ? 0 : 8)
            }
            if !compactHeight { actionBar }
        }
        .padding(.horizontal, 18).padding(.bottom, compactHeight ? 2 : 6)
    }

    private var actionBar: some View {
        HStack {
            Button("Share", systemImage: "square.and.arrow.up") { share() }
                .disabled(loader.preparingShare || loader.loading)
                .overlay { if loader.preparingShare { ProgressView() } }
            Spacer()
            Button(favoriteTitle, systemImage: isFavorite ? "heart.fill" : "heart") { toggleFavorite() }
                .foregroundStyle(isFavorite ? Color.pink : .white)
                .symbolEffect(.bounce, value: isFavorite)
                .sensoryFeedback(.selection, trigger: isFavorite)
            Spacer()
            Button("Find similar", systemImage: "square.on.square") { findSimilar() }
            Spacer()
            Button("Details", systemImage: "info.circle") { sheet = .info }
        }
        .labelStyle(.iconOnly).font(.title3).buttonStyle(MediaControlButtonStyle()).foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay(alignment: .top) {
            if let shareError = loader.shareError {
                Text(shareError).font(.caption).foregroundStyle(.white.opacity(0.8)).offset(y: -22)
            }
        }
    }

    // MARK: Actions

    private var isFavorite: Bool { store.favorites.contains(item?.id ?? "") }
    private var favoriteTitle: String { isFavorite ? "Unfavorite" : "Favorite" }
    private var shouldAutoHide: Bool {
        chromeVisible && isVideo && playback.isPlaying && !playback.scrubbing && !voiceOver && sheet == nil
            && !locked && similarSeed == nil
    }
    private var autoHideKey: AutoHideKey {
        AutoHideKey(
            visible: chromeVisible, playing: playback.isPlaying, scrubbing: playback.scrubbing,
            interaction: interaction, blocked: sheet != nil || locked || voiceOver)
    }
    private func poke() { interaction &+= 1 }
    private func setChrome(_ visible: Bool) {
        guard chromeVisible != visible else { return }
        withAnimation(.easeInOut(duration: 0.2)) { chromeVisible = visible }
    }
    private func toggleChrome() {
        guard !locked else { return }
        setChrome(!chromeVisible)
        poke()
    }
    private func doubleTap(_ zone: PlaybackMath.Zone) {
        guard !locked else { return }
        switch zone {
        case .center:
            playback.togglePlay()
        case .leading, .trailing:
            let sign = zone == .leading ? -1 : 1
            playback.skip(by: Double(sign * skipInterval))
            // Rapid repeated double-taps accumulate into one badge.
            let total = (skipFeedback?.zone == zone ? skipFeedback?.seconds ?? 0 : 0) + skipInterval
            withAnimation(.easeOut(duration: 0.15)) {
                skipFeedback = SkipFeedback(zone: zone, seconds: total)
            }
        }
        poke()
    }
    private func lock() {
        withAnimation(.easeInOut(duration: 0.2)) { locked = true }
    }
    private func unlock() {
        withAnimation(.easeInOut(duration: 0.2)) {
            locked = false
            chromeVisible = true
        }
        poke()
    }
    private func share() {
        guard let item else { return }
        Task { if await loader.prepareShare(item) { sheet = .share } }
    }
    private func toggleFavorite() {
        if let item { store.toggleFavorite(item.id) }
        poke()
    }
    private func findSimilar() {
        playback.pause()
        similarSeed = item
    }
    private func page(_ direction: Int, stride: CGFloat) {
        guard items.indices.contains(index + direction) else { return }
        mediaTask?.cancel()
        savePosition()
        playback.detach()
        loader.stop()
        isZoomed = false
        zoomInteracting = false
        skipFeedback = nil
        // Re-base the offset so the incoming page stays under the finger, then settle.
        index += direction
        pageOffset += CGFloat(direction) * stride
        withAnimation(snap) { pageOffset = 0 }
    }
    // Interactive closes finish with a short fade, revealing the library underneath.
    private func close(height: CGFloat?) {
        guard !closing else { return }
        guard let height, !reduceMotion else {
            dismiss()
            return
        }
        withAnimation(.easeOut(duration: 0.18)) {
            closing = true
            dismissOffset.height += height * 0.25
        }
        Task {
            try? await Task.sleep(for: .milliseconds(170))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }
    private func savePosition() {
        guard let item, let player = loader.player else { return }
        let time = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        guard time.isFinite else { return }
        store.rememberPosition(duration.isFinite && time >= duration - 2 ? 0 : time, for: item.id)
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
                    if !item.format.isEmpty { LabeledContent("Format", value: item.format) }
                    LabeledContent("Source", value: item.isPhotoLibrary ? "Photos" : "Files")
                }
                if item.kind == .livePhoto { Text("Touch and hold the photo to play its motion and sound.") }
                if item.kind == .video {
                    Section("Gestures") {
                        Text("Double-tap the left or right side to skip, hold for 2× speed, pinch to fill.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { sheet = nil } }
        }.presentationDetents([.medium, .large])
    }
}

// Neighbor pages and the loading state show the grid's cached thumbnail, so a swipe
// reveals the next item instantly instead of an empty black page.
struct ViewerPreview: View {
    let item: MediaItem
    @State private var image: UIImage?
    @State private var request = PhotoThumbnailRequest()
    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: item.kind.symbol).font(.largeTitle).foregroundStyle(.white.opacity(0.25))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .task(id: item.thumbnailKey) {
            if item.isPhotoLibrary {
                request.load(item, pixels: 400) { if let result = $0 { image = result } }
            } else {
                let result = await ThumbnailService.shared.image(for: item, pixels: 400)
                if !Task.isCancelled, let result { image = result }
            }
        }
        .onDisappear { request.cancel() }
        .accessibilityHidden(true)
    }
}
