import Foundation

/// An sRGB colour. Themes are plain values so the app and its tests can
/// share them without AppKit.
public struct ThemeColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From 0xRRGGBB.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// A CSS colour: `#rrggbb`, or `rgb(r g b / a)` when translucent.
    public var css: String {
        func channel(_ value: Double) -> Int { Int((value * 255).rounded()) }
        if alpha >= 0.999 {
            return String(format: "#%02x%02x%02x", channel(red), channel(green), channel(blue))
        }
        return "rgb(\(channel(red)) \(channel(green)) \(channel(blue)) / \(String(format: "%.3g", alpha)))"
    }

    /// WCAG relative luminance, for checking contrast in tests.
    public var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// One named theme: a background, ink, a cursor and eight character
/// colours, with every token the app draws from derived from them. A theme
/// is either a light or a dark one; the user picks one of each.
public struct ThemePalette: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let dark: Bool
    /// The caret and the theme card's bar. Also the selection ring, so a
    /// picked theme shows its own cursor colour.
    public let cursor: ThemeColor
    /// The eight dots on the theme card, in a terminal's ANSI order.
    public let swatches: [ThemeColor]
    public let colors: [ThemeToken: ThemeColor]

    public func color(_ token: ThemeToken) -> ThemeColor? { colors[token] }

    /// Every token as CSS custom properties, for the live preview.
    public var cssVariables: [String: String] {
        var out: [String: String] = [:]
        for token in ThemeToken.allCases {
            if let color = colors[token] { out[token.rawValue] = color.css }
        }
        return out
    }

    public init(
        id: String,
        name: String,
        dark: Bool,
        bg: UInt32,
        fg: UInt32,
        cursor: UInt32,
        swatches: [UInt32],
        overrides: [ThemeToken: ThemeColor] = [:]
    ) {
        precondition(swatches.count == 8, "a theme needs eight swatches")
        let background = ThemeColor(hex: bg)
        let ink = ThemeColor(hex: fg)

        /// Move from the background toward the ink, the way surfaces and
        /// secondary text lift off the page.
        func mix(_ amount: Double) -> ThemeColor {
            ThemeColor(
                red: background.red + (ink.red - background.red) * amount,
                green: background.green + (ink.green - background.green) * amount,
                blue: background.blue + (ink.blue - background.blue) * amount
            )
        }

        var colors: [ThemeToken: ThemeColor] = [
            .bg: background,
            .surface: mix(dark ? 0.05 : 0.035),
            .surfaceRaised: mix(dark ? 0.09 : 0.06),
            .line: mix(dark ? 0.14 : 0.10),
            .guide: mix(dark ? 0.24 : 0.16),
            .fg: ink,
            .fgBody: mix(dark ? 0.82 : 0.80),
            .fgDim: mix(dark ? 0.58 : 0.55),
            .synKeyword: ThemeColor(hex: swatches[1]),
            .synString: ThemeColor(hex: swatches[5]),
            .synAttr: ThemeColor(hex: swatches[4]),
            .synNumber: ThemeColor(hex: swatches[3]),
            .synComment: mix(0.45),
            .edgeTop: ThemeColor(hex: dark ? 0xFFFFFF : 0x000000, alpha: dark ? 0.16 : 0.06),
            .edgeBottom: ThemeColor(hex: dark ? 0xFFFFFF : 0x000000, alpha: dark ? 0.06 : 0.13),
        ]
        colors.merge(overrides) { _, theme in theme }

        self.id = id
        self.name = name
        self.dark = dark
        self.cursor = ThemeColor(hex: cursor)
        self.swatches = swatches.map { ThemeColor(hex: $0) }
        self.colors = colors
    }
}

// MARK: - Built-in themes

public extension ThemePalette {
    /// The app's own palette. Every token matches page.css exactly, so the
    /// chrome, the preview and a published page read as one design.
    static let nautLight = ThemePalette(
        id: "naut-light", name: "Naut", dark: false,
        bg: 0xFBFBF9, fg: 0x161715, cursor: 0xC8502D,
        swatches: [0x161715, 0xC8502D, 0x3F7A4A, 0x9A6A10, 0x5B55D6, 0x8A3FC0, 0x2E7A80, 0x8D8F89],
        overrides: [
            .surface: ThemeColor(hex: 0xF3F3F0),
            .surfaceRaised: ThemeColor(hex: 0xECECE8),
            .line: ThemeColor(hex: 0xE0E0DB),
            .guide: ThemeColor(hex: 0xCFCFCA),
            .fgBody: ThemeColor(hex: 0x3B3D39),
            .fgDim: ThemeColor(hex: 0x7A7C76),
            .synKeyword: ThemeColor(hex: 0xC8502D),
            .synString: ThemeColor(hex: 0x8A3FC0),
            .synAttr: ThemeColor(hex: 0x5B55D6),
            .synNumber: ThemeColor(hex: 0x9A6A10),
            .synComment: ThemeColor(hex: 0x8D8F89),
        ]
    )

    static let nautDark = ThemePalette(
        id: "naut-dark", name: "Naut", dark: true,
        bg: 0x10120F, fg: 0xF1F1EE, cursor: 0xF2876A,
        swatches: [0x2C2D2B, 0xF2876A, 0x8FBF7A, 0xE7C27D, 0xA9A7F7, 0xCF9CF2, 0x6FC7C0, 0x7C7E78],
        overrides: [
            .surface: ThemeColor(hex: 0x191C17),
            .surfaceRaised: ThemeColor(hex: 0x1F201F),
            .line: ThemeColor(hex: 0x2C2D2B),
            .guide: ThemeColor(hex: 0x3E3F3C),
            .fgBody: ThemeColor(hex: 0xC4C5C0),
            .fgDim: ThemeColor(hex: 0x8B8D87),
            .synKeyword: ThemeColor(hex: 0xF2876A),
            .synString: ThemeColor(hex: 0xCF9CF2),
            .synAttr: ThemeColor(hex: 0xA9A7F7),
            .synNumber: ThemeColor(hex: 0xE7C27D),
            .synComment: ThemeColor(hex: 0x7C7E78),
        ]
    )

    static let newsprintFog = ThemePalette(
        id: "newsprint-fog", name: "Newsprint Fog", dark: false,
        bg: 0xF6F5F1, fg: 0x171614, cursor: 0xB23A2E,
        swatches: [0x171614, 0xB23A2E, 0x2E6A43, 0x9C6F16, 0x3B61A8, 0x7A4A9E, 0x2C767C, 0x8A8983]
    )

    static let orchardBreeze = ThemePalette(
        id: "orchard-breeze", name: "Orchard Breeze", dark: false,
        bg: 0xF1F5EA, fg: 0x1B291A, cursor: 0x3E7B45,
        swatches: [0x1B291A, 0xB14A32, 0x3E7B45, 0x93711B, 0x466A9E, 0x7C5AA6, 0x2F7A6E, 0x83907C]
    )

    static let lavenderPostcard = ThemePalette(
        id: "lavender-postcard", name: "Lavender Postcard", dark: false,
        bg: 0xF5F1FA, fg: 0x241E2E, cursor: 0x7A5AC8,
        swatches: [0x241E2E, 0xB1475C, 0x4B7A56, 0x9C7225, 0x5C63C6, 0x8A55B8, 0x3B7C8C, 0x8D8798]
    )

    static let staticNoir = ThemePalette(
        id: "static-noir", name: "Static Noir", dark: true,
        bg: 0x0C0C0D, fg: 0xF1EEE8, cursor: 0xE0443B,
        swatches: [0x2A2A2D, 0xE0443B, 0x4E9A5A, 0xC79A3E, 0x5B8FD6, 0xA873D1, 0x4FA3A8, 0xA9A49B]
    )

    static let sonoranDusk = ThemePalette(
        id: "sonoran-dusk", name: "Sonoran Dusk", dark: true,
        bg: 0x171310, fg: 0xEDE2D2, cursor: 0xD98A3F,
        swatches: [0x3A3028, 0xC6553F, 0x6F8B4E, 0xD99A45, 0x6A86B8, 0xA877B0, 0x5B9490, 0xAB9C8A]
    )

    static let velvetDusk = ThemePalette(
        id: "velvet-dusk", name: "Velvet Dusk", dark: true,
        bg: 0x141018, fg: 0xF0E7F6, cursor: 0xB07CE8,
        swatches: [0x322B3A, 0xD05C7A, 0x5E9567, 0xC9A046, 0x6E86D9, 0xB07CE8, 0x599FA6, 0xA79CAF]
    )

    static let lightThemes: [ThemePalette] = [
        .nautLight, .newsprintFog, .orchardBreeze, .lavenderPostcard,
    ]

    static let darkThemes: [ThemePalette] = [
        .nautDark, .staticNoir, .sonoranDusk, .velvetDusk,
    ]

    static let allThemes: [ThemePalette] = lightThemes + darkThemes

    /// The theme with this id and mode, or the app's own theme when the
    /// saved id no longer exists.
    static func named(_ id: String, dark: Bool) -> ThemePalette {
        let themes = dark ? darkThemes : lightThemes
        return themes.first { $0.id == id } ?? themes[0]
    }
}
