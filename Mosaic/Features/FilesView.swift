import SwiftUI
import UniformTypeIdentifiers

// References opened through the system picker remain at their provider locations.
// Forget removes a reference; it never deletes or moves the source file.
struct FilesView: View {
    @Environment(LibraryStore.self) private var store
    @State private var importing = false
    @State private var query = ""
    @State private var viewer: ViewerRoute?
    @State private var removing: MediaItem?
    private var files: [MediaItem] {
        MediaSort.newest.sorted(
            store.archive.files.filter { query.isEmpty || $0.name.localizedStandardContains(query) })
    }
    var body: some View {
        List {
            Section {
                Button {
                    importing = true
                } label: {
                    Label("Browse files", systemImage: "folder.badge.plus")
                        .font(.headline).padding(.vertical, 10)
                }.tint(.primary)
            }
            Section("Opened files · \(files.count)") {
                if files.isEmpty {
                    Text(query.isEmpty ? "No opened files" : "No files match your search.").foregroundStyle(
                        .secondary
                    ).padding(.vertical, 16)
                }
                ForEach(files) { item in
                    Button {
                        viewer = ViewerRoute(items: files, selectedID: item.id)
                    } label: {
                        HStack(spacing: 14) {
                            MediaThumbnail(item: item, pixels: 180).frame(width: 62, height: 62).clipShape(
                                .rect(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.name).font(.subheadline.weight(.medium)).lineLimit(2)
                                Text(
                                    "\(item.format) · \(item.date.formatted(date: .abbreviated, time: .omitted))"
                                ).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(
                                systemName: item.kind == .video
                                    ? "play.circle" : "arrow.up.left.and.arrow.down.right"
                            ).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                        .swipeActions { Button("Forget", role: .destructive) { removing = item } }
                }
            }
        }
        .scrollContentBackground(.hidden).mosaicBackground().navigationTitle("Files")
        .searchable(text: $query, prompt: "Search opened files")
        .toolbar {
            Button("Open files", systemImage: "plus") { importing = true }.disabled(store.isImporting)
        }
        .overlay {
            if store.isImporting {
                ProgressView("Opening files…").padding(24).glassEffect(in: .rect(cornerRadius: 24))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            result in
            switch result {
            case .success(let urls): Task { await store.openFiles(urls) }
            case .failure(let error): store.message = error.localizedDescription
            }
        }
        .fullScreenCover(item: $viewer) { MediaViewer(items: $0.items, initialID: $0.selectedID) }
        .confirmationDialog(
            "Forget this file?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Forget file", role: .destructive) {
                if let removing { store.forgetFile(removing) }
                removing = nil
            }
        } message: {
            Text(
                "This removes its reference and collection memberships from Mosaic. The original file will not be deleted."
            )
        }
    }
}
