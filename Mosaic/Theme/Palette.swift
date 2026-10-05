import Photos
import SwiftUI
import UniformTypeIdentifiers

// Content stays neutral. The gradient belongs only to the primary connection action.
enum MosaicTheme {
    static let accent = LinearGradient(
        colors: [Color(hex: 0x9E2EDB), Color(hex: 0xFA9429)], startPoint: .topLeading,
        endPoint: .bottomTrailing)
    static let warmBackground = Color(
        uiColor: UIColor {
            $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.063, green: 0.063, blue: 0.063, alpha: 1)
                : UIColor(red: 0.965, green: 0.965, blue: 0.957, alpha: 1)
        })
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255)
    }
}

struct MosaicBackground: ViewModifier {
    @AppStorage("monochrome") private var monochrome = false
    func body(content: Content) -> some View {
        content.background(monochrome ? Color(uiColor: .systemBackground) : MosaicTheme.warmBackground)
    }
}

extension View {
    func mosaicBackground() -> some View { modifier(MosaicBackground()) }
}

struct SectionEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
    }
}

struct ConnectLibraryView: View {
    @Environment(LibraryStore.self) private var store
    @State private var importing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ZStack {
                RoundedRectangle(cornerRadius: 24).fill(.quaternary).frame(width: 164, height: 196)
                    .rotationEffect(.degrees(-12)).offset(x: -37, y: 9)
                RoundedRectangle(cornerRadius: 24).fill(.tertiary.opacity(0.3)).frame(width: 164, height: 196)
                    .rotationEffect(.degrees(10)).offset(x: 36, y: 3)
                RoundedRectangle(cornerRadius: 24).fill(.background).frame(width: 164, height: 196)
                    .overlay {
                        Image(systemName: "photo.on.rectangle.angled").font(
                            .system(size: 52, weight: .ultraLight)
                        ).foregroundStyle(.primary)
                    }
            }
            .frame(maxWidth: .infinity).frame(height: 250).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                Text("Your library.").font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-1)
                Text("Choose photos or open files to get started.")
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 14) {
                Button {
                    if store.authorization == .denied || store.authorization == .restricted {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } else {
                        Task { await store.connectPhotos() }
                    }
                } label: {
                    Label(
                        store.authorization == .denied ? "Open Photo Settings" : "Connect Photos",
                        systemImage: "photo.badge.plus"
                    )
                    .font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 17)
                    .background(MosaicTheme.accent, in: Capsule()).glassEffect(.clear.interactive())
                }
                Button("Open from Files", systemImage: "folder") { importing = true }
                    .font(.subheadline.weight(.medium)).tint(.primary).padding(8)
            }
        }
        .padding(28)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            result in
            switch result {
            case .success(let urls): Task { await store.openFiles(urls) }
            case .failure(let error): store.message = error.localizedDescription
            }
        }
    }
}

// Viewer icon buttons keep a 44-point hit area even when their SF Symbol is small.
struct MediaControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}
