import SwiftUI

// Photo and video library. On-device organizing surfaces structure here
// without ever sending media content off the device.
struct LibraryView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Photos or Videos Yet",
                systemImage: "photo.on.rectangle",
                description: Text("Import media to organize it, entirely on-device.")
            )
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import", systemImage: "square.and.arrow.down") {}
                        .buttonStyle(.accentGlass)
                        .labelStyle(.iconOnly)
                }
            }
        }
    }
}

#Preview {
    LibraryView()
}
