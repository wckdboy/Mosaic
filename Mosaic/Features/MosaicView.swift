import SwiftUI

// One canvas supports open exploration and contextual discovery. Indexing has its
// own task so typing or adjusting filters never restarts the analysis batch.
struct MosaicView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compactHeight: Bool { verticalSizeClass == .compact }
    var seed: MediaItem? = nil
    @AppStorage("mosaicGrouping") private var groupingRaw = MosaicGrouping.color.rawValue
    @AppStorage("visualCacheVersion") private var visualCacheVersion = 0
    @AppStorage("visualAnalysis") private var visualAnalysis = true
    @AppStorage("textRecognition") private var textRecognition = false
    @AppStorage("libraryLayout") private var libraryLayout = "gallery"
    @State private var seedMode = MosaicGrouping.similar.rawValue
    @State private var filter = MosaicFilter()
    @FocusState private var searchFocused: Bool
    @State private var clusters: [MosaicCluster] = []
    @State private var descriptors: [String: VisualDescriptor] = [:]
    @State private var revision = UUID()
    @State private var indexVersion = 0
    @State private var zoom: CGFloat = 1
    @State private var analyzing = false
    @State private var viewer: ViewerRoute?
    @State private var batch = 0
    @State private var attempted: Set<String> = []
    @State private var indexedItems: [MediaItem] = []
    @State private var indexedCacheVersion = -1
    private var grouping: Binding<String> { seed == nil ? $groupingRaw : $seedMode }
    private var mode: MosaicGrouping { MosaicGrouping(rawValue: grouping.wrappedValue) ?? .color }
    private struct IndexRequest: Equatable {
        let items: [MediaItem]
        let batch: Int
        let enabled: Bool
        let cacheVersion: Int
    }
    private struct Projection: Equatable {
        let index: IndexRequest
        let version: Int
        let filter: MosaicFilter
        let mode: MosaicGrouping
        let favorites: Set<String>
        let text: [String: String]
    }
    private var indexRequest: IndexRequest {
        IndexRequest(
            items: store.items, batch: batch, enabled: visualAnalysis, cacheVersion: visualCacheVersion)
    }
    private var projection: Projection {
        Projection(
            index: indexRequest, version: indexVersion, filter: filter, mode: mode,
            favorites: store.favorites, text: textRecognition ? store.recognizedText : [:])
    }
    var body: some View {
        MosaicCanvas(clusters: clusters, revision: revision, zoom: zoom) { item in
            searchFocused = false
            viewer = ViewerRoute(items: clusters.flatMap(\.items), selectedID: item.id)
        }
        .overlay {
            if clusters.isEmpty {
                if analyzing {
                    ProgressView().accessibilityLabel("Finding related media")
                } else {
                    ContentUnavailableView(
                        seed == nil ? "No matches" : "Nothing close yet",
                        systemImage: "square.on.square",
                        description: Text(
                            seed == nil
                                ? "Try another search or filter."
                                : "Try Color or Name, or explore more of your library.")
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .overlay(alignment: .bottom) { if !compactHeight { canvasControls } }
        .safeAreaInset(edge: .top, spacing: 0) { discoveryBar }
        .mosaicBackground()
        .navigationTitle(seed == nil ? "Mosaic" : "Find similar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if seed == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Gallery view", systemImage: "square.grid.2x2") { libraryLayout = "gallery" }
                }
            }
        }
        .fullScreenCover(item: $viewer) { MediaViewer(items: $0.items, initialID: $0.selectedID) }
        .task(id: indexRequest) { await buildIndex() }
        .task(id: projection) { await project() }
    }

    // The seed acts as a visual breadcrumb. Search and advanced filters share one
    // quiet row, leaving the rest of the screen to the two-axis media surface.
    private var discoveryBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if let seed {
                    MediaThumbnail(item: seed).frame(width: 42, height: 42)
                        .clipShape(.rect(cornerRadius: 10)).accessibilityLabel("Reference: \(seed.name)")
                }
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your media", text: $filter.query).accessibilityIdentifier("mosaic.search")
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).focused($searchFocused).onSubmit { searchFocused = false }
                if !filter.query.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { filter.query = "" }
                        .labelStyle(.iconOnly).foregroundStyle(.secondary)
                }
                Menu {
                    // Pinch remains the primary landscape zoom gesture. These
                    // explicit actions keep zoom/grouping accessible while a
                    // single header row leaves more of the canvas visible.
                    if compactHeight {
                        Menu(seed == nil ? "Group by" : "Match by") {
                            Picker("Grouping", selection: grouping) {
                                ForEach(MosaicGrouping.allCases) {
                                    Label($0.rawValue, systemImage: $0.symbol).tag($0.rawValue)
                                }
                            }
                        }
                        Menu("Zoom") { canvasActions }
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
            }.padding(.horizontal, 14).padding(.vertical, 4)
                .background(.primary.opacity(0.045), in: .rect(cornerRadius: 20))
            if !compactHeight {
                HStack {
                    Menu {
                        Picker(seed == nil ? "Group by" : "Match by", selection: grouping) {
                            ForEach(MosaicGrouping.allCases) {
                                Label($0.rawValue, systemImage: $0.symbol).tag($0.rawValue)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(mode.rawValue).font(.subheadline.weight(.medium))
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        }.padding(.vertical, 8)
                    }.accessibilityLabel(
                        seed == nil ? "Group by \(mode.rawValue)" : "Match by \(mode.rawValue)")
                    Spacer()
                    Text(clusters.reduce(0) { $0 + $1.items.count }.formatted())
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if analyzing { ProgressView().controlSize(.mini) }
                }.padding(.horizontal, 4)
            }
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4).mosaicBackground()
    }
    private var canvasControls: some View {
        HStack(spacing: 4) {
            canvasActions
        }.labelStyle(.iconOnly).buttonStyle(MediaControlButtonStyle()).padding(6)
            .glassEffect().padding(.bottom, 14)
    }
    @ViewBuilder private var canvasActions: some View {
        Button("Zoom out", systemImage: "minus.magnifyingglass") { zoom = max(0.4, zoom - 0.2) }
        Button("Reset zoom", systemImage: "arrow.up.left.and.arrow.down.right") {
            zoom = zoom == 1 ? 0.999 : 1
        }
        Button("Zoom in", systemImage: "plus.magnifyingglass") { zoom = min(2, zoom + 0.2) }
        if visualAnalysis {
            Button("Analyze more", systemImage: "arrow.clockwise") { batch += 1 }.disabled(analyzing)
        }
    }
    private func buildIndex() async {
        let items = store.items
        if indexedItems != items || indexedCacheVersion != visualCacheVersion {
            attempted.removeAll()
            indexedItems = items
            indexedCacheVersion = visualCacheVersion
        }
        let cached = await MosaicAnalysis.shared.cached()
        guard !Task.isCancelled else { return }
        descriptors = Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
                guard let descriptor = cached[item.id], descriptor.sourceModified == item.modified else {
                    return nil
                }
                return (item.id, descriptor)
            })
        indexVersion += 1
        guard visualAnalysis else { return }
        analyzing = true
        defer { analyzing = false }
        // Always prioritize the reference, then a bounded local-only library batch.
        let pending =
            (seed.map { [$0] } ?? [])
            + Array(
                items.filter { descriptors[$0.id] == nil && !attempted.contains($0.id) && $0.id != seed?.id }
                    .prefix(500))
        for item in pending {
            guard !Task.isCancelled else { break }
            attempted.insert(item.id)
            if let descriptor = await MosaicAnalysis.shared.analyze(item, allowFileRead: item.id == seed?.id)
            {
                descriptors[item.id] = descriptor
            }
        }
        await MosaicAnalysis.shared.save()
        if !Task.isCancelled { indexVersion += 1 }
    }
    private func project() async {
        let request = projection
        let visual = descriptors
        let reference = seed
        // Debounce keystrokes; grouping work never runs on the main actor.
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        let result = await Task.detached(priority: .userInitiated) {
            let items = request.index.items.filter {
                request.filter.matches($0, favorites: request.favorites, text: request.text)
            }
            let sentiments =
                request.mode == .sentiment
                ? MosaicAnalysis.sentiments(items: request.index.items, recognizedText: request.text) : [:]
            if let reference {
                let matches = MosaicSimilarity.matches(
                    seed: reference, items: items, mode: request.mode,
                    descriptors: visual, sentiments: sentiments)
                return matches.isEmpty
                    ? []
                    : [
                        MosaicCluster(
                            id: "matches",
                            title: request.mode == .similar && visual[reference.id] == nil
                                ? "Related names" : "Related media", items: matches)
                    ]
            }
            return MosaicClusterBuilder.clusters(
                items: items, mode: request.mode, descriptors: visual, sentiments: sentiments)
        }.value
        guard !Task.isCancelled else { return }
        clusters = result
        revision = UUID()
    }
}

// Contextual discovery is modal so dismissing it returns to the exact media item.
struct SimilarMediaView: View {
    @Environment(\.dismiss) private var dismiss
    let seed: MediaItem
    var body: some View {
        NavigationStack {
            MosaicView(seed: seed)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } } }
        }
    }
}
