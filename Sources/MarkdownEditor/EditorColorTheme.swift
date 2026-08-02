import AppKit
import SwiftUI

/// Light or dark background, matching the Background radio group in the
/// kirupa.com "Customize Theme" dialog.
enum EditorAppearanceMode: String, CaseIterable, Identifiable {
    case light
    case dark

    static let storageKey = "editorAppearanceMode"

    static var systemDefault: Self {
        let globalPreferences = UserDefaults.standard.persistentDomain(
            forName: UserDefaults.globalDomain
        )
        return globalPreferences?["AppleInterfaceStyle"] as? String == "Dark"
            ? .dark
            : .light
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .light:
            "sun.max"
        case .dark:
            "moon"
        }
    }
}

/// The eight color choices offered by the kirupa.com theme selector.
enum EditorThemeColor: String, CaseIterable, Identifiable {
    case blue
    case yellow
    case pink
    case green
    case purple
    case pico8
    case black
    case brown

    static let storageKey = "editorThemeColor"

    var id: Self { self }

    var title: String {
        switch self {
        case .blue:
            "Blue"
        case .yellow:
            "Yellow"
        case .pink:
            "Pink"
        case .green:
            "Green"
        case .purple:
            "Purple"
        case .pico8:
            "Pico-8"
        case .black:
            "Black"
        case .brown:
            "Brown"
        }
    }

    /// `#themeChooser #theme_<color>` background-color in kirupa.css.
    var swatchFillColor: NSColor {
        switch self {
        case .blue:
            NSColor(hex: 0xCEEBFF)
        case .yellow:
            NSColor(hex: 0xFFEE22)
        case .pink:
            NSColor(hex: 0xFFD9E6)
        case .green:
            NSColor(hex: 0x81C784)
        case .purple:
            NSColor(hex: 0xB891D4)
        case .pico8:
            NSColor(hex: 0xFFCCAA)
        case .black:
            NSColor(hex: 0xCCCCCC)
        case .brown:
            NSColor(hex: 0x88634E)
        }
    }

    /// `#themeChooser #theme_<color>` border-color in kirupa.css.
    var swatchBorderColor: NSColor {
        switch self {
        case .blue:
            NSColor(hex: 0x0066AF)
        case .yellow:
            NSColor(hex: 0x867E0F)
        case .pink:
            NSColor(hex: 0xFF0767)
        case .green:
            NSColor(hex: 0x2E7D32)
        case .purple:
            NSColor(hex: 0x6B16A6)
        case .pico8:
            NSColor(hex: 0x333333)
        case .black:
            NSColor(hex: 0x666666)
        case .brown:
            NSColor(hex: 0x67320F)
        }
    }
}

/// The subset of kirupa.com custom properties this editor maps onto native
/// AppKit surfaces.
struct KirupaPalette {
    /// `--primary`
    let primary: NSColor
    /// `--primaryLightest`
    let primaryLightest: NSColor
    /// `--backgroundStart`
    let backgroundStart: NSColor
    /// `--lighter`
    let lighter: NSColor
    /// `--headerBackground`
    let headerBackground: NSColor
    /// `--pageBackground`
    let pageBackground: NSColor
    /// `--bodyText`
    let bodyText: NSColor
    /// `--darkTextSecondary`
    let secondaryText: NSColor
}

/// A complete editor theme: one kirupa.com color plus a light or dark
/// background, mirroring how the site composes `theme_<color>` and
/// `theme_<color>_dark`.
struct EditorColorTheme: Equatable, Hashable {
    var color: EditorThemeColor
    var mode: EditorAppearanceMode

    init(color: EditorThemeColor, mode: EditorAppearanceMode) {
        self.color = color
        self.mode = mode
    }

    static var systemDefault: Self {
        Self(color: .blue, mode: .systemDefault)
    }

    var title: String {
        "\(color.title) \(mode.title)"
    }

    var palette: KirupaPalette {
        switch mode {
        case .light:
            Self.lightPalette(for: color)
        case .dark:
            Self.darkPalette(for: color)
        }
    }

    var colorScheme: ColorScheme {
        mode == .dark ? .dark : .light
    }

    var appKitAppearance: NSAppearance? {
        NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
    }

    var editorBackgroundColor: NSColor {
        palette.pageBackground
    }

    var canvasBackgroundColor: NSColor {
        palette.backgroundStart
    }

    var sidebarBackgroundColor: NSColor {
        switch mode {
        case .light:
            // Soften the saturated header tints so sidebar labels stay legible.
            palette.headerBackground.blended(
                with: NSColor(hex: 0xFFFFFF),
                fraction: 0.55
            )
        case .dark:
            palette.headerBackground
        }
    }

    var primaryTextColor: NSColor {
        palette.bodyText
    }

    var secondaryTextColor: NSColor {
        switch mode {
        case .light:
            palette.bodyText.blended(
                with: sidebarBackgroundColor,
                fraction: 0.2
            )
        case .dark:
            palette.secondaryText
        }
    }

    var separatorColor: NSColor {
        mode == .dark
            ? NSColor.white.withAlphaComponent(0.25)
            : NSColor.black.withAlphaComponent(0.17)
    }

    var accentColor: NSColor {
        palette.primary
    }

    var selectionBackgroundColor: NSColor {
        palette.primary
    }

    var selectionTextColor: NSColor {
        let black = NSColor(hex: 0x000000)
        let white = NSColor(hex: 0xFFFFFF)
        return selectionBackgroundColor.contrastRatio(with: black)
            >= selectionBackgroundColor.contrastRatio(with: white)
            ? black
            : white
    }

    var inlineCodeBackgroundColor: NSColor {
        mode == .dark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.07)
    }

    var codeBlockBackgroundColor: NSColor {
        switch mode {
        case .light:
            palette.primaryLightest
        case .dark:
            palette.lighter.blended(with: .black, fraction: 0.15)
        }
    }

    var canvasBackground: Color {
        Color(nsColor: canvasBackgroundColor)
    }

    var sidebarBackground: Color {
        Color(nsColor: sidebarBackgroundColor)
    }

    @MainActor
    func apply(to textView: NSTextView, in scrollView: NSScrollView) {
        textView.appearance = appKitAppearance
        scrollView.appearance = appKitAppearance
        textView.drawsBackground = true
        textView.backgroundColor = editorBackgroundColor
        textView.textColor = primaryTextColor
        textView.insertionPointColor = primaryTextColor
        textView.selectedTextAttributes = [
            .backgroundColor: selectionBackgroundColor,
            .foregroundColor: selectionTextColor
        ]
        scrollView.drawsBackground = true
        scrollView.backgroundColor = editorBackgroundColor
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = editorBackgroundColor
    }

    @MainActor
    func apply(
        to outlineView: NSOutlineView,
        in scrollView: NSScrollView
    ) {
        outlineView.appearance = appKitAppearance
        scrollView.appearance = appKitAppearance
        outlineView.backgroundColor = sidebarBackgroundColor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = sidebarBackgroundColor
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = sidebarBackgroundColor
    }
}

extension EditorColorTheme {
    /// Values transcribed from `:root` and each `html.theme_<color>` block on
    /// https://www.kirupa.com/.
    static func lightPalette(for color: EditorThemeColor) -> KirupaPalette {
        let secondaryText = NSColor(hex: 0x5B5B5B)
        let bodyText = NSColor(hex: 0x373D42)
        let pageBackground = NSColor(hex: 0xFFFFFF)

        switch color {
        case .blue:
            return KirupaPalette(
                primary: NSColor(hex: 0x0798FF),
                primaryLightest: NSColor(hex: 0xEAF7FF),
                backgroundStart: NSColor(hex: 0xF5FCFF),
                lighter: NSColor(hex: 0xFAFAFA),
                headerBackground: NSColor(hex: 0xEAF7FF),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        case .yellow:
            return KirupaPalette(
                primary: NSColor(hex: 0x686305),
                primaryLightest: NSColor(hex: 0xFFF5C5),
                backgroundStart: NSColor(hex: 0xFFFCDF),
                lighter: NSColor(hex: 0xFAFAFA),
                headerBackground: NSColor(hex: 0xFFF38B),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        case .pink:
            return KirupaPalette(
                primary: NSColor(hex: 0xFF0767),
                primaryLightest: NSColor(hex: 0xFFDAE8),
                backgroundStart: NSColor(hex: 0xFFAECD),
                lighter: NSColor(hex: 0xFFFCFE),
                headerBackground: NSColor(hex: 0xFFEAF2),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        case .green:
            return KirupaPalette(
                primary: NSColor(hex: 0x428989),
                primaryLightest: NSColor(hex: 0xA4F8A8),
                backgroundStart: NSColor(hex: 0xF1FFF1),
                lighter: NSColor(hex: 0xFAFAFA),
                headerBackground: NSColor(hex: 0xDEFFE0),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        case .purple:
            return KirupaPalette(
                primary: NSColor(hex: 0x6B16A6),
                primaryLightest: NSColor(hex: 0xEDD4FF),
                backgroundStart: NSColor(hex: 0xF0DBFF),
                lighter: NSColor(hex: 0xFAFAFA),
                headerBackground: NSColor(hex: 0xBB94D7),
                pageBackground: pageBackground,
                bodyText: NSColor(hex: 0x280540),
                secondaryText: secondaryText
            )
        case .pico8:
            return KirupaPalette(
                primary: NSColor(hex: 0x7E2553),
                primaryLightest: NSColor(hex: 0xFFE4D3),
                backgroundStart: NSColor(hex: 0xF9E9D9),
                lighter: NSColor(hex: 0xFAFAFA),
                headerBackground: NSColor(hex: 0xFFCCAA),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        case .black:
            return KirupaPalette(
                primary: NSColor(hex: 0x000000),
                primaryLightest: NSColor(hex: 0xC1C1C1),
                backgroundStart: NSColor(hex: 0xECECEC),
                lighter: NSColor(hex: 0xFAFAFA),
                headerBackground: NSColor(hex: 0xD6D6D6),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        case .brown:
            return KirupaPalette(
                primary: NSColor(hex: 0x99242C),
                primaryLightest: NSColor(hex: 0xD8ABAE),
                backgroundStart: NSColor(hex: 0xFFD4D7),
                lighter: NSColor(hex: 0xFAFAFA),
                headerBackground: NSColor(hex: 0xE48289),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        }
    }

    /// Values transcribed from `html.theme_dark` on https://www.kirupa.com/,
    /// overlaid with each `html.theme_<color>_dark` block.
    static func darkPalette(for color: EditorThemeColor) -> KirupaPalette {
        let bodyText = NSColor(hex: 0xF5F9FE)

        switch color {
        case .blue:
            return KirupaPalette(
                primary: NSColor(hex: 0x518AC1),
                primaryLightest: NSColor(hex: 0x3E4F5F),
                backgroundStart: NSColor(hex: 0x000000),
                lighter: NSColor(hex: 0x24282D),
                headerBackground: NSColor(hex: 0x24282D),
                pageBackground: NSColor(hex: 0x383A42),
                bodyText: bodyText,
                secondaryText: NSColor(hex: 0xCACACA)
            )
        case .yellow:
            return KirupaPalette(
                primary: NSColor(hex: 0x776600),
                primaryLightest: NSColor(hex: 0xBFA500),
                backgroundStart: NSColor(hex: 0x776703),
                lighter: NSColor(hex: 0x27230B),
                headerBackground: NSColor(hex: 0x292720),
                pageBackground: NSColor(hex: 0x3A382F),
                bodyText: bodyText,
                secondaryText: NSColor(hex: 0xCACACA)
            )
        case .pink:
            return KirupaPalette(
                primary: NSColor(hex: 0xCA4FB2),
                primaryLightest: NSColor(hex: 0xBF8ABF),
                backgroundStart: NSColor(hex: 0x7B397B),
                lighter: NSColor(hex: 0x270227),
                headerBackground: NSColor(hex: 0x1B001B),
                pageBackground: NSColor(hex: 0x290229),
                bodyText: bodyText,
                secondaryText: NSColor(hex: 0xCACACA)
            )
        case .green:
            return KirupaPalette(
                primary: NSColor(hex: 0x2DAA72),
                primaryLightest: NSColor(hex: 0x123027),
                backgroundStart: NSColor(hex: 0x000000),
                lighter: NSColor(hex: 0x061911),
                headerBackground: NSColor(hex: 0x0B2C1D),
                pageBackground: NSColor(hex: 0x062014),
                bodyText: bodyText,
                secondaryText: NSColor(hex: 0xADCABA)
            )
        case .purple:
            return KirupaPalette(
                primary: NSColor(hex: 0x972FC6),
                primaryLightest: NSColor(hex: 0x551E70),
                backgroundStart: NSColor(hex: 0x4D1866),
                lighter: NSColor(hex: 0x0C050F),
                headerBackground: NSColor(hex: 0x15081C),
                pageBackground: NSColor(hex: 0x230D2E),
                bodyText: bodyText,
                secondaryText: NSColor(hex: 0xBDADCA)
            )
        case .pico8:
            return KirupaPalette(
                primary: NSColor(hex: 0x29ADFF),
                primaryLightest: NSColor(hex: 0x551E70),
                backgroundStart: NSColor(hex: 0x4F475D),
                lighter: NSColor(hex: 0x362531),
                headerBackground: NSColor(hex: 0x332E3C),
                pageBackground: NSColor(hex: 0x1B1820),
                bodyText: bodyText,
                secondaryText: NSColor(hex: 0xBDADCA)
            )
        case .black:
            return KirupaPalette(
                primary: NSColor(hex: 0x009AFF),
                primaryLightest: NSColor(hex: 0x000000),
                backgroundStart: NSColor(hex: 0x212121),
                lighter: NSColor(hex: 0x2F2F2F),
                headerBackground: NSColor(hex: 0x191919),
                pageBackground: NSColor(hex: 0x232323),
                bodyText: bodyText,
                secondaryText: NSColor(hex: 0xBDBDBD)
            )
        case .brown:
            return KirupaPalette(
                primary: NSColor(hex: 0xA56554),
                primaryLightest: NSColor(hex: 0x4A2F28),
                backgroundStart: NSColor(hex: 0x4F475D),
                lighter: NSColor(hex: 0x201410),
                headerBackground: NSColor(hex: 0x432B24),
                pageBackground: NSColor(hex: 0x2C1C17),
                bodyText: bodyText,
                secondaryText: NSColor(hex: 0xCAADAD)
            )
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// WCAG relative luminance, used to pick readable text over a fill.
    var relativeLuminance: CGFloat {
        guard let srgb = usingColorSpace(.sRGB) else { return 0 }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    func blended(with other: NSColor, fraction: CGFloat) -> NSColor {
        blended(withFraction: fraction, of: other) ?? self
    }

    func contrastRatio(with other: NSColor) -> CGFloat {
        let first = relativeLuminance
        let second = other.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
