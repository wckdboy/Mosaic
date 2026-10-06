import SwiftUI

// Collections store stable media identifiers, not duplicate files. Smart groups
// are derived views, while named collections are saved in the local archive.
struct CollectionsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var creating = false
    @State private var name = ""
    @State private var deleting: MediaCollection?
    @State private var groups = Groups()
    // Smart groups and memberships are derived in one background pass when inputs
    // change, rather than filtering the whole library several times per render.
    struct Groups: Sendable {
        var favorites: [MediaItem] = []
        var videos: [MediaItem] = []
        var animated: [MediaItem] = []
        var live: [MediaItem] = []
        var members: [UUID: [MediaItem]] = [:]
    }
    private struct GroupKey: Equatable {
        let items: [MediaItem]
        let favorites: Set<String>
        let collections: [MediaCollection]
    }
    private nonisolated static func derive(_ key: GroupKey) -> Groups {
        var groups = Groups()
        for item in key.items {
            if key.favorites.contains(item.id) { groups.favorites.append(item) }
            switch item.kind {
            case .video: groups.videos.append(item)
            case .animated: groups.animated.append(item)
            case .livePhoto: groups.live.append(item)
            case .photo: break
            }
            for collection in key.collections where collection.itemIDs.contains(item.id) {
                groups.members[collection.id, default: []].append(item)
            }
        }
        return groups
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        smartCollection(
                            "Favorites", symbol: "heart",
                            items: groups.favorites)
                        smartCollection(
                            "Videos", symbol: "play.rectangle",
                            items: groups.videos)
                        smartCollection(
                            "Animated", symbol: "square.stack.3d.forward.dottedline",
                            items: groups.animated)
                        smartCollection(
                            "Live Photos", symbol: "livephoto",
                            items: groups.live)
                    }
                    HStack {
                        Text("Your collections").font(.title3.weight(.semibold))
                        Spacer()
                        Text(store.collections.count.formatted()).foregroundStyle(.secondary)
                    }
                    if store.collections.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "rectangle.stack.badge.plus").font(
                                .largeTitle.weight(.ultraLight))
                            Text("No collections yet").font(.headline)
                            Text("Group the things that belong together.").foregroundStyle(.secondary)
                            Button("Create collection") { creating = true }.buttonStyle(.glass).padding(
                                .top, 4)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(24).background(
                            .quaternary.opacity(0.4), in: .rect(cornerRadius: 24))
                    } else {
                        ForEach(store.collections) { collection in
                            let media = groups.members[collection.id] ?? []
                            NavigationLink {
                                MediaBrowser(title: collection.name, items: media, collection: collection)
                            } label: {
                                HStack(spacing: 16) {
                                    collectionCover(media, symbol: "rectangle.stack").frame(
                                        width: 72, height: 72
                                    ).clipShape(.rect(cornerRadius: 14))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(collection.name).font(.headline)
                                        Text("\(media.count) items").font(.subheadline).foregroundStyle(
                                            .secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(
                                        .tertiary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete collection", systemImage: "trash", role: .destructive) {
                                        deleting = collection
                                    }
                                }
                        }
                    }
                }.padding(20).padding(.bottom, 80)
            }
            .mosaicBackground().navigationTitle("Collections")
            .task(id: GroupKey(items: store.items, favorites: store.favorites, collections: store.collections)) {
                let key = GroupKey(items: store.items, favorites: store.favorites, collections: store.collections)
                let derived = await Task.detached(priority: .userInitiated) { Self.derive(key) }.value
                if !Task.isCancelled { groups = derived }
            }
            .toolbar { Button("New collection", systemImage: "plus") { creating = true } }
            .alert("New collection", isPresented: $creating) {
                TextField("Collection name", text: $name)
                Button("Create") {
                    store.createCollection(name)
                    name = ""
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { name = "" }
            } message: {
                Text("Choose a name.")
            }
            .confirmationDialog(
                "Delete this collection?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
            ) {
                Button("Delete collection", role: .destructive) {
                    if let deleting { store.deleteCollection(deleting) }
                    deleting = nil
                }
            } message: {
                Text("Your original photos and videos will remain untouched.")
            }
        }
    }
    private func smartCollection(_ title: String, symbol: String, items: [MediaItem]) -> some View {
        NavigationLink {
            MediaBrowser(title: title, items: items)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                collectionCover(items, symbol: symbol).frame(height: 142).clipShape(.rect(cornerRadius: 20))
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(items.count.formatted()).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func collectionCover(_ items: [MediaItem], symbol: String) -> some View {
        if let item = items.first {
            MediaThumbnail(item: item).overlay(alignment: .bottomLeading) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.white).padding(12).background(
                    .black.opacity(0.25), in: Circle()
                ).padding(10)
            }
        } else {
            Rectangle().fill(.quaternary.opacity(0.6)).overlay {
                Image(systemName: symbol).font(.system(size: 32, weight: .ultraLight)).foregroundStyle(
                    .secondary)
            }
        }
    }
}

struct OrganizeSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let selection: Set<String>
    @State private var name = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("New collection name", text: $name)
                        Button("Create") {
                            store.createCollection(name, items: selection)
                            dismiss()
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Create a collection")
                } footer: {
                    Text("Organizing \(selection.count) items. Originals stay in place.")
                }
                Section("Add to existing") {
                    ForEach(store.collections) { collection in
                        Button {
                            store.add(selection, to: collection)
                            dismiss()
                        } label: {
                            Label(collection.name, systemImage: "rectangle.stack")
                        }
                    }
                }
            }
            .navigationTitle("Add to collection").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}
