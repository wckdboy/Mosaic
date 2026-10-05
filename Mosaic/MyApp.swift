import SwiftUI

// One observable store is shared across tabs and viewers. AppStorage keeps visual
// preferences local, while the repository persists the user’s organization.
@main struct MosaicApp: App {
    @State private var store: LibraryStore = {
        #if DEBUG
            if let fixture = UITestFixture.storeIfRequested() { return fixture }
        #endif
        return LibraryStore()
    }()
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task { await store.start() }
                .onOpenURL { url in Task { await store.openFiles([url]) } }
        }
    }
}
