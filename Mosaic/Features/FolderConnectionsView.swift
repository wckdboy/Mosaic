import SwiftUI
import UniformTypeIdentifiers

// Folder grants are a user decision. Disconnecting removes only Mosaic's index,
// while future foreground scans discover additions and removals inside the tree.
struct FolderConnectionsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var choosing = false
    @State private var disconnecting: FolderConnection?
    var body: some View {
        List {
            Section {
                ForEach(store.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .swipeActions { Button("Disconnect", role: .destructive) { disconnecting = folder } }
                }
                Button("Connect folder…", systemImage: "folder.badge.plus") { choosing = true }
                Button("Scan connected folders", systemImage: "arrow.clockwise") {
                    Task { await store.refreshFolders() }
                }.disabled(store.scanningFolders || store.folders.isEmpty)
                if store.scanningFolders { ProgressView("Discovering media…") }
            } header: {
                Text("Automatic discovery")
            } footer: {
                Text(
                    "Connect Downloads or any other folder in Files. Mosaic discovers images, GIFs, and videos in its subfolders and rescans when you reopen the app. Cloud providers may need a connection to list their contents."
                )
            }
            Section("Access on iPhone") {
                Text(
                    "iOS requires you to choose each folder once. Mosaic cannot search other apps’ private storage or folders you have not authorized. Photos access and folder access are separate permissions."
                )
                Text(
                    "Original files stay in place unless you choose to move them in Auto organize. Disconnecting a folder removes its discovered items from Mosaic without changing the files."
                )
            }.font(.subheadline).foregroundStyle(.secondary)
        }
        .navigationTitle("Folders & discovery").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await store.connectFolder(url) }
            case .failure(let error): store.message = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Disconnect folder?",
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } })
        ) {
            Button("Disconnect", role: .destructive) {
                if let disconnecting { store.disconnectFolder(disconnecting) }
                disconnecting = nil
            }
        } message: {
            Text("Original files remain untouched.")
        }
    }
}
