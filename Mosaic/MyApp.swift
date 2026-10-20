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
    @State private var creations: CreationStore = {
        #if DEBUG
            // UI tests must never inherit a person's saved projects (or projects from
            // a previous run). Each launch gets a fresh temporary recipe store.
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                let root = URL.temporaryDirectory.appending(
                    path: "Mosaic-UI-Creations-\(UUID().uuidString)", directoryHint: .isDirectory)
                return CreationStore(url: root.appending(path: "creations.json"))
            }
        #endif
        return CreationStore()
    }()
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(creations)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task { await store.start() }
                .onOpenURL { url in Task { await store.openFiles([url]) } }
        }
    }
}
