import SwiftUI

// The root owns navigation and transient errors. Permission requests remain inside
// explicit user actions; foreground entry refreshes authorized sources only.
struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        @Bindable var store = store
        TabView {
            Tab("Library", systemImage: "square.grid.2x2") { LibraryView() }
            Tab("Collections", systemImage: "rectangle.stack") { CollectionsView() }
        }
        .disabled(!store.isReady)
        .tint(.primary)
        // Explicit asset tint keeps an active switch legible in dark appearance;
        // inheriting white navigation tint makes its white thumb disappear.
        .toggleStyle(SwitchToggleStyle(tint: Color("AccentColor")))
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .top) {
            if let message = store.message {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle")
                    Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss", systemImage: "xmark") { store.message = nil }.labelStyle(.iconOnly)
                }
                .padding().glassEffect(in: .rect(cornerRadius: 20)).padding()
                .accessibilityElement(children: .contain)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await store.refreshPhotos()
                    await store.refreshFolders()
                }
            } else if phase == .background {
                store.stopIndexing()
                Task { await store.flush() }
            }
        }
    }
}
