import SwiftUI

// Order is the story. This sheet is deliberately a list, not a grid, so drag and
// drop has a clear destination and the date of each photo stays visible.
struct BookPhotosView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var project: CreationProject
    @State private var adding = false

    var body: some View {
        NavigationStack {
            Group {
                if project.itemIDs.isEmpty {
                    ContentUnavailableView(
                        "No photos yet", systemImage: "photo.on.rectangle.angled",
                        description: Text("Add photos to start building the book."))
                } else {
                    List {
                        ForEach(project.itemIDs, id: \.self) { id in
                            if let item = store.item(id) {
                                HStack(spacing: 12) {
                                    MediaThumbnail(item: item, pixels: 180)
                                        .frame(width: 54, height: 54)
                                        .clipShape(.rect(cornerRadius: 7))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "line.3.horizontal")
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .onMove { offsets, destination in
                            project.itemIDs.move(fromOffsets: offsets, toOffset: destination)
                        }
                        .onDelete { offsets in
                            project.itemIDs.remove(atOffsets: offsets)
                        }
                    }
                }
            }
            .navigationTitle("Photos in this book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Add photos", systemImage: "plus") { adding = true }
                }
            }
            .sheet(isPresented: $adding) {
                CreationPhotoPicker(initial: project.itemIDs, limit: 120) { ids in
                    project.itemIDs = ids
                }
            }
        }
    }
}
