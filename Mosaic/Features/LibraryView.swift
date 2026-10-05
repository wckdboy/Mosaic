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
    let title: String
    let items: [MediaItem]
    var showsOverview = false
    var collection: MediaCollection?
    @AppStorage("textRecognition") private var textRecognition = false
    @AppStorage("libraryLayout") private var libraryLayout = "gallery"
    @State private var query = ""
    @State private var kind: MediaItem.Kind?
    @State private var sort = MediaSort.newest
    @AppStorage("gridColumns") private var columns = 3
    @AppStorage("galleryDirection") private var galleryDirection = "vertical"
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var viewer: ViewerRoute?
    @State private var organize = false
    @State private var autoOrganize = false
    @State private var similar: MediaItem?
    @State private var importing = false
    @State private var visibleItems: [MediaItem] = []
    @State private var groups: [DayGroup] = []

    private var filterKey: FilterKey {
        FilterKey(
            items: items, query: query, kind: kind, sort: sort,
            text: textRecognition ? store.recognizedText : [:],
            // Visual labels only matter for a query; avoid refiltering while indexing otherwise.
            index: query.isEmpty ? 0 : MosaicIndexer.shared.revision)
    }
    private struct FilterKey: Equatable {
        let items: [MediaItem]
        let query: String
        let kind: MediaItem.Kind?
        let sort: MediaSort
        let text: [String: String]
        let index: Int
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
                    Button(selection.count == visibleItems.count ? "Deselect all" : "Select all") {
                        selection = selection.count == visibleItems.count ? [] : Set(visibleItems.map(\.id))
                    }
                    Spacer()
                    Text("\(selection.count)").monospacedDigit().foregroundStyle(.secondary)
                    Menu {
                        Button("Add to collection", systemImage: "rectangle.stack.badge.plus") {
                            organize = true
                        }
                        Button("Auto organize", systemImage: "wand.and.stars") { autoOrganize = true }
                    } label: {
                        Image(systemName: "rectangle.stack.badge.plus")
                    }
                    .accessibilityLabel("Organize selection").disabled(selection.isEmpty)
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
                let filter = MosaicFilter(query: current.query, kind: current.kind)
                let sorted = current.sort.sorted(
                    current.items.filter { filter.matches($0, favorites: [], text: current.text, visual: visual) })
                return (sorted, Self.dayGroups(sorted, sort: current.sort))
            }.value
            if !Task.isCancelled {
                visibleItems = result.0
                groups = result.1
            }
        }
        .fullScreenCover(item: $viewer) { route in
            MediaViewer(items: route.items, initialID: route.selectedID)
        }
        .fullScreenCover(item: $similar) { SimilarMediaView(seed: $0) }
        .fullScreenCover(isPresented: $autoOrganize) {
            AutoOrganizeView(selectedIDs: selecting ? selection : Set(items.map(\.id)))
        }
        .sheet(isPresented: $organize) { OrganizeSheet(selection: selection) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            result in
            switch result {
            case .success(let urls): Task { await store.openFiles(urls) }
            case .failure(let error): store.message = error.localizedDescription
            }
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
                                    sort == .name
                                        ? "All media"
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
                                        if let collection {
                                            Button("Remove from collection", systemImage: "minus.circle") {
                                                store.remove([item.id], from: collection)
                                            }
                                        }
                                    }
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
                                        Button("Add to collection", systemImage: "rectangle.stack.badge.plus")
                                        {
                                            selection = [item.id]
                                            organize = true
                                        }
                                    }
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterButton("All", symbol: nil, value: nil)
                ForEach(MediaItem.Kind.allCases, id: \.self) { type in
                    filterButton(type.title, symbol: type.symbol, value: type)
                }
            }.padding(.horizontal, 20)
        }
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
    private func open(_ item: MediaItem) {
        if selecting {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            viewer = ViewerRoute(items: visibleItems, selectedID: item.id)
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
