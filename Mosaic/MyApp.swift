import SwiftUI

// Entry point for the Mosaic app. A single window hosts the root view;
// navigation between the file manager, library, and player lives inside `ContentView`.
@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
