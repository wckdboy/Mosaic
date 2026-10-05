import SwiftUI

// Local file browsing. Files stay at their existing locations on disk;
// this view will host the browser once file access is wired up.
struct FilesView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Files Yet",
                systemImage: "folder",
                description: Text("Files you open will stay in place on your device.")
            )
            .navigationTitle("Files")
            .overlay(alignment: .bottomTrailing) {
                Button("New Folder", systemImage: "folder.badge.plus") {}
                    .labelStyle(.iconOnly)
                    .buttonStyle(.accentGlass)
                    .padding(24)
            }
        }
    }
}

#Preview {
    FilesView()
}
