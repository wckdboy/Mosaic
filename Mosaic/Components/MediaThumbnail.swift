import SwiftUI

// Cells request display-sized images on appearance and cancel on disappearance.
// The image itself is decorative; the owning Button supplies the accessible label.
struct MediaThumbnail: View {
    let item: MediaItem
    var pixels = 400
    @State private var image: UIImage?
    @State private var request = PhotoThumbnailRequest()
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    Image(systemName: item.kind.symbol).font(.title2).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: item.thumbnailKey) {
            image = nil
            if item.isPhotoLibrary {
                request.load(item, pixels: pixels) { image = $0 }
            } else {
                let result = await ThumbnailService.shared.image(for: item, pixels: pixels)
                if !Task.isCancelled { image = result }
            }
        }
        .onDisappear { request.cancel() }
        .accessibilityHidden(true)
    }
}

struct MediaTile: View {
    let item: MediaItem
    var favorite = false
    var selecting = false
    var selected = false
    var body: some View {
        MediaThumbnail(item: item)
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if favorite { Image(systemName: "heart.fill") }
                    if item.kind == .video {
                        Image(systemName: "play.fill")
                        Text(item.duration > 0 ? item.durationLabel : "VIDEO")
                    }
                    if item.kind == .animated { Text("GIF") }
                    if item.kind == .livePhoto { Image(systemName: "livephoto") }
                }
                .font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.white).padding(8)
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2).foregroundStyle(selected ? Color.accentColor : .white)
                        .background(.black.opacity(0.2), in: Circle()).padding(7)
                }
            }
            .clipShape(.rect(cornerRadius: 5))
            .accessibilityLabel("\(item.name), \(item.kind.title)\(favorite ? ", favorite" : "")")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
