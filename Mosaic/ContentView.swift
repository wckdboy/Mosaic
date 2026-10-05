import SwiftUI

// Root navigation: Files, Library, and Player as top-level tabs. On iOS
// 26/27 the system renders the tab bar in Liquid Glass automatically —
// no extra styling needed here.
struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Files", systemImage: "folder") {
                FilesView()
            }
            Tab("Library", systemImage: "photo.on.rectangle") {
                LibraryView()
            }
            Tab("Player", systemImage: "play.circle") {
                PlayerView()
            }
        }
        .tint(.accentColor)
    }
}

#Preview {
    ContentView()
}
