import SwiftUI

/// The decorative motif drawn behind each theme (see Motifs.swift).
enum Motif: String, CaseIterable {
    case leaves, waves, sun, lavender, depths, petals, pines, studio, blossom, rays, mountains, dunes, meadow, linen, aurora, steam
}

/// One complete colour identity for a light or dark appearance.
struct ThemePalette {
    var backgroundTop: Color
    var backgroundBottom: Color
    /// Soft radial glow in the upper area of the window.
    var glow: Color
    var surface: Color
    var surfaceStrong: Color
    var stroke: Color
    var text: Color
    var secondaryText: Color
    var accent: Color
    var accentSoft: Color
    /// Text/icon colour on top of the accent.
    var onAccent: Color
    var record: Color
    var wave: [Color]
    var motif: Color
    var motifOpacity: Double
    var success: Color
    var warning: Color
}

struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let tagline: String
    let symbol: String
    let motif: Motif
    let titleDesign: Font.Design
    let light: ThemePalette
    let dark: ThemePalette
    /// The appearance the theme looks best in when the user chooses "Theme default".
    let preferred: ColorScheme

    static func == (a: Theme, b: Theme) -> Bool { a.id == b.id }

    func palette(_ scheme: ColorScheme) -> ThemePalette { scheme == .dark ? dark : light }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

private func lightPalette(top: UInt32, bottom: UInt32, glow: UInt32, text: UInt32, secondary: UInt32, accent: UInt32,
                          record: UInt32, wave: [UInt32], motif: UInt32, onAccent: UInt32 = 0xFFFFFF, motifOpacity: Double = 0.55) -> ThemePalette {
    ThemePalette(backgroundTop: Color(hex: top), backgroundBottom: Color(hex: bottom), glow: Color(hex: glow, opacity: 0.85),
                 surface: Color.white.opacity(0.66), surfaceStrong: Color.white.opacity(0.86), stroke: Color(hex: text, opacity: 0.08),
                 text: Color(hex: text), secondaryText: Color(hex: secondary), accent: Color(hex: accent),
                 accentSoft: Color(hex: accent, opacity: 0.14), onAccent: Color(hex: onAccent), record: Color(hex: record),
                 wave: wave.map { Color(hex: $0) }, motif: Color(hex: motif), motifOpacity: motifOpacity,
                 success: Color(hex: 0x3F8F5B), warning: Color(hex: 0xC27C1A))
}

private func darkPalette(top: UInt32, bottom: UInt32, glow: UInt32, text: UInt32, secondary: UInt32, accent: UInt32,
                         record: UInt32, wave: [UInt32], motif: UInt32, onAccent: UInt32 = 0x101010, motifOpacity: Double = 0.45) -> ThemePalette {
    ThemePalette(backgroundTop: Color(hex: top), backgroundBottom: Color(hex: bottom), glow: Color(hex: glow, opacity: 0.75),
                 surface: Color.white.opacity(0.06), surfaceStrong: Color.white.opacity(0.11), stroke: Color.white.opacity(0.09),
                 text: Color(hex: text), secondaryText: Color(hex: secondary), accent: Color(hex: accent),
                 accentSoft: Color(hex: accent, opacity: 0.18), onAccent: Color(hex: onAccent), record: Color(hex: record),
                 wave: wave.map { Color(hex: $0) }, motif: Color(hex: motif), motifOpacity: motifOpacity,
                 success: Color(hex: 0x7CCB8E), warning: Color(hex: 0xF0B45B))
}

enum ThemeCatalog {
    static let defaultId = "botanical"

    static func theme(_ id: String?) -> Theme { all.first { $0.id == id } ?? all[0] }

    static let all: [Theme] = [
        Theme(id: "botanical", name: "Botanical Garden", tagline: "Sage, fern and cream", symbol: "leaf.fill", motif: .leaves, titleDesign: .serif,
              light: lightPalette(top: 0xF4F2E8, bottom: 0xE2E9D6, glow: 0xD3E3C6, text: 0x24301F, secondary: 0x5F6F57, accent: 0x587F53,
                                  record: 0xC65D45, wave: [0x6E9A63, 0xB5CE9F], motif: 0x7E9E70),
              dark: darkPalette(top: 0x131E17, bottom: 0x1C2A21, glow: 0x2E4834, text: 0xEEF2E6, secondary: 0xA7B5A0, accent: 0x9CC48F,
                                record: 0xE58066, wave: [0x8DBA80, 0xD8E8C8], motif: 0x6E8F65),
              preferred: .light),
        Theme(id: "coastal", name: "Coastal Morning", tagline: "Seafoam, sand and soft aqua", symbol: "water.waves", motif: .waves, titleDesign: .rounded,
              light: lightPalette(top: 0xF6F9F6, bottom: 0xD8EEEA, glow: 0xF5E8D2, text: 0x1F3B40, secondary: 0x5D7A7D, accent: 0x2F8E8C,
                                  record: 0xE26D57, wave: [0x4DBAB5, 0xA6E1D9], motif: 0x86C6BF),
              dark: darkPalette(top: 0x0E2427, bottom: 0x153437, glow: 0x1F5052, text: 0xE8F5F3, secondary: 0x9DBFBD, accent: 0x6FD0C8,
                                record: 0xF08A70, wave: [0x5CC9C1, 0xBDEDE6], motif: 0x3E8C88),
              preferred: .light),
        Theme(id: "sunset", name: "Sunset Beach", tagline: "Coral, peach and golden light", symbol: "sun.horizon.fill", motif: .sun, titleDesign: .rounded,
              light: lightPalette(top: 0xFFF5EA, bottom: 0xFFD8C2, glow: 0xFFC58D, text: 0x4A2A22, secondary: 0x8A5A4C, accent: 0xDE5D43,
                                  record: 0xD0402F, wave: [0xFF8A5B, 0xFFC371], motif: 0xF29E78),
              dark: darkPalette(top: 0x29151F, bottom: 0x3D2027, glow: 0x7A3B3B, text: 0xFCEADF, secondary: 0xD5AFA2, accent: 0xFF8F6B,
                                record: 0xFF6B57, wave: [0xFF8F6B, 0xFFC97A], motif: 0xA8564A),
              preferred: .light),
        Theme(id: "lavender", name: "Lavender Fields", tagline: "Lilac and muted purple", symbol: "camera.macro", motif: .lavender, titleDesign: .serif,
              light: lightPalette(top: 0xF7F3FB, bottom: 0xE4D9F2, glow: 0xDCCBF2, text: 0x2F2540, secondary: 0x6E6283, accent: 0x7E62B5,
                                  record: 0xC4527A, wave: [0xA184D8, 0xD5C3F2], motif: 0xAE93D8),
              dark: darkPalette(top: 0x1A1625, bottom: 0x261F35, glow: 0x41336A, text: 0xF0EAFB, secondary: 0xB7ABCB, accent: 0xB9A1EB,
                                record: 0xE07AA0, wave: [0xA88BDB, 0xE2D4FA], motif: 0x6D5A99),
              preferred: .light),
        Theme(id: "ocean", name: "Ocean Depths", tagline: "Deep navy, teal and ocean blue", symbol: "drop.fill", motif: .depths, titleDesign: .default,
              light: lightPalette(top: 0xEDF5F9, bottom: 0xCCE1EC, glow: 0xBFE6EE, text: 0x0F2A3D, secondary: 0x4F6E82, accent: 0x1D6E97,
                                  record: 0xE0533A, wave: [0x2A9DB5, 0x7FD3E0], motif: 0x7DB3CB),
              dark: darkPalette(top: 0x06121E, bottom: 0x0B2236, glow: 0x0F4C5C, text: 0xE3F1F8, secondary: 0x8FB3C7, accent: 0x3FC1C9,
                                record: 0xFF6B57, wave: [0x2EC4B6, 0x5DA9E9], motif: 0x2A6F8F, motifOpacity: 0.55),
              preferred: .dark),
        Theme(id: "rosewater", name: "Rosewater", tagline: "Blush pink and warm ivory", symbol: "heart.fill", motif: .petals, titleDesign: .serif,
              light: lightPalette(top: 0xFFF9F5, bottom: 0xF7E0DF, glow: 0xF6D0CE, text: 0x3D2628, secondary: 0x85676A, accent: 0xB86A76,
                                  record: 0xC0434C, wave: [0xE59AA4, 0xF5C7C1], motif: 0xE6A9AF),
              dark: darkPalette(top: 0x231517, bottom: 0x331F20, glow: 0x5A2F35, text: 0xFBEDEB, secondary: 0xD2B2B1, accent: 0xF0A7AF,
                                record: 0xF07A7F, wave: [0xF0A7AF, 0xFAD5CF], motif: 0x8C5258),
              preferred: .light),
        Theme(id: "forest", name: "Forest Retreat", tagline: "Pine, moss and earth", symbol: "tree.fill", motif: .pines, titleDesign: .serif,
              light: lightPalette(top: 0xEFF2EB, bottom: 0xD5DDCD, glow: 0xC9D9BE, text: 0x1E2A1F, secondary: 0x56665A, accent: 0x3B6745,
                                  record: 0xB4533A, wave: [0x4F7F55, 0x9DB78E], motif: 0x5E7F5B),
              dark: darkPalette(top: 0x0D1912, bottom: 0x16261C, glow: 0x24402C, text: 0xE6EEE4, secondary: 0x9FB2A2, accent: 0x7FB28A,
                                record: 0xE07A55, wave: [0x6FA57A, 0xC2D8A8], motif: 0x355B40, motifOpacity: 0.6),
              preferred: .dark),
        Theme(id: "midnight", name: "Midnight Studio", tagline: "Charcoal and indigo", symbol: "moon.stars.fill", motif: .studio, titleDesign: .default,
              light: lightPalette(top: 0xF3F3F8, bottom: 0xDFE0EE, glow: 0xD3D5F5, text: 0x1C1D2B, secondary: 0x5E6079, accent: 0x4B4FB8,
                                  record: 0xDD4458, wave: [0x6366F1, 0xA5B4FC], motif: 0x9C9FD6),
              dark: darkPalette(top: 0x0B0C13, bottom: 0x151728, glow: 0x2B2E6B, text: 0xECECF6, secondary: 0x9A9BB8, accent: 0x8B8FFF,
                                record: 0xFF5470, wave: [0x7C83FF, 0xC3A6FF], motif: 0x3A3D7A, motifOpacity: 0.6),
              preferred: .dark),
        Theme(id: "cherry", name: "Cherry Blossom", tagline: "Soft pink and spring green", symbol: "camera.filters", motif: .blossom, titleDesign: .rounded,
              light: lightPalette(top: 0xFFF7F9, bottom: 0xF3E4EB, glow: 0xE6F1DE, text: 0x3A2530, secondary: 0x806571, accent: 0xCC6A8E,
                                  record: 0xCF4560, wave: [0xF29CB7, 0xBFD9B0], motif: 0xEFB2C6),
              dark: darkPalette(top: 0x21191E, bottom: 0x2E2229, glow: 0x55324A, text: 0xFBEFF4, secondary: 0xD0B5C2, accent: 0xF5A3C0,
                                record: 0xFF6F8B, wave: [0xF5A3C0, 0xCFE6BF], motif: 0x8A5470),
              preferred: .light),
        Theme(id: "golden", name: "Golden Hour", tagline: "Honey, amber and warm beige", symbol: "sun.max.fill", motif: .rays, titleDesign: .serif,
              light: lightPalette(top: 0xFFF9EC, bottom: 0xF6E1BA, glow: 0xFFD27A, text: 0x3B2C17, secondary: 0x7E6845, accent: 0xB57F1E,
                                  record: 0xC5523B, wave: [0xE8AE3C, 0xF6D58E], motif: 0xE3B866, onAccent: 0xFFFFFF),
              dark: darkPalette(top: 0x1E170F, bottom: 0x2C2115, glow: 0x6B4A1A, text: 0xFAF0DC, secondary: 0xCDB894, accent: 0xF2C35B,
                                record: 0xFF7B54, wave: [0xF2C35B, 0xFFE3A3], motif: 0x8C6A2E),
              preferred: .light),
        Theme(id: "alpine", name: "Alpine Air", tagline: "Icy blue, slate and snow", symbol: "mountain.2.fill", motif: .mountains, titleDesign: .default,
              light: lightPalette(top: 0xF8FBFD, bottom: 0xE1EAF2, glow: 0xFFFFFF, text: 0x1F2A36, secondary: 0x637487, accent: 0x40719C,
                                  record: 0xD5504C, wave: [0x6FA3D0, 0xB9D6EE], motif: 0xA9BFD3),
              dark: darkPalette(top: 0x111921, bottom: 0x1B2632, glow: 0x2C4257, text: 0xEAF2F9, secondary: 0xA2B4C6, accent: 0x8EC1EC,
                                record: 0xFF6B6B, wave: [0x8EC1EC, 0xDDEEFB], motif: 0x3E5870),
              preferred: .light),
        Theme(id: "desert", name: "Desert Bloom", tagline: "Terracotta, clay and cream", symbol: "camera.macro.circle.fill", motif: .dunes, titleDesign: .serif,
              light: lightPalette(top: 0xFCF4EB, bottom: 0xEFD9C4, glow: 0xF3C9A5, text: 0x3C2519, secondary: 0x866553, accent: 0xB65A36,
                                  record: 0xB23D2C, wave: [0xD9784F, 0xEDB48E], motif: 0xD69C79),
              dark: darkPalette(top: 0x22150E, bottom: 0x321F16, glow: 0x6A3622, text: 0xF8EADF, secondary: 0xCFB2A0, accent: 0xE8946B,
                                record: 0xFF7A5C, wave: [0xE8946B, 0xF6CCAE], motif: 0x7E4630),
              preferred: .light),
        Theme(id: "meadow", name: "Wildflower Meadow", tagline: "Pastels and floral accents", symbol: "camera.macro", motif: .meadow, titleDesign: .rounded,
              light: lightPalette(top: 0xFCFBF3, bottom: 0xEAF0DF, glow: 0xF8E3EF, text: 0x2E3326, secondary: 0x6B735E, accent: 0x6F8344,
                                  record: 0xCF5878, wave: [0xF2A7C3, 0xA7C7E7, 0xF5D78E], motif: 0xC9A3C8),
              dark: darkPalette(top: 0x191C16, bottom: 0x23291F, glow: 0x3E3448, text: 0xF1F4E8, secondary: 0xB5BCA6, accent: 0xB8CF87,
                                record: 0xF07C9A, wave: [0xF2A7C3, 0xA7C7E7, 0xF5D78E], motif: 0x6D5C74),
              preferred: .light),
        Theme(id: "linen", name: "Minimal Linen", tagline: "Oat, stone and ivory", symbol: "square.grid.3x3.fill", motif: .linen, titleDesign: .serif,
              light: lightPalette(top: 0xF8F5EF, bottom: 0xECE6DA, glow: 0xFFFFFF, text: 0x2B2824, secondary: 0x7A7268, accent: 0x7E6D57,
                                  record: 0xB0503D, wave: [0x9F907D, 0xD3C8B8], motif: 0xB9AD9B, motifOpacity: 0.35),
              dark: darkPalette(top: 0x1B1916, bottom: 0x26231F, glow: 0x3A352E, text: 0xF2EEE7, secondary: 0xB8AFA3, accent: 0xCDBBA0,
                                record: 0xE07A5F, wave: [0xCDBBA0, 0xEDE3D3], motif: 0x5A5247, motifOpacity: 0.35),
              preferred: .light),
        Theme(id: "aurora", name: "Aurora", tagline: "Atmospheric purple, teal and blue", symbol: "sparkles", motif: .aurora, titleDesign: .default,
              light: lightPalette(top: 0xF0F3FB, bottom: 0xE0E7F7, glow: 0xC7B8F5, text: 0x1E2140, secondary: 0x5A5F84, accent: 0x5257D0,
                                  record: 0xDD4B77, wave: [0x7F5AF0, 0x2CB1BC, 0x4C9AFF], motif: 0x8E7BEA),
              dark: darkPalette(top: 0x060A19, bottom: 0x0E1530, glow: 0x2C1F5E, text: 0xEAF0FF, secondary: 0x9AA6C8, accent: 0x7DE2D1,
                                record: 0xFF5C8A, wave: [0x7F5AF0, 0x2CE0C0, 0x4C9AFF], motif: 0x2CE0C0, motifOpacity: 0.5),
              preferred: .dark),
        Theme(id: "espresso", name: "Espresso", tagline: "Coffee, caramel and chocolate", symbol: "cup.and.saucer.fill", motif: .steam, titleDesign: .serif,
              light: lightPalette(top: 0xF9F3EB, bottom: 0xE8D8C4, glow: 0xE6C9A3, text: 0x2E1F16, secondary: 0x7A6151, accent: 0x85553A,
                                  record: 0xB0432E, wave: [0xA9714B, 0xD9B48A], motif: 0xC4A07E),
              dark: darkPalette(top: 0x16100C, bottom: 0x231812, glow: 0x4A2E1E, text: 0xF3E7DA, secondary: 0xB49C88, accent: 0xD39A6A,
                                record: 0xF07A55, wave: [0xC7834F, 0xE9C49A], motif: 0x5A3A28, motifOpacity: 0.55),
              preferred: .dark),
    ]
}

/// The appearance choice in Settings → Appearance.
enum AppearanceChoice: String, CaseIterable, Identifiable, Codable {
    case themeDefault, system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .themeDefault: return "Theme default"
        case .system: return "Match macOS"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// A theme resolved for the current appearance, injected into the environment.
struct ResolvedTheme {
    let theme: Theme
    let scheme: ColorScheme
    var palette: ThemePalette { theme.palette(scheme) }

    var background: LinearGradient {
        LinearGradient(colors: [palette.backgroundTop, palette.backgroundBottom], startPoint: .top, endPoint: .bottom)
    }
    var waveGradient: LinearGradient {
        LinearGradient(colors: palette.wave, startPoint: .leading, endPoint: .trailing)
    }
    func titleFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: theme.titleDesign)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ResolvedTheme(theme: ThemeCatalog.all[0], scheme: .light)
}

extension EnvironmentValues {
    var hmoTheme: ResolvedTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
