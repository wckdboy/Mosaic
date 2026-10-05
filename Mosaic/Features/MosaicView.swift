import SwiftUI

// One canvas supports open exploration and contextual discovery. Tapping a tile
// re-centers the canvas on that item with its closest matches spiraling outward;
// each hop is kept in a trail so Back returns to the exact previous viewport.
// The library-wide index runs elsewhere; this view only projects its results.
struct MosaicView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dismiss) private var dismiss
    private var compactHeight: Bool { verticalSizeClass == .compact }
    // A seed opens directly in discovery (Find similar from the gallery or viewer).
    var seed: MediaItem? = nil
    @AppStorage("mosaicGrouping") private var groupingRaw = MosaicGrouping.color.rawValue
    @AppStorage("visualAnalysis") private var visualAnalysis = true
    @AppStorage("textRecognition") private var textRecognition = false
    @AppStorage("libraryLayout") private var libraryLayout = "gallery"
    @State private var matchMode = MosaicGrouping.similar
    @State private var trail: [MediaItem] = []
    @State private var filter = MosaicFilter()
    @FocusState private var searchFocused: Bool
    @State private var clusters: [MosaicCluster] = []
    @State private var tints: [String: UInt32] = [:]
    @State private var revision = UUID()
    @State private var projecting = false
    @State private var viewer: ViewerRoute?
    @State private var command: CanvasCommand?
    // The index revision the canvas currently shows. Newer analysis is offered
    // with a Refresh pill rather than rearranging tiles under the user's finger.
    @State private var shownIndexRevision = -1
    @State private var shownAnalyzedCount = 0
    private var indexer: MosaicIndexer { MosaicIndexer.shared }

    private var focus: MediaItem? { trail.last }
    private var overviewMode: MosaicGrouping { MosaicGrouping(rawValue: groupingRaw) ?? .color }
    private var mode: MosaicGrouping { focus == nil ? overviewMode : matchMode }
    private var contextKey: String {
        focus.map { "focus-\($0.id)-\(matchMode.rawValue)" } ?? "overview-\(overviewMode.rawValue)"
    }

    private struct Projection: Equatable {
        let items: [MediaItem]
        let focus: MediaItem?
        let filter: MosaicFilter
        let mode: MosaicGrouping
        let favorites: Set<String>
        let text: [String: String]
        let applied: Int
    }
    private var projection: Projection {
        Projection(
            items: store.items, focus: focus, filter: filter, mode: mode,
            favorites: filter.favoritesOnly ? store.favorites : [],
            text: textRecognition ? store.recognizedText : [:], applied: shownIndexRevision)
    }
    private var pendingAnalysis: Bool {
        indexer.revision != shownIndexRevision && indexer.descriptors.count != shownAnalyzedCount
    }

    var body: some View {
        MosaicCanvas(
            clusters: clusters, revision: revision, context: contextKey, focused: focus != nil,
            tints: tints, favorites: store.favorites, command: command,
            onTap: { item in explore(item) },
            onOpen: { item in open(item) },
            onFavorite: { store.toggleFavorite($0.id) }
        )
        .overlay {
            if clusters.isEmpty {
                if projecting {
                    ProgressView().accessibilityLabel("Finding related media")
                } else {
                    ContentUnavailableView(
                        focus == nil ? "No matches" : "Nothing close yet",
                        systemImage: "square.on.square",
                        description: Text(emptyDescription)
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .overlay(alignment: .bottom) { if !compactHeight { canvasControls } }
        .safeAreaInset(edge: .top, spacing: 0) { discoveryBar }
        .mosaicBackground()
        .navigationTitle(focus == nil ? "Mosaic" : "Similar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if seed == nil && focus == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Gallery view", systemImage: "square.grid.2x2") { libraryLayout = "gallery" }
                }
            }
        }
        .fullScreenCover(item: $viewer) { MediaViewer(items: $0.items, initialID: $0.selectedID) }
        .onAppear {
            if trail.isEmpty, let seed { trail = [seed] }
        }
        .task(id: projection) { await project() }
        .onChange(of: indexer.revision) { _, _ in
            // Apply automatically while the canvas has little analysis to disturb.
            if shownAnalyzedCount == 0 || (focus != nil && indexer.descriptors[focus!.id] != nil
                && clusters.first?.items.count ?? 0 <= 1)
            {
                applyIndex()
            }
        }
    }

    private var emptyDescription: String {
        if focus == nil { return "Try another search or filter." }
        if indexer.descriptors[focus!.id] == nil && mode != .name {
            return "This item hasn't been analyzed yet. Try Name, or check back once indexing finishes."
        }
        return "Try another match type, or explore more of your library."
    }

    // MARK: Chrome

    // The focused item acts as a breadcrumb. Search, grouping chips, and status
    // share two quiet rows, leaving the rest of the screen to the media surface.
    private var discoveryBar: some View {
        VStack(spacing: 10) {
            if let focus {
                focusHeader(focus)
            } else {
                searchRow
            }
            if !compactHeight {
                HStack(spacing: 8) {
                    modeChips
                    statusBadge
                }
            }
        }.padding(.horizontal, 16).padding(.top, compactHeight ? 4 : 8).padding(.bottom, 6)
            // In landscape the bar must not crowd out the canvas at accessibility sizes;
            // the search field still scales, up to a size that leaves room for media.
            .dynamicTypeSize(compactHeight ? ...DynamicTypeSize.xxxLarge : ...DynamicTypeSize.accessibility5)
            .mosaicBackground()
    }

    private var searchRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search: beach, dog, blue, 2024…", text: $filter.query)
                .accessibilityIdentifier("mosaic.search")
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).focused($searchFocused).onSubmit { searchFocused = false }
            if !filter.query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { filter.query = "" }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
            }
            filterMenu
        }.padding(.horizontal, 14).padding(.vertical, 4)
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: 20))
    }

    private func focusHeader(_ focus: MediaItem) -> some View {
        HStack(spacing: 12) {
            Button {
                back()
            } label: {
                Image(systemName: trail.count > 1 || seed == nil ? "chevron.left" : "xmark")
                    .font(.body.weight(.semibold)).frame(width: 40, height: 40)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .accessibilityLabel(trail.count > 1 ? "Back" : seed == nil ? "Back to Mosaic" : "Done")
            Button {
                open(focus)
            } label: {
                HStack(spacing: 10) {
                    MediaThumbnail(item: focus, pixels: 160).frame(width: 40, height: 40)
                        .clipShape(.rect(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Similar to").font(.caption).foregroundStyle(.secondary)
                        Text(focusSubtitle(focus)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reference: \(focus.name). Open full screen")
            .accessibilityIdentifier("mosaic.focus")
            if trail.count > 1 {
                Text("\(trail.count)").font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.primary.opacity(0.08), in: Capsule())
                    .accessibilityLabel("\(trail.count) steps in this trail")
            }
            filterMenu
        }
    }

    private func focusSubtitle(_ item: MediaItem) -> String {
        guard let descriptor = indexer.descriptors[item.id] else { return item.name }
        let label = descriptor.labels?.first.map { MediaTheme.readable($0).capitalized }
        return [label ?? descriptor.theme, descriptor.color].compactMap { $0 }.joined(separator: " · ")
    }

    private var modeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(focus == nil ? MosaicGrouping.allCases : [.similar, .color, .theme, .name]) { option in
                    let selected = option == mode
                    Button {
                        if focus == nil { groupingRaw = option.rawValue } else { matchMode = option }
                    } label: {
                        Label(option.rawValue, systemImage: option.symbol)
                            .font(.subheadline.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(selected ? Color(uiColor: .systemBackground) : .primary)
                            .background(selected ? Color.primary : Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(focus == nil ? "Group by \(option.rawValue)" : "Match by \(option.rawValue)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .scrollClipDisabled()
    }

    @ViewBuilder private var statusBadge: some View {
        let count = clusters.reduce(0) { $0 + $1.items.count }
        HStack(spacing: 6) {
            if visualAnalysis && indexer.running {
                ProgressView(value: indexer.progress).progressViewStyle(.circular).controlSize(.mini)
                    .accessibilityLabel("Analyzing library, \(Int(indexer.progress * 100)) percent")
            } else if projecting {
                ProgressView().controlSize(.mini)
            }
            Text(count.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityLabel("\(count) items")
        }
    }

    private var filterMenu: some View {
        Menu {
            if compactHeight {
                // Submenus keep the root menu short enough at accessibility text sizes.
                Menu(focus == nil ? "Group by" : "Match by") {
                    Picker(focus == nil ? "Group by" : "Match by", selection: modeBinding) {
                        ForEach(MosaicGrouping.allCases) {
                            Label($0.rawValue, systemImage: $0.symbol).tag($0)
                        }
                    }
                }
                Menu("Zoom") { zoomActions }
            }
            Picker("Media", selection: $filter.kind) {
                Text("All media").tag(nil as MediaItem.Kind?)
                ForEach(MediaItem.Kind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(Optional(kind))
                }
            }
            Toggle("Favorites", systemImage: "heart", isOn: $filter.favoritesOnly)
            Picker("Source", selection: $filter.source) {
                ForEach(MosaicFilter.Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if filter.isActive {
                Button("Reset filters") {
                    let query = filter.query
                    filter = MosaicFilter(query: query)
                }
            }
        } label: {
            Image(
                systemName: filter.isActive
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
            )
            .frame(minWidth: 32, minHeight: 44)
        }.accessibilityLabel(
            compactHeight ? "Canvas options" : filter.isActive ? "Filters active" : "Filter media")
    }
    private var modeBinding: Binding<MosaicGrouping> {
        Binding(
            get: { mode },
            set: { value in if focus == nil { groupingRaw = value.rawValue } else { matchMode = value } })
    }

    private var canvasControls: some View {
        VStack(spacing: 10) {
            if pendingAnalysis && visualAnalysis {
                Button {
                    applyIndex()
                } label: {
                    Label("New matches ready", systemImage: "sparkles").font(.subheadline.weight(.medium))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glass)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 4) {
                zoomActions
                if let focus {
                    Divider().frame(height: 22)
                    Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { open(focus) }
                }
            }.labelStyle(.iconOnly).buttonStyle(MediaControlButtonStyle()).padding(6)
                .glassEffect()
        }
        .padding(.bottom, 14)
        .animation(.snappy, value: pendingAnalysis)
    }
    @ViewBuilder private var zoomActions: some View {
        Button("Zoom out", systemImage: "minus.magnifyingglass") { send(.zoomOut) }
        Button("Show all", systemImage: "arrow.down.right.and.arrow.up.left") { send(.fit) }
        Button("Recenter", systemImage: "scope") { send(.recenter) }
        Button("Zoom in", systemImage: "plus.magnifyingglass") { send(.zoomIn) }
    }

    // MARK: Actions

    private func send(_ action: CanvasCommand.Action) {
        command = CanvasCommand(id: (command?.id ?? 0) + 1, action: action)
    }
    private func explore(_ item: MediaItem) {
        searchFocused = false
        guard item.id != focus?.id else {
            open(item)
            return
        }
        trail.append(item)
        // Analyze the new reference first so its matches never wait behind the queue.
        guard visualAnalysis else { return }
        Task {
            if await indexer.prioritize(item) != nil { applyIndex() }
        }
    }
    private func back() {
        if trail.count > 1 || seed == nil {
            trail.removeLast()
        } else {
            dismiss()
        }
    }
    private func open(_ item: MediaItem) {
        searchFocused = false
        viewer = ViewerRoute(items: clusters.flatMap(\.items), selectedID: item.id)
    }
    private func applyIndex() {
        shownIndexRevision = indexer.revision
    }

    private func project() async {
        let request = projection
        let visual = indexer.descriptors
        shownAnalyzedCount = visual.count
        projecting = true
        defer { projecting = false }
        // Debounce keystrokes; grouping work never runs on the main actor.
        do { try await Task.sleep(for: .milliseconds(request.filter.query.isEmpty ? 30 : 160)) } catch {
            return
        }
        let favorites = store.favorites
        let (result, colors) = await Task.detached(priority: .userInitiated) {
            () -> ([MosaicCluster], [String: UInt32]) in
            let items = request.items.filter {
                request.filter.matches($0, favorites: favorites, text: request.text, visual: visual)
            }
            let sentiments =
                request.mode == .sentiment
                ? MosaicAnalysis.sentiments(items: request.items, recognizedText: request.text) : [:]
            if let reference = request.focus {
                let matches = MosaicSimilarity.matches(
                    seed: reference, items: items, mode: request.mode, descriptors: visual,
                    sentiments: sentiments, continuing: true)
                let cluster = MosaicCluster(id: "matches", title: "Related media", items: [reference] + matches)
                return ([cluster], Self.tints([cluster], visual))
            }
            let clusters = MosaicClusterBuilder.clusters(
                items: items, mode: request.mode, descriptors: visual, sentiments: sentiments)
            return (clusters, Self.tints(clusters, visual))
        }.value
        guard !Task.isCancelled else { return }
        clusters = result
        tints = colors
        revision = UUID()
    }
}

extension MosaicView {
    // Dominant colors paint placeholders so tiles never flash empty while decoding.
    nonisolated static func tints(_ clusters: [MosaicCluster], _ visual: [String: VisualDescriptor])
        -> [String: UInt32]
    {
        var result: [String: UInt32] = [:]
        for cluster in clusters {
            for item in cluster.items {
                if let color = visual[item.id]?.dominantRGB { result[item.id] = color }
            }
        }
        return result
    }
}

// Contextual discovery is modal so dismissing it returns to the exact media item.
struct SimilarMediaView: View {
    let seed: MediaItem
    var body: some View {
        NavigationStack {
            MosaicView(seed: seed)
        }
    }
}
