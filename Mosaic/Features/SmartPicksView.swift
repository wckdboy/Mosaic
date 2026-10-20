import SwiftUI

// Smart picks turns a large library into a small, varied set. The ranking is local:
// the Rust engine combines resolution, favorites, freshness, and visual/theme
// diversity, and suppresses burst duplicates. Every pick shows why it was chosen.
struct SmartPicksView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: [MediaItem]
    let initialCount: Int
    let onUse: (CreationProject.Kind, [MediaItem]) -> Void
    @State private var count = 24
    @State private var diversity = 0.62
    @State private var avoidDuplicates = true
    @State private var selections: [CoreSelection] = []
    @State private var loading = true
    @State private var error: String?

    init(
        source: [MediaItem], initialCount: Int = 24,
        onUse: @escaping (CreationProject.Kind, [MediaItem]) -> Void
    ) {
        self.source = source
        self.initialCount = initialCount
        self.onUse = onUse
        _count = State(initialValue: min(max(initialCount, 4), 60))
    }

    private var pickedItems: [MediaItem] {
        selections.compactMap { store.item($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    controls
                    if loading {
                        ProgressView("Choosing a varied set…")
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else if let error {
                        ContentUnavailableView(
                            "Could not choose photos", systemImage: "exclamationmark.triangle",
                            description: Text(error))
                    } else {
                        grid
                    }
                }
                .padding(20)
                .padding(.bottom, 100)
            }
            .mosaicBackground()
            .navigationTitle("Smart picks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await pick() } }
                        .disabled(loading)
                }
            }
            .safeAreaInset(edge: .bottom) { actions }
            .task { await pick() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A book needs a point of view.")
                .font(.system(.title2, design: .rounded, weight: .semibold))
            Text(
                "Mosaic chooses sharp, favorite, and visually different moments from \(source.count.formatted()) items, then keeps near-duplicates out."
            )
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Photos").font(.subheadline.weight(.medium))
                Spacer()
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                Stepper("", value: $count, in: 4...60, step: 2).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Variety").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(diversity.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $diversity, in: 0...1)
            }
            Toggle("Avoid near-duplicates", isOn: $avoidDuplicates)
            HStack(spacing: 10) {
                Button("Choose again") { Task { await pick() } }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .glassEffect(in: .capsule)
                Button("Save collection", systemImage: "rectangle.stack.badge.plus") {
                    guard !pickedItems.isEmpty else { return }
                    store.createCollection(
                        "Smart picks", items: Set(pickedItems.map(\.id)))
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .glassEffect(in: .capsule)
                .disabled(pickedItems.isEmpty)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 20))
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(selections) { selection in
                if let item = store.item(selection.id) {
                    VStack(alignment: .leading, spacing: 6) {
                        MediaThumbnail(item: item, pixels: 500)
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(.rect(cornerRadius: 12))
                        HStack(spacing: 4) {
                            Image(systemName: reasonSymbol(selection.reason))
                            Text(selection.reason).lineLimit(1)
                        }
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("smartPick.\(selection.id)")
                    .contextMenu {
                        Button("Remove", systemImage: "minus.circle") {
                            selections.removeAll { $0.id == selection.id }
                        }
                        Button("Open full screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                            // The picker is about selection; opening media would
                            // leave the curation flow, so this stays a preview.
                        }
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                handOff(.collage)
            } label: {
                Label("Collage", systemImage: "square.on.square.dashed")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
            }
            .buttonStyle(.glass)
            .disabled(pickedItems.isEmpty)

            Button {
                handOff(.photobook)
            } label: {
                Label("Photobook", systemImage: "book.closed")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
            }
            .buttonStyle(.glassProminent)
            .disabled(pickedItems.isEmpty)
        }
        .padding(16)
        .background(.bar)
    }

    // Let the cover finish dismissing before presenting the studio. Presenting a
    // second full-screen cover while this one is still on screen can be dropped.
    private func handOff(_ kind: CreationProject.Kind) {
        let picked = pickedItems
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            onUse(kind, picked)
        }
    }

    private func pick() async {
        loading = true
        error = nil
        let descriptors = MosaicIndexer.shared.descriptors
        do {
            let rows = try await MosaicCoreStore.shared.select(
                items: store.items, descriptors: descriptors, favorites: store.favorites,
                count: count, diversity: diversity,
                minGapSeconds: avoidDuplicates ? 8 : 0,
                preferRecent: true, seed: UInt64(Date().timeIntervalSince1970),
                ids: source.map(\.id))
            selections = rows
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func reasonSymbol(_ reason: String) -> String {
        switch reason {
        case "Favorite": "heart"
        case "Adds variety": "square.stack.3d.up"
        case "Detailed frame": "camera.aperture"
        case "Spaced in time": "clock"
        default: "sparkles"
        }
    }
}
