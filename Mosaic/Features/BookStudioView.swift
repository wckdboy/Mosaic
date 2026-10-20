import SwiftUI

// Photobook studio. It curates a sequence, groups it into events, and lays it out as
// print pages. The Rust planner owns the page rhythm; this view owns the human
// choices: which photos, which tone, and how the finished book should read.
struct BookStudioView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(CreationStore.self) private var creations
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var project: CreationProject
    @State private var plan: CoreBookPlan?
    @State private var picker = false
    @State private var options = false
    @State private var loading = false
    @State private var exporting = false
    @State private var share: SharePayload?
    @State private var error: String?
    @State private var fillCount = 36
    @State private var sourceCollection: UUID?
    @State private var favoritesOnly = false
    @State private var pageIndex = 0

    init(project: CreationProject) {
        _project = State(initialValue: project)
    }

    private var items: [MediaItem] { store.items(for: project.itemIDs) }
    private var lookup: [String: MediaItem] {
        Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }
    private var descriptors: [String: VisualDescriptor] { MosaicIndexer.shared.descriptors }

    private var sourceItems: [MediaItem] {
        if let sourceCollection,
            let collection = store.collections.first(where: { $0.id == sourceCollection })
        {
            return store.items(for: Array(collection.itemIDs))
        }
        return favoritesOnly ? store.items.filter { store.favorites.contains($0.id) } : store.items
    }

    private var planKey: PlanKey {
        PlanKey(
            ids: project.itemIDs, style: project.style, pageAspect: project.pageAspect,
            spread: project.spread, seed: project.seed, maxPerPage: project.maxPerPage,
            title: project.title, subtitle: project.subtitle, cover: project.includeCover)
    }
    private struct PlanKey: Equatable {
        let ids: [String]
        let style: String
        let pageAspect: Double
        let spread: Bool
        let seed: UInt64
        let maxPerPage: Int
        let title: String
        let subtitle: String
        let cover: Bool
    }

    /// Groups facing pages for wide layouts. On a phone the same plan is shown one
    /// page at a time so the type and photographs stay legible.
    private var displayGroups: [[CoreBookPage]] {
        guard let plan else { return [] }
        if !project.spread || horizontalSizeClass != .regular {
            return plan.pages.map { [$0] }
        }
        var groups: [[CoreBookPage]] = []
        for page in plan.pages {
            if let last = groups.last, last.count == 1,
                let previous = last.first, previous.spreadIndex == page.spreadIndex,
                page.side != "single"
            {
                groups[groups.count - 1].append(page)
            } else {
                groups.append([page])
            }
        }
        return groups
    }

    private var currentGroup: [CoreBookPage] {
        guard !displayGroups.isEmpty else { return [] }
        return displayGroups[min(pageIndex, displayGroups.count - 1)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    bookPreview
                    if !displayGroups.isEmpty {
                        pageStrip
                        pageCaption
                    }
                    quickControls
                    curateControls
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
                    Button("Share PDF", systemImage: "square.and.arrow.up") { exportPDF() }
                        .disabled(plan == nil || exporting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Options", systemImage: "slider.horizontal.3") { options = true }
                }
            }
            .sheet(isPresented: $picker) {
                CreationPhotoPicker(initial: project.itemIDs, limit: 120) { ids in
                    project.itemIDs = ids
                }
            }
            .sheet(isPresented: $options) {
                BookOptionsView(project: $project)
                    .presentationDetents([.large])
            }
            .sheet(item: $share) { payload in
                ShareSheet(items: payload.items).ignoresSafeArea()
            }
            .alert("Could not build the book", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .overlay {
                if loading || exporting {
                    ProgressView(exporting ? "Laying out your book…" : "Curating photos…")
                        .padding(22)
                        .glassEffect(in: .rect(cornerRadius: 20))
                }
            }
            .task {
                if project.itemIDs.isEmpty { await curate() }
            }
            .task(id: planKey) { await rebuild() }
            .task(id: project) { await autosave() }
        }
    }

    private var bookPreview: some View {
        Group {
            if displayGroups.isEmpty {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.quaternary)
                    .aspectRatio(max(project.pageAspect, 0.4), contentMode: .fit)
                    .overlay {
                        if loading {
                            ProgressView()
                        } else {
                            ContentUnavailableView(
                                "Make a book", systemImage: "book.closed",
                                description: Text("Curate a set of photos to begin."))
                        }
                    }
            } else {
                TabView(selection: $pageIndex) {
                    ForEach(Array(displayGroups.enumerated()), id: \.offset) { index, group in
                        HStack(spacing: 8) {
                            ForEach(group) { page in
                                BookPagePreview(
                                    page: page, items: lookup, finish: project.finish,
                                    pageAspect: project.pageAspect)
                            }
                        }
                        .padding(.horizontal, 20)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: previewHeight)
                .accessibilityIdentifier("book.preview")
            }
        }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
    }

    private var previewHeight: CGFloat {
        horizontalSizeClass == .regular ? 620 : 500
    }

    private var pageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(displayGroups.enumerated()), id: \.offset) { index, group in
                    Button {
                        pageIndex = index
                    } label: {
                        HStack(spacing: 3) {
                            ForEach(group) { page in
                                BookPagePreview(
                                    page: page, items: lookup, finish: project.finish,
                                    pageAspect: project.pageAspect, cornerRadius: 2
                                )
                                .frame(width: 44)
                            }
                        }
                        .padding(3)
                        .background(
                            pageIndex == index ? Color.primary.opacity(0.16) : Color.clear,
                            in: .rect(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pageLabel(group, index: index))
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 80)
    }

    private var pageCaption: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pageLabel(currentGroup, index: pageIndex))
                    .font(.subheadline.weight(.semibold))
                if let page = currentGroup.first {
                    Text(page.kind == "cover" ? "Cover" : "\(page.cells.count) photos")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(min(pageIndex + 1, displayGroups.count)) of \(displayGroups.count)")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var quickControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BookStyle.allCases) { style in
                    Button {
                        project.bookStyle = style
                    } label: {
                        Text(style.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .foregroundStyle(
                                project.bookStyle == style ? Color(uiColor: .systemBackground) : .primary
                            )
                            .background(
                                project.bookStyle == style ? Color.primary : Color.primary.opacity(0.06),
                                in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button("Shuffle", systemImage: "shuffle") { project.seed &+= 1 }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .glassEffect(in: .capsule)
            }
        }
    }

    private var curateControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Curate the book").font(.headline)
                    Text("Choose from \(sourceItems.count.formatted()) items")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Stepper("\(fillCount)", value: $fillCount, in: 8...120, step: 4).labelsHidden()
                Text("\(fillCount)").monospacedDigit().frame(minWidth: 30)
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
                    Task { await curate() }
                } label: {
                    Label("Smart curate", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("book.curate")
                .disabled(loading)
            }
            HStack(spacing: 10) {
                Button("Photos", systemImage: "photo.badge.plus") { picker = true }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.glass)
                Button("Book settings", systemImage: "book.pages") { options = true }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.glass)
            }
            if let plan {
                Text(
                    "\(plan.photoCount.formatted()) photos · \(plan.pageCount.formatted()) pages · \(plan.events.count.formatted()) chapter\(plan.events.count == 1 ? "" : "s")"
                )
                .font(.caption).foregroundStyle(.secondary)
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

    private func pageLabel(_ group: [CoreBookPage], index: Int) -> String {
        guard let first = group.first else { return "Page" }
        if first.kind == "cover" { return "Cover" }
        if group.count == 2 { return "Pages \(first.index)–\(group[1].index)" }
        return "Page \(first.index)"
    }

    private func curate() async {
        guard !sourceItems.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let picks = try await MosaicCoreStore.shared.select(
                items: store.items, descriptors: descriptors, favorites: store.favorites,
                count: min(fillCount, sourceItems.count), diversity: 0.7,
                minGapSeconds: 12, preferRecent: true,
                seed: UInt64(Date().timeIntervalSince1970), ids: sourceItems.map(\.id))
            if !picks.isEmpty {
                project.itemIDs = picks.map(\.id)
                pageIndex = 0
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rebuild() async {
        let media = items
        guard !media.isEmpty else {
            plan = nil
            return
        }
        let request = CoreBookRequest(
            items: media.map { item in
                let descriptor = descriptors[item.id]
                return CoreBookItem(
                    id: item.id, date: item.date.timeIntervalSince1970,
                    width: item.width, height: item.height,
                    theme: descriptor?.theme, color: descriptor?.color ?? "Neutral",
                    favorite: store.favorites.contains(item.id),
                    quality: min(1, Double(item.width * item.height) / 12_000_000))
            },
            pageAspect: project.pageAspect, spread: project.spread,
            style: project.bookStyle.rawValue, seed: project.seed,
            includeCover: project.includeCover, title: project.title,
            subtitle: project.subtitle, maxPerPage: project.maxPerPage,
            spacing: 0.014, padding: 0.028)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try MosaicCoreBridge.book(request)
            }.value
            if !Task.isCancelled {
                plan = result
                if pageIndex >= max(displayGroups.count, 1) { pageIndex = 0 }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func autosave() async {
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        creations.save(project)
    }

    private func exportPDF() {
        guard let plan, !items.isEmpty else { return }
        exporting = true
        let project = project
        let items = items
        Task {
            let url = await Task.detached(priority: .userInitiated) {
                await CreationExporter.bookPDF(project: project, plan: plan, items: items)
            }.value
            exporting = false
            if let url {
                share = SharePayload(items: [url])
            } else {
                error = "The PDF could not be written. Free some storage or try a smaller book."
            }
        }
    }
}

// MARK: - Options

private struct BookOptionsView: View {
    @Binding var project: CreationProject
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Book") {
                    TextField("Title", text: $project.title)
                    TextField("Subtitle", text: $project.subtitle)
                }
                Section("Tone") {
                    Picker("Page rhythm", selection: $project.bookStyle) {
                        ForEach(BookStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    Text(project.bookStyle.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Page size", selection: $project.pageAspectChoice) {
                        ForEach(PageAspect.allCases) { aspect in
                            Text(aspect.title).tag(aspect)
                        }
                    }
                }
                Section("Layout") {
                    Toggle("Facing-page spreads", isOn: $project.spread)
                    Toggle("Include cover", isOn: $project.includeCover)
                    Stepper(
                        "Up to \(project.maxPerPage) photos per page", value: $project.maxPerPage, in: 1...9)
                    Button("Shuffle page arrangements", systemImage: "shuffle") {
                        project.seed &+= 1
                    }
                }
                Section("Finish") {
                    Picker("Page background", selection: $project.finish) {
                        ForEach(CollageFinish.allCases) { finish in
                            Text(finish.title).tag(finish)
                        }
                    }
                }
            }
            .navigationTitle("Book settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
