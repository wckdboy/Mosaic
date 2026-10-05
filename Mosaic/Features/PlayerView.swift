import SwiftUI

// Full-screen photo and video playback. No primary action lives here —
// per BRANDING.md, the accent is reserved for screens with one clear choice,
// and a viewer's job is to get out of the way of the media.
struct PlayerView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Nothing Playing",
                systemImage: "play.circle",
                description: Text("Select a photo or video from your library to play it here.")
            )
            .navigationTitle("Player")
        }
    }
}

#Preview {
    PlayerView()
}
