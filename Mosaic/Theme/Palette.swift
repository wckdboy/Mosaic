import SwiftUI

// Color tokens from BRANDING.md. Mirrors the structure of Omnie's other
// apps (see omnie-edit/OmnieEdit/Theme/Palette.swift) so Mosaic's UI stays
// traceable back to the shared brand guide.
enum BrandPalette {

    // Warm neutrals: the default theme people see in System/Light/Dark mode.
    enum Neutral {
        static let background = Color(light: Color(hex: 0xF6F6F4), dark: Color(hex: 0x101010))
        static let text = Color(light: Color(hex: 0x161616), dark: Color(hex: 0xE6E6E3))
        static let secondary = Color(light: Color(hex: 0x6E6E6A), dark: Color(hex: 0x8E8E8A))
        static let hairline = Color(light: Color(hex: 0xD8D8D4), dark: Color(hex: 0x2A2A2A))
    }

    // True monochrome: the alternate, pure black/white theme from BRANDING.md section 2.1.
    enum Monochrome {
        static let background = Color(light: .white, dark: .black)
        static let text = Color(light: .black, dark: .white)
        static let secondary = Color(light: Color(hex: 0x6A6A6A), dark: Color(hex: 0x9A9A9A))
        static let hairline = Color(light: Color(hex: 0xE0E0E0), dark: Color(hex: 0x2A2A2A))
    }

    // The one accent: purple into orange, diagonal. BRANDING.md section 2.2 reserves
    // this for exactly one primary action or active/selected state per screen.
    static let accentGradient = LinearGradient(
        colors: [Color(hex: 0x9E2EDB), Color(hex: 0xFA9429)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    // Resolves to `light` or `dark` based on the current interface style,
    // the same dynamic-color shape UIKit/AppKit expect.
    init(light: Color, dark: Color) {
        self.init(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// The single accent treatment BRANDING.md section 4 describes for a screen's one
// primary action: a gradient fill behind clear Liquid Glass. This is a floating
// action button, not a toolbar style — toolbar items should stay plain glass,
// which the system already provides automatically.
struct AccentGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(BrandPalette.accentGradient, in: Circle())
            .glassEffect(.clear.interactive(), in: Circle())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension ButtonStyle where Self == AccentGlassButtonStyle {
    static var accentGlass: AccentGlassButtonStyle { AccentGlassButtonStyle() }
}
