import SwiftUI

// The collage studio is a focused workbench: a live print preview, a small set of
// composition styles, and direct control over which photographs appear in what
// order. Layout geometry comes from Rust; the same recipe is used for export.
struct CollageStudioView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(CreationStore.self) private var creations
    @Environment(\.dismiss) private var dismiss
    @State private var project: CreationProject
    @State private var layout: CoreCollageLayout?
    @State private var picker = false
    @State private var options = false
    @State private var loading = false
    @State private var exporting = false
    @State private var share: SharePayload?
    @State private var error: String?
    @State private var fillCount = 12
    @State private var sourceCollection: UUID?
    @State private var favoritesOnly = false

    init(project: CreationProject) {
        _project = State(initialValue: project)
    }

    private var items: [MediaItem] { store.items(for: project.itemIDs) }
    private var lookup: [String: MediaItem] {
        Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private var layoutKey: LayoutKey {
        LayoutKey(
            ids: project.itemIDs, style: project.style, aspect: project.aspect,
            seed: project.seed, spacing: project.spacing, padding: project.padding)
    }
    private struct LayoutKey: Equatable {
        let ids: [String]
        let style: String
        let aspect: Double
        let seed: UInt64
        let spacing: Double
        let padding: Double
    }

    private var sourceItems: [MediaItem] {
        if let sourceCollection,
            let collection = store.collections.first(where: { $0.id == sourceCollection })
        {
            return store.items(for: Array(collection.itemIDs))
        }
        return favoritesOnly ? store.items.filter { store.favorites.contains($0.id) } : store.items
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    preview
                    quickControls
                    photoStrip
                    composeControls
                }
                .padding(20)
                .padding(.bottom, 70)
            }
            .mosaicBackground()
            .navigationTitle(project.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        creations.save(project)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Share", systemImage: "square.and.arrow.up") { export() }
                        .accessibilityIdentifier("collage.share")
                        .disabled(layout == nil || exporting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Options", systemImage: "slider.horizontal.3") { options = true }
                }
            }
            .sheet(isPresented: $picker) {
                CreationPhotoPicker(
                    initial: project.itemIDs, limit: 40
                ) { ids in
                    project.itemIDs = ids
                }
            }
            .sheet(isPresented: $options) {
                CollageOptionsView(project: $project)
                    .presentationDetents([.large])
            }
            .sheet(item: $share) { payload in
                ShareSheet(items: payload.items)
                    .ignoresSafeArea()
            }
            .alert("Could not create the collage", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .overlay {
                if loading || exporting {
                    ProgressView(exporting ? "Rendering your collage…" : "Choosing photos…")
                        .padding(22)
                        .glassEffect(in: .rect(cornerRadius: 20))
                }
            }
            .task {
                if project.itemIDs.isEmpty { await smartFill() }
            }
            .task(id: layoutKey) { await rebuildLayout() }
            .task(id: project) { await autosave() }
        }
    }

    private var preview: some View {
        Group {
            if let layout {
                CollagePreview(
                    layout: layout, items: lookup, finish: project.finish,
                    cornerRadius: project.cornerRadius, showCaptions: project.showCaptions)
            } else {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.quaternary)
                    .aspectRatio(max(project.aspect, 0.5), contentMode: .fit)
                    .overlay {
                        if loading {
                            ProgressView()
                        } else {
                            ContentUnavailableView(
                                "Choose a few photos", systemImage: "photo.on.rectangle.angled",
                                description: Text("Smart fill can pick a varied set for you."))
                        }
                    }
            }
        }
        .frame(maxHeight: 430)
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .accessibilityIdentifier("collage.preview")
    }

    private var quickControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CollageStyle.allCases) { style in
                    Button {
                        project.collageStyle = style
                    } label: {
                        Label(style.title, systemImage: style.symbol)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .foregroundStyle(
                                project.collageStyle == style ? Color(uiColor: .systemBackground) : .primary
                            )
                            .background(
                                project.collageStyle == style ? Color.primary : Color.primary.opacity(0.06),
                                in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(project.collageStyle == style ? .isSelected : [])
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private var photoStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Photos").font(.headline)
                Text("\(project.itemIDs.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Add", systemImage: "plus") { picker = true }
                    .font(.caption.weight(.semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(project.itemIDs.enumerated()), id: \.element) { index, id in
                        if let item = store.item(id) {
                            MediaThumbnail(item: item, pixels: 260)
                                .frame(width: 70, height: 70)
                                .clipShape(.rect(cornerRadius: 8))
                                .overlay(alignment: .topLeading) {
                                    Text("\(index + 1)")
                                        .font(.caption2.weight(.bold)).monospacedDigit()
                                        .foregroundStyle(.white)
                                        .padding(3)
                                        .background(.black.opacity(0.45), in: Circle())
                                        .padding(3)
                                }
                                .draggable(id)
                                .dropDestination(for: String.self) { dragged, _ in
                                    guard let value = dragged.first,
                                        let from = project.itemIDs.firstIndex(of: value)
                                    else { return false }
                                    let to = project.itemIDs.firstIndex(of: id) ?? index
                                    guard from != to else { return true }
                                    let moved = project.itemIDs.remove(at: from)
                                    project.itemIDs.insert(moved, at: to)
                                    return true
                                }
                                .contextMenu {
                                    Button("Move to first", systemImage: "arrow.up.to.line") {
                                        moveFirst(id)
                                    }
                                    Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                        project.itemIDs.removeAll { $0 == id }
                                    }
                                }
                                .accessibilityLabel("Photo \(index + 1), \(item.name)")
                        }
                    }
                    Button {
                        picker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3).foregroundStyle(.secondary)
                            .frame(width: 70, height: 70)
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add photos")
                }
            }
        }
    }

    private var composeControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Smart fill").font(.headline)
                    Text("Choose a varied set from \(sourceItems.count.formatted()) items")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Stepper("\(fillCount)", value: $fillCount, in: 2...40)
                    .labelsHidden()
                Text("\(fillCount)").monospacedDigit().frame(minWidth: 24)
            }
            HStack(spacing: 10) {
                Menu {
                    Button("All photos") {
                        sourceCollection = nil
                        favoritesOnly = false
                    }
                    Button("Favorites") {
                        sourceCollection = nil
                        favoritesOnly = true
                    }
                    ForEach(store.collections) { collection in
                        Button(collection.name) {
                            sourceCollection = collection.id
                            favoritesOnly = false
                        }
                    }
                } label: {
                    Label(sourceLabel, systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.glass)

                Button {
                    Task { await smartFill() }
                } label: {
                    Label("Fill", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("collage.fill")
                .disabled(loading)
            }
            HStack(spacing: 10) {
                Button("Shuffle", systemImage: "shuffle") {
                    project.seed &+= 1
                }
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .buttonStyle(.glass)
                Button("Layout", systemImage: "rectangle.3.group") { options = true }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.glass)
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.32), in: .rect(cornerRadius: 22))
    }

    private var sourceLabel: String {
        if let sourceCollection,
            let collection = store.collections.first(where: { $0.id == sourceCollection })
        {
            return collection.name
        }
        return favoritesOnly ? "Favorites" : "All photos"
    }

    private func moveFirst(_ id: String) {
        guard let index = project.itemIDs.firstIndex(of: id), index > 0 else { return }
        let value = project.itemIDs.remove(at: index)
        project.itemIDs.insert(value, at: 0)
    }

    private func smartFill() async {
        guard !sourceItems.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let picks = try await MosaicCoreStore.shared.select(
                items: store.items, descriptors: MosaicIndexer.shared.descriptors,
                favorites: store.favorites, count: min(fillCount, sourceItems.count),
                diversity: 0.68, minGapSeconds: 4, preferRecent: true,
                seed: UInt64(Date().timeIntervalSince1970), ids: sourceItems.map(\.id))
            if !picks.isEmpty {
                project.itemIDs = picks.map(\.id)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rebuildLayout() async {
        let media = items
        guard !media.isEmpty else {
            layout = nil
            return
        }
        let request = CoreCollageRequest(
            count: media.count, aspect: project.aspect,
            style: project.collageStyle.rawValue, seed: project.seed,
            spacing: project.spacing, padding: project.padding,
            items: media.map {
                CoreLayoutItem(
                    id: $0.id, width: $0.width, height: $0.height,
                    date: $0.date.timeIntervalSince1970,
                    favorite: store.favorites.contains($0.id),
                    quality: Double($0.width * $0.height) / 12_000_000)
            })
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try MosaicCoreBridge.collage(request)
            }.value
            if !Task.isCancelled { layout = result }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func autosave() async {
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        creations.save(project)
    }

    private func export() {
        guard let layout, !items.isEmpty else { return }
        exporting = true
        let project = project
        let items = items
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                await CreationExporter.collage(project: project, items: items, layout: layout)
            }.value
            exporting = false
            if let image {
                share = SharePayload(items: [image])
            } else {
                error =
                    "The collage could not be rendered. Try a smaller selection or reconnect iCloud photos."
            }
        }
    }
}

// MARK: - Options

private struct CollageOptionsView: View {
    @Binding var project: CreationProject
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Title", text: $project.title)
                }
                Section("Composition") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(CollageStyle.allCases) { style in
                            Button {
                                project.collageStyle = style
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Image(systemName: style.symbol).font(.title3)
                                    Text(style.title).font(.caption.weight(.semibold))
                                    Text(style.explanation)
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    project.collageStyle == style
                                        ? Color.primary.opacity(0.1) : Color.primary.opacity(0.03),
                                    in: .rect(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Picker("Canvas", selection: $project.collageAspect) {
                        ForEach(CollageAspect.allCases) { aspect in
                            Text(aspect.title).tag(aspect)
                        }
                    }
                }
                Section("Finish") {
                    Picker("Background", selection: $project.finish) {
                        ForEach(CollageFinish.allCases) { finish in
                            Text(finish.title).tag(finish)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Corner radius").font(.subheadline)
                        Slider(value: $project.cornerRadius, in: 0...28, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("Spacing").font(.subheadline)
                        Slider(value: $project.spacing, in: 0...0.05)
                    }
                    VStack(alignment: .leading) {
                        Text("Margin").font(.subheadline)
                        Slider(value: $project.padding, in: 0...0.1)
                    }
                    Toggle("Date captions", isOn: $project.showCaptions)
                }
            }
            .navigationTitle("Layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
