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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Folder", systemImage: "folder.badge.plus") {}
                        .buttonStyle(.accentGlass)
                        .labelStyle(.iconOnly)
                }
            }
        }
    }
}

#Preview {
    FilesView()
}
