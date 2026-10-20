import SwiftUI

// A quiet project shelf. Multiple books and collages are first-class: each has a
// cover, a state, and the usual rename/duplicate/delete actions, without turning the
// browsing tabs into a file manager.
struct CreationLibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(CreationStore.self) private var creations
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var editing: CreationProject?
    @State private var renaming: CreationProject?
    @State private var renameText = ""

    private enum Filter: String, CaseIterable, Identifiable {
        case all, collages, books
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .collages: "Collages"
            case .books: "Books"
            }
        }
    }

    private var filtered: [CreationProject] {
        creations.projects.filter { project in
            switch filter {
            case .all: break
            case .collages: if project.kind != .collage { return false }
            case .books: if project.kind != .photobook { return false }
            }
            guard !query.isEmpty else { return true }
            return project.title.localizedStandardContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    if filtered.isEmpty {
                        empty
                    } else {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14),
                            ],
                            spacing: 20
                        ) {
                            ForEach(filtered) { project in
                                card(project)
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 60)
            }
            .mosaicBackground()
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search projects")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New collage", systemImage: "square.on.square.dashed") {
                            editing = .collage(
                                itemIDs: [], title: CreationProject.suggestedTitle(.collage))
                        }
                        Button("New photobook", systemImage: "book.closed") {
                            editing = .photobook(
                                itemIDs: [], title: CreationProject.suggestedTitle(.photobook))
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("projects.new")
                }
            }
            .fullScreenCover(item: $editing) { project in
                if project.kind == .collage {
                    CollageStudioView(project: project)
                } else {
                    BookStudioView(project: project)
                }
            }
            .alert("Rename project", isPresented: .constant(renaming != nil)) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let renaming { creations.rename(renaming, to: renameText) }
                    renaming = nil
                    renameText = ""
                }
                Button("Cancel", role: .cancel) {
                    renaming = nil
                    renameText = ""
                }
            } message: {
                Text("Give this project a name you will recognize later.")
            }
        }
    }

    private func card(_ project: CreationProject) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                editing = project
            } label: {
                VStack(alignment: .leading, spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(uiColor: .secondarySystemBackground))
                        if let item = coverItem(project) {
                            MediaThumbnail(item: item, pixels: 420)
                                .clipShape(.rect(cornerRadius: 16))
                        } else {
                            Image(systemName: project.kind.symbol)
                                .font(.largeTitle.weight(.ultraLight)).foregroundStyle(.secondary)
                        }
                        if project.kind == .photobook {
                            VStack {
                                Spacer()
                                HStack {
                                    Image(systemName: "book.closed")
                                    Text("BOOK").font(.caption2.weight(.bold)).tracking(1)
                                }
                                .foregroundStyle(.white)
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    LinearGradient(
                                        colors: [.clear, .black.opacity(0.55)],
                                        startPoint: .center, endPoint: .bottom))
                            }
                            .clipShape(.rect(cornerRadius: 16))
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(
                            "\(project.itemIDs.count) items · \(project.updatedAt.formatted(date: .abbreviated, time: .omitted))"
                        )
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("projects.card.\(project.id.uuidString)")
            Menu {
                Button("Rename", systemImage: "pencil") {
                    renaming = project
                    renameText = project.title
                }
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    creations.duplicate(project)
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    creations.delete(project)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.32), in: Circle())
            }
            .padding(8)
            .accessibilityIdentifier("projects.menu")
        }
    }

    private func coverItem(_ project: CreationProject) -> MediaItem? {
        if let id = project.coverItemID, let item = store.item(id) { return item }
        return project.itemIDs.first.flatMap { store.item($0) }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "square.stack.3d.up").font(.title.weight(.ultraLight))
                .foregroundStyle(.secondary)
            Text("No projects yet").font(.headline)
            Text("Start a collage or photobook from Create, or add photos while browsing.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 20))
    }
}
