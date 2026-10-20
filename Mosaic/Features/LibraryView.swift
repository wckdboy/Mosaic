import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Library is the Photos + authorized Files projection; it owns only presentation
// state and delegates all persisted mutations to LibraryStore.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @State private var settings = false
    @AppStorage("libraryLayout") private var libraryLayout = "gallery"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty && !store.hasPhotoAccess {
                    ScrollView { ConnectLibraryView() }
                } else if libraryLayout == "mosaic" {
                    MosaicView()
                } else {
                    MediaBrowser(title: "Library", items: store.items, showsOverview: true)
                }
            }
            .mosaicBackground()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: libraryLayout)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "slider.horizontal.3") { settings = true }
                }
            }
            .sheet(isPresented: $settings) { SettingsView() }
        }
    }
}

// The same browsing surface powers the library, collections, and individual media types.
// Only visible cells decode thumbnails; filtering never touches the media bytes.
struct MediaBrowser: View {
    @Environment(LibraryStore.self) private var store
    @Environment(CreationStore.self) private var creations
    let title: String
    let items: [MediaItem]
    var showsOverview = false
    var collection: MediaCollection?
    @AppStorage("textRecognition") private var textRecognition = false
    @AppStorage("libraryLayout") private var libraryLayout = "gallery"
    @State private var query: String
    @State private var kind: MediaItem.Kind?
    @State private var favoritesOnly: Bool
    @State private var source: MosaicFilter.Source
    @State private var sort: MediaSort
    @AppStorage("gridColumns") private var columns = 3
    @AppStorage("galleryDirection") private var galleryDirection = "vertical"
    @State private var selecting = false
    // Ordered, not a Set: Hero, Scatter, Stack, and story-led books use tap order.
    @State private var selection: [String] = []
    @State private var savingLens = false
    @State private var lensName = ""
    @Namespace private var viewerTransition
    @State private var viewer: ViewerRoute?
    @State private var organize = false
    @State private var autoOrganize = false
    @State private var similar: MediaItem?
    @State private var creation: CreationProject?
    @State private var smartPicks = false
    @State private var importing = false
    @State private var visibleItems: [MediaItem] = []
    @State private var visibleIndex: [String: Int] = [:]
    @State private var prefetchedThrough = -1
    @State private var groups: [DayGroup] = []

    init(
        title: String, items: [MediaItem], showsOverview: Bool = false,
        collection: MediaCollection? = nil, query: String = "", kind: MediaItem.Kind? = nil,
        favoritesOnly: Bool = false, source: MosaicFilter.Source = .all, sort: MediaSort = .newest
    ) {
        self.title = title
        self.items = items
        self.showsOverview = showsOverview
        self.collection = collection
        _query = State(initialValue: query)
        _kind = State(initialValue: kind)
        _favoritesOnly = State(initialValue: favoritesOnly)
        _source = State(initialValue: source)
        _sort = State(initialValue: sort)
    }

    private var filterKey: FilterKey {
        FilterKey(
            items: items, query: query, kind: kind, favoritesOnly: favoritesOnly,
            source: source, sort: sort, favorites: favoritesOnly ? store.favorites : [],
            text: textRecognition ? store.recognizedText : [:],
            // Visual labels only matter for a query; avoid refiltering while indexing otherwise.
            index: query.isEmpty ? 0 : MosaicIndexer.shared.revision)
    }
    private struct FilterKey: Equatable {
        let items: [MediaItem]
        let query: String
        let kind: MediaItem.Kind?
        let favoritesOnly: Bool
        let source: MosaicFilter.Source
        let sort: MediaSort
        let favorites: Set<String>
        let text: [String: String]
        let index: Int
    }
    private var allVisibleSelected: Bool {
        !visibleItems.isEmpty && visibleItems.allSatisfy { selection.contains($0.id) }
    }
    private var suggestedLensName: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed.capitalized }
        if let kind { return kind.title }
        if favoritesOnly { return "Favorites" }
        if source != .all { return source.rawValue }
        return sort == .newest ? "All media" : sort.rawValue
    }
    struct DayGroup: Identifiable, Sendable {
        let date: Date
        var items: [MediaItem]
        var id: Date { date }
    }
    // Day sections are computed with the filter, off the main actor, not per render.
    nonisolated static func dayGroups(_ items: [MediaItem], sort: MediaSort) -> [DayGroup] {
        if sort == .name { return [DayGroup(date: .distantPast, items: items)] }
        let calendar = Calendar.current
        var result: [DayGroup] = []
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            if result.last?.date == day {
                result[result.count - 1].items.append(item)
            } else {
                result.append(DayGroup(date: day, items: [item]))
            }
        }
        return result
    }
    var body: some View {
        Group {
            if galleryDirection == "horizontal" { horizontalGallery } else { verticalGallery }
        }
        .mosaicBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(galleryDirection == "horizontal" ? .inline : .large)
        .refreshable {
            await store.refreshPhotos()
            await store.refreshFolders()
        }
        .searchable(text: $query, prompt: "Search: beach, dog, blue, 2024…")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if showsOverview && !selecting {
                    Button("Mosaic view", systemImage: "square.grid.3x3") { libraryLayout = "mosaic" }
                }
                if selecting {
                    Button("Done") {
                        selecting = false
                        selection.removeAll()
                    }
                }
                Menu {
                    Button("Auto organize", systemImage: "wand.and.stars") { autoOrganize = true }.disabled(
                        items.isEmpty)
                    Button("Select items", systemImage: "checkmark.circle") {
                        selecting = true
                        selection.removeAll()
                    }.disabled(items.isEmpty)
                    Divider()
                    Picker("Sort", selection: $sort) {
                        ForEach(MediaSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Grid", selection: $columns) {
                        ForEach(2...5, id: \.self) { Text("\($0) columns").tag($0) }
                    }
                    Toggle("Favorites only", systemImage: "heart", isOn: $favoritesOnly)
                    Picker("Source", selection: $source) {
                        ForEach(MosaicFilter.Source.allCases, id: \.self) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                    Button("Smart picks", systemImage: "wand.and.stars") { smartPicks = true }
                        .disabled(items.isEmpty)
                    Button("Save view", systemImage: "bookmark") {
                        lensName = suggestedLensName
                        savingLens = true
                    }
                    .disabled(items.isEmpty)
                    .accessibilityIdentifier("library.saveView")
                    Button("Open files", systemImage: "folder.badge.plus") { importing = true }
                    if !store.hasPhotoAccess {
                        Button("Connect Photos", systemImage: "photo.badge.plus") {
                            Task { await store.connectPhotos() }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Library options").accessibilityIdentifier("library.options")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    Button(allVisibleSelected ? "Deselect all" : "Select all") { toggleSelectAll() }
                    Spacer()
                    Text("\(selection.count)").monospacedDigit().foregroundStyle(.secondary)
                    Menu {
                        Button("Make a collage", systemImage: "square.on.square.dashed") {
                            openCreation(.collage)
                        }
                        Button("Make a photobook", systemImage: "book.closed") {
                            openCreation(.photobook)
                        }
                        Divider()
                        Button("Add to collection", systemImage: "rectangle.stack.badge.plus") {
                            organize = true
                        }
                        Button("Auto organize", systemImage: "wand.and.stars") { autoOrganize = true }
                    } label: {
                        Image(systemName: "rectangle.stack.badge.plus")
                    }
                    .accessibilityLabel("Selection actions").disabled(selection.isEmpty)
                }.padding(18).glassEffect(in: .capsule).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .task(id: filterKey) {
            let current = filterKey
            let visual = current.query.isEmpty ? [:] : MosaicIndexer.shared.descriptors
            if !current.query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
            let result = await Task.detached(priority: .userInitiated) {
                let kinds = current.items.filter { item in
                    guard current.kind == nil || item.kind == current.kind else { return false }
                    guard !current.favoritesOnly || current.favorites.contains(item.id) else { return false }
                    return current.source == .all
                        || (current.source == .photos ? item.isPhotoLibrary : !item.isPhotoLibrary)
                }
                let search = MosaicSearch(current.query)
                guard !search.isEmpty else {
                    let sorted = current.sort.sorted(kinds)
                    return (sorted, Self.dayGroups(sorted, sort: current.sort))
                }
                // A search lists best matches by relevance, then related media.
                let ranked = search.rank(kinds, descriptors: visual, text: current.text)
                let ordered = ranked.matches + ranked.related
                var groups: [DayGroup] = []
                if !ranked.matches.isEmpty {
                    groups.append(DayGroup(date: .distantPast, items: ranked.matches))
                }
                if !ranked.related.isEmpty {
                    groups.append(DayGroup(date: .distantFuture, items: ranked.related))
                }
                return (ordered, groups)
            }.value
            if !Task.isCancelled {
                visibleItems = result.0
                visibleIndex = Dictionary(
                    uniqueKeysWithValues: result.0.enumerated().map { ($0.element.id, $0.offset) })
                prefetchedThrough = -1
                groups = result.1
            }
        }
        .fullScreenCover(item: $viewer) { route in
            MediaViewer(items: route.items, initialID: route.selectedID)
                .navigationTransition(.zoom(sourceID: route.selectedID, in: viewerTransition))
        }
        .fullScreenCover(item: $similar) { SimilarMediaView(seed: $0) }
        .fullScreenCover(item: $creation) { project in
            if project.kind == .collage {
                CollageStudioView(project: project)
            } else {
                BookStudioView(project: project)
            }
        }
        .fullScreenCover(isPresented: $smartPicks) {
            SmartPicksView(source: items) { kind, picked in
                creation =
                    kind == .collage
                    ? .collage(
                        itemIDs: picked.map(\.id),
                        title: CreationProject.suggestedTitle(.collage))
                    : .photobook(
                        itemIDs: picked.map(\.id),
                        title: CreationProject.suggestedTitle(.photobook))
            }
        }
        .fullScreenCover(isPresented: $autoOrganize) {
            AutoOrganizeView(selectedIDs: selecting ? Set(selection) : Set(items.map(\.id)))
        }
        .sheet(isPresented: $organize) { OrganizeSheet(selection: Set(selection)) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            result in
            switch result {
            case .success(let urls): Task { await store.openFiles(urls) }
            case .failure(let error): store.message = error.localizedDescription
            }
        }
        .alert("Save view", isPresented: $savingLens) {
            TextField("Name", text: $lensName)
            Button("Save") {
                store.createLens(
                    name: lensName, query: query, kind: kind, favoritesOnly: favoritesOnly,
                    source: source, sort: sort)
                lensName = ""
            }
            .disabled(lensName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { lensName = "" }
        } message: {
            Text("Saved views reopen this search, media type, filters, and sort from Collections.")
        }
    }

    private var verticalGallery: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                if showsOverview && query.isEmpty && !selecting { overview }
                filters
                if store.isLoading && items.isEmpty {
                    ProgressView("Reading your library…").frame(maxWidth: .infinity).padding(50)
                } else if visibleItems.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "Room for more" : "No matches",
                        systemImage: query.isEmpty ? "photo.on.rectangle" : "magnifyingglass",
                        description: Text(
                            query.isEmpty
                                ? "Open media from Files or connect your photo library."
                                : "Try a filename, a year, or a format like GIF."))
                } else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(
                                    group.date == .distantFuture
                                        ? "Related"
                                        : group.date == .distantPast
                                            ? (query.isEmpty ? "All media" : "Best matches")
                                            : group.date.formatted(date: .abbreviated, time: .omitted)
                                )
                                .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(group.items.count.formatted()).font(.caption).foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }.padding(.horizontal, 20)
                            LazyVGrid(
                                columns: Array(
                                    repeating: GridItem(.flexible(), spacing: 3),
                                    count: max(2, min(columns, 5))), spacing: 3
                            ) {
                                ForEach(group.items) { item in
                                    Button {
                                        open(item)
                                    } label: {
                                        MediaTile(
                                            item: item, favorite: store.favorites.contains(item.id),
                                            selecting: selecting, selected: selection.contains(item.id))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(item.name), \(item.kind.title)")
                                    .accessibilityIdentifier("media-\(item.id)")
                                    .accessibilityValue(selection.contains(item.id) ? "Selected" : "")
                                    .contextMenu {
                                        Button("Find similar", systemImage: "square.on.square") {
                                            similar = item
                                        }
                                        Button(
                                            store.favorites.contains(item.id) ? "Unfavorite" : "Favorite",
                                            systemImage: "heart"
                                        ) { store.toggleFavorite(item.id) }
                                        Button("Add to collection", systemImage: "rectangle.stack.badge.plus")
                                        {
                                            selection = [item.id]
                                            organize = true
                                        }
                                        Button("Make a collage", systemImage: "square.on.square.dashed") {
                                            creation = .collage(
                                                itemIDs: selection.isEmpty ? [item.id] : selection,
                                                title: CreationProject.suggestedTitle(.collage))
                                        }
                                        Button("Make a photobook", systemImage: "book.closed") {
                                            creation = .photobook(
                                                itemIDs: selection.isEmpty ? [item.id] : selection,
                                                title: CreationProject.suggestedTitle(.photobook))
                                        }
                                        if let collection {
                                            Button("Remove from collection", systemImage: "minus.circle") {
                                                store.remove([item.id], from: collection)
                                            }
                                        }
                                    }
                                    .onAppear { prefetchNeighbors(of: item) }
                                    .matchedTransitionSource(id: item.id, in: viewerTransition)
                                }
                            }.padding(.horizontal, 3)
                        }
                    }
                    Text("\(visibleItems.count.formatted()) items")
                        .font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(
                            .vertical, 18)
                }
            }.padding(.top, 8).padding(.bottom, 24)
        }
    }

    // A horizontal grid uses rows instead of rotating the view, preserving readable
    // text, natural gestures, accessibility order, and adaptive iPad geometry.
    private var horizontalGallery: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                filters
                if visibleItems.isEmpty {
                    ContentUnavailableView(
                        "No media", systemImage: "photo",
                        description: Text("Try another filter or open files."))
                } else {
                    let rowCount = min(columns, 4)
                    let tileSize = max(64, (geometry.size.height - 150) / CGFloat(rowCount))
                    ScrollView(.horizontal) {
                        LazyHGrid(
                            rows: Array(repeating: GridItem(.fixed(tileSize), spacing: 3), count: rowCount),
                            spacing: 3
                        ) {
                            ForEach(visibleItems) { item in
                                Button {
                                    open(item)
                                } label: {
                                    MediaTile(
                                        item: item, favorite: store.favorites.contains(item.id),
                                        selecting: selecting, selected: selection.contains(item.id)
                                    )
                                    .frame(width: tileSize, height: tileSize)
                                }.buttonStyle(.plain)
                                    .accessibilityLabel("\(item.name), \(item.kind.title)")
                                    .accessibilityIdentifier("media-\(item.id)")
                                    .contextMenu {
                                        Button("Find similar", systemImage: "square.on.square") {
                                            similar = item
                                        }
                                        Button(
                                            store.favorites.contains(item.id) ? "Unfavorite" : "Favorite",
                                            systemImage: "heart"
                                        ) { store.toggleFavorite(item.id) }
                                        Button("Add to collection", systemImage: "rectangle.stack.badge.plus")
                                        {
                                            selection = [item.id]
                                            organize = true
                                        }
                                        Button("Make a collage", systemImage: "square.on.square.dashed") {
                                            creation = .collage(
                                                itemIDs: selection.isEmpty ? [item.id] : selection,
                                                title: CreationProject.suggestedTitle(.collage))
                                        }
                                        Button("Make a photobook", systemImage: "book.closed") {
                                            creation = .photobook(
                                                itemIDs: selection.isEmpty ? [item.id] : selection,
                                                title: CreationProject.suggestedTitle(.photobook))
                                        }
                                        if let collection {
                                            Button("Remove from collection", systemImage: "minus.circle") {
                                                store.remove([item.id], from: collection)
                                            }
                                        }
                                    }
                                    .onAppear { prefetchNeighbors(of: item) }
                                    .matchedTransitionSource(id: item.id, in: viewerTransition)
                            }
                        }.padding(.horizontal, 3)
                    }
                    // Free momentum scrolling: view-aligned snapping stopped every
                    // fling after a few tiles, which made long libraries tedious.
                    .scrollIndicators(.hidden)
                }
            }.padding(.top, 12)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(items.count.formatted()) items").font(
                        .system(.title, design: .rounded, weight: .semibold)
                    ).tracking(-0.7)
                }
                Spacer()
                Image(systemName: "square.grid.3x3.square").font(.system(size: 27, weight: .ultraLight))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            if store.authorization == .limited {
                HStack {
                    Label("Selected Photos access", systemImage: "checkmark.shield").font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Manage") { presentLimitedPicker() }.font(.caption.weight(.semibold))
                }
            }
            Divider()
        }.padding(.horizontal, 20)
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterButton("All", symbol: nil, value: nil)
                    ForEach(MediaItem.Kind.allCases, id: \.self) { type in
                        filterButton(type.title, symbol: type.symbol, value: type)
                    }
                }.padding(.horizontal, 20)
            }
            if favoritesOnly || source != .all {
                HStack(spacing: 7) {
                    if favoritesOnly {
                        activeFilter("Favorites", symbol: "heart.fill") { favoritesOnly = false }
                    }
                    if source != .all {
                        activeFilter(source.rawValue, symbol: "externaldrive") { source = .all }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
    private func activeFilter(
        _ title: String, symbol: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
                Image(systemName: "xmark").font(.caption2.weight(.bold)).opacity(0.6)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(title) filter")
    }
    private func filterButton(_ name: String, symbol: String?, value: MediaItem.Kind?) -> some View {
        Button {
            kind = value
        } label: {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(name)
            }
            .font(.subheadline.weight(.medium)).padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(kind == value ? Color(uiColor: .systemBackground) : Color.primary)
            .background(kind == value ? Color.primary : Color.primary.opacity(0.055), in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(kind == value ? .isSelected : [])
    }
    private func openCreation(_ kind: CreationProject.Kind) {
        let ids = selection.isEmpty ? visibleItems.map(\.id) : selection
        creation =
            kind == .collage
            ? .collage(itemIDs: ids, title: CreationProject.suggestedTitle(.collage))
            : .photobook(itemIDs: ids, title: CreationProject.suggestedTitle(.photobook))
    }

    private func open(_ item: MediaItem) {
        if selecting {
            if let index = selection.firstIndex(of: item.id) {
                selection.remove(at: index)
            } else {
                selection.append(item.id)
            }
        } else {
            viewer = ViewerRoute(items: visibleItems, selectedID: item.id)
        }
    }
    // Warm the next row or two while the current tiles settle. The caching manager
    // deduplicates requests, and one rolling watermark avoids a task per visible cell.
    private func prefetchNeighbors(of item: MediaItem) {
        guard item.isPhotoLibrary, let index = visibleIndex[item.id], index + 10 > prefetchedThrough
        else { return }
        let end = min(visibleItems.count, index + 11)
        guard index + 1 < end else { return }
        prefetchedThrough = end - 1
        PhotoThumbnailRequest.prefetch(Array(visibleItems[(index + 1)..<end]), pixels: 400)
    }

    private func toggleSelectAll() {
        let visible = Set(visibleItems.map(\.id))
        if allVisibleSelected {
            selection.removeAll { visible.contains($0) }
        } else {
            for id in visibleItems.map(\.id) where !selection.contains(id) {
                selection.append(id)
            }
        }
    }
    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }
}

struct ViewerRoute: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let selectedID: String
}
