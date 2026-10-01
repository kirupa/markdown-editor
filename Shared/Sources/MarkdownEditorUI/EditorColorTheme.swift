import Foundation
import SwiftUI

/// Light or dark background, matching the Background radio group in the
/// kirupa.com "Customize Theme" dialog.
public enum EditorAppearanceMode: String, CaseIterable, Identifiable {
    case light
    case dark

    public static let storageKey = "editorAppearanceMode"

    public static var systemDefault: Self {
        let globalPreferences = UserDefaults.standard.persistentDomain(
            forName: UserDefaults.globalDomain
        )
        return globalPreferences?["AppleInterfaceStyle"] as? String == "Dark"
            ? .dark
            : .light
    }

    public var id: Self { self }

    public var title: String {
        switch self {
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    public var systemImage: String {
        switch self {
        case .light:
            "sun.max"
        case .dark:
            "moon"
        }
    }
}

/// The eight color choices offered by the kirupa.com theme selector.
public enum EditorThemeColor: String, CaseIterable, Identifiable {
    case blue
    case yellow
    case pink
    case green
    case purple
    case pico8
    case black
    case brown

    public static let storageKey = "editorThemeColor"

    public var id: Self { self }

    public var title: String {
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
    public var swatchFillColor: PlatformColor {
        switch self {
        case .blue:
            PlatformColor(hex: 0xCEEBFF)
        case .yellow:
            PlatformColor(hex: 0xFFEE22)
        case .pink:
            PlatformColor(hex: 0xFFD9E6)
        case .green:
            PlatformColor(hex: 0x81C784)
        case .purple:
            PlatformColor(hex: 0xB891D4)
        case .pico8:
            PlatformColor(hex: 0xFFCCAA)
        case .black:
            PlatformColor(hex: 0xCCCCCC)
        case .brown:
            PlatformColor(hex: 0x88634E)
        }
    }

    /// `#themeChooser #theme_<color>` border-color in kirupa.css.
    public var swatchBorderColor: PlatformColor {
        switch self {
        case .blue:
            PlatformColor(hex: 0x0066AF)
        case .yellow:
            PlatformColor(hex: 0x867E0F)
        case .pink:
            PlatformColor(hex: 0xFF0767)
        case .green:
            PlatformColor(hex: 0x2E7D32)
        case .purple:
            PlatformColor(hex: 0x6B16A6)
        case .pico8:
            PlatformColor(hex: 0x333333)
        case .black:
            PlatformColor(hex: 0x666666)
        case .brown:
            PlatformColor(hex: 0x67320F)
        }
    }
}

/// The subset of kirupa.com custom properties this editor maps onto native
/// AppKit surfaces.
public struct KirupaPalette {
    /// `--primary`
    public let primary: PlatformColor
    /// `--primaryLightest`
    public let primaryLightest: PlatformColor
    /// `--backgroundStart`
    public let backgroundStart: PlatformColor
    /// `--lighter`
    public let lighter: PlatformColor
    /// `--headerBackground`
    public let headerBackground: PlatformColor
    /// `--pageBackground`
    public let pageBackground: PlatformColor
    /// `--bodyText`
    public let bodyText: PlatformColor
    /// `--darkTextSecondary`
    public let secondaryText: PlatformColor
}

/// A complete editor theme: one kirupa.com color plus a light or dark
/// background, mirroring how the site composes `theme_<color>` and
/// `theme_<color>_dark`.
public struct EditorColorTheme: Equatable, Hashable {
    public var color: EditorThemeColor
    public var mode: EditorAppearanceMode
    /// The face the document is set in — Customize Theme ▸ Font.
    ///
    /// Part of the theme rather than beside it because it changes how every
    /// character is drawn, exactly as a palette does, and the editors already
    /// re-style the whole document when — and only when — the theme changes.
    public var typeface: EditorTypeface

    /// Where the document's face is remembered. Beside the colour and the
    /// background, not inside the critique's key: the two choices are made
    /// from the same list and are still two choices.
    public static let typefaceStorageKey = "editorTypeface"

    /// How large the document is drawn — Customize Theme ▸ Size — as a
    /// multiple of the type scale.
    ///
    /// There because faces set at the same size are not the same size to the
    /// eye: a hand that reads small can be brought up and one that shouts
    /// brought down. It scales everything the text is set with — the type,
    /// the space between lines and paragraphs, and the indents of lists,
    /// quotes and code — so a page at 150% is the same page drawn larger
    /// rather than larger words crammed into the old spacing. The column the
    /// text is set in, and the pictures in it, stay the size they were.
    ///
    /// Always within `textScaleRange`, in whole percent.
    public var textScale: CGFloat {
        didSet { textScale = Self.clampedTextScale(textScale) }
    }

    /// Where the text size is remembered, beside the face it corrects.
    public static let textScaleStorageKey = "editorTextScale"

    /// Three quarters of the type scale to half as large again.
    public static let textScaleRange: ClosedRange<CGFloat> = 0.75...1.5

    /// `scale` brought into `textScaleRange` and rounded to a whole percent,
    /// so that a slider's 1.0000000000000002 is the 100% it says it is and a
    /// theme that has been round-tripped through storage compares equal to
    /// the one that was stored. Anything that is not a number reads as 100%.
    public static func clampedTextScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else {
            return 1
        }
        let clamped = min(
            max(scale, textScaleRange.lowerBound),
            textScaleRange.upperBound
        )
        return (clamped * 100).rounded() / 100
    }

    public init(
        color: EditorThemeColor,
        mode: EditorAppearanceMode,
        typeface: EditorTypeface = .sans,
        textScale: CGFloat = 1
    ) {
        self.color = color
        self.mode = mode
        self.typeface = typeface
        self.textScale = Self.clampedTextScale(textScale)
    }

    /// `length`, a size or a space in the type scale, at this theme's text
    /// size.
    public func scaled(_ length: CGFloat) -> CGFloat {
        length * textScale
    }

    public static var systemDefault: Self {
        Self(color: .blue, mode: .systemDefault)
    }

    public var title: String {
        "\(color.title) \(mode.title)"
    }

    public var palette: KirupaPalette {
        switch mode {
        case .light:
            Self.lightPalette(for: color)
        case .dark:
            Self.darkPalette(for: color)
        }
    }

    public var colorScheme: ColorScheme {
        mode == .dark ? .dark : .light
    }

    public var editorBackgroundColor: PlatformColor {
        palette.pageBackground
    }

    public var canvasBackgroundColor: PlatformColor {
        palette.backgroundStart
    }

    public var sidebarBackgroundColor: PlatformColor {
        switch mode {
        case .light:
            // Soften the saturated header tints so sidebar labels stay legible.
            palette.headerBackground.blended(
                with: PlatformColor(hex: 0xFFFFFF),
                fraction: 0.55
            )
        case .dark:
            palette.headerBackground
        }
    }

    public var primaryTextColor: PlatformColor {
        palette.bodyText
    }

    public var secondaryTextColor: PlatformColor {
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

    public var separatorColor: PlatformColor {
        mode == .dark
            ? PlatformColor.white.withAlphaComponent(0.25)
            : PlatformColor.black.withAlphaComponent(0.17)
    }

    public var accentColor: PlatformColor {
        palette.primary
    }

    /// The fill for a selected row or a pressed control. Selected *text* uses
    /// `textSelectionBackgroundColor` instead.
    public var selectionBackgroundColor: PlatformColor {
        palette.primary
    }

    public var selectionTextColor: PlatformColor {
        let black = PlatformColor(hex: 0x000000)
        let white = PlatformColor(hex: 0xFFFFFF)
        return selectionBackgroundColor.contrastRatio(with: black)
            >= selectionBackgroundColor.contrastRatio(with: white)
            ? black
            : white
    }

    /// The tint behind selected text.
    ///
    /// Not the row fill above. Under a run of words the full accent was a
    /// slab of dark blue, and the words had to be forced to black or white to
    /// show on it at all. This is the accent laid thinly over the page, and it
    /// carries no text colour: selected words keep their own, so body text,
    /// headings, links and code read the same selected as not.
    ///
    /// Translucent rather than mixed in advance, because a selection lands on
    /// more than the page. A pre-mixed tint is one colour wherever it lands,
    /// and in Blue Dark that colour is all but the web's low-severity critique
    /// shading, so a selection inside a marked passage would disappear. A
    /// tint shades whatever is under it, so the selected part of a marked
    /// passage or a code block always shows.
    ///
    /// Composite it over what it is drawn on before measuring it:
    /// `contrastRatio(with:)` does not look at alpha.
    public var textSelectionBackgroundColor: PlatformColor {
        palette.primary.withAlphaComponent(textSelectionOpacity)
    }

    /// How strongly the accent is laid down under selected text.
    ///
    /// Solved for each theme rather than fixed, because the eight accents are
    /// nothing like the same weight: at one opacity black is a heavy grey and
    /// a sky blue is barely there. Each is as strong as it takes to stand
    /// 1.4:1 from the page, which is what leaves body text at 7.6:1 or better
    /// on it, and weaker wherever that would take code on a code block below
    /// 4.5:1. Never above 40%, past which a dull accent stops being a tint.
    var textSelectionOpacity: CGFloat {
        strongestTint(of: palette.primary, standingOff: 1.4, ceiling: 0.4)
    }

    /// The tint behind selected text while the editor is not the one being
    /// typed into: its window is behind another, or the focus is elsewhere.
    ///
    /// The page's own text colour, laid thinly — the way macOS greys a
    /// selection it is not acting on. The same shape as the active selection,
    /// without the accent, so it is plain which editor the keys will go to
    /// and the selection is still where it was left.
    public var inactiveTextSelectionBackgroundColor: PlatformColor {
        primaryTextColor.withAlphaComponent(inactiveTextSelectionOpacity)
    }

    /// As strong as it takes to stand 1.3:1 from the page, a little under the
    /// active tint, and never above 25%.
    var inactiveTextSelectionOpacity: CGFloat {
        strongestTint(of: primaryTextColor, standingOff: 1.3, ceiling: 0.25)
    }

    /// The strongest opacity, up to `ceiling`, at which `colour` laid over
    /// the page stands no more than `contrast` from it and leaves code on a
    /// code block at 4.5:1.
    private func strongestTint(
        of colour: PlatformColor,
        standingOff contrast: CGFloat,
        ceiling: CGFloat
    ) -> CGFloat {
        let page = editorBackgroundColor
        let codeBlock = codeBlockBackgroundColor
        let text = primaryTextColor
        func fits(_ opacity: CGFloat) -> Bool {
            let tint = colour.withAlphaComponent(opacity)
            return tint.composited(over: page).contrastRatio(with: page)
                    <= contrast
                && text.contrastRatio(with: tint.composited(over: codeBlock))
                    >= 4.5
        }
        if fits(ceiling) { return ceiling }
        // Both measures move one way as the tint strengthens, so the
        // strongest opacity that fits can be found by halving.
        var fitting: CGFloat = 0
        var failing = ceiling
        for _ in 0..<16 {
            let middle = (fitting + failing) / 2
            if fits(middle) {
                fitting = middle
            } else {
                failing = middle
            }
        }
        return fitting
    }

    public var inlineCodeBackgroundColor: PlatformColor {
        mode == .dark
            ? PlatformColor.white.withAlphaComponent(0.12)
            : PlatformColor.black.withAlphaComponent(0.07)
    }

    public var codeBlockBackgroundColor: PlatformColor {
        switch mode {
        case .light:
            palette.primaryLightest
        case .dark:
            palette.lighter.blended(with: .black, fraction: 0.15)
        }
    }

    public var canvasBackground: Color {
        Color(platformColor: canvasBackgroundColor)
    }

    public var sidebarBackground: Color {
        Color(platformColor: sidebarBackgroundColor)
    }
}

extension Color {
    /// SwiftUI spells this `init(nsColor:)` on macOS and `init(uiColor:)` on
    /// iOS. Callers should not have to care which.
    public init(platformColor: PlatformColor) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        self.init(nsColor: platformColor)
        #else
        self.init(uiColor: platformColor)
        #endif
    }
}

extension EditorColorTheme {
    /// Values transcribed from `:root` and each `html.theme_<color>` block on
    /// https://www.kirupa.com/.
    static func lightPalette(for color: EditorThemeColor) -> KirupaPalette {
        let secondaryText = PlatformColor(hex: 0x5B5B5B)
        let bodyText = PlatformColor(hex: 0x373D42)
        let pageBackground = PlatformColor(hex: 0xFFFFFF)

        switch color {
        case .blue:
            return KirupaPalette(
                primary: PlatformColor(hex: 0x0798FF),
                primaryLightest: PlatformColor(hex: 0xEAF7FF),
                backgroundStart: PlatformColor(hex: 0xF5FCFF),
                lighter: PlatformColor(hex: 0xFAFAFA),
                headerBackground: PlatformColor(hex: 0xEAF7FF),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        case .yellow:
            return KirupaPalette(
                primary: PlatformColor(hex: 0x686305),
                primaryLightest: PlatformColor(hex: 0xFFF5C5),
                backgroundStart: PlatformColor(hex: 0xFFFCDF),
                lighter: PlatformColor(hex: 0xFAFAFA),
                headerBackground: PlatformColor(hex: 0xFFF38B),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        case .pink:
            return KirupaPalette(
                primary: PlatformColor(hex: 0xFF0767),
                primaryLightest: PlatformColor(hex: 0xFFDAE8),
                backgroundStart: PlatformColor(hex: 0xFFAECD),
                lighter: PlatformColor(hex: 0xFFFCFE),
                headerBackground: PlatformColor(hex: 0xFFEAF2),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        case .green:
            return KirupaPalette(
                primary: PlatformColor(hex: 0x428989),
                primaryLightest: PlatformColor(hex: 0xA4F8A8),
                backgroundStart: PlatformColor(hex: 0xF1FFF1),
                lighter: PlatformColor(hex: 0xFAFAFA),
                headerBackground: PlatformColor(hex: 0xDEFFE0),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        case .purple:
            return KirupaPalette(
                primary: PlatformColor(hex: 0x6B16A6),
                primaryLightest: PlatformColor(hex: 0xEDD4FF),
                backgroundStart: PlatformColor(hex: 0xF0DBFF),
                lighter: PlatformColor(hex: 0xFAFAFA),
                headerBackground: PlatformColor(hex: 0xBB94D7),
                pageBackground: pageBackground,
                bodyText: PlatformColor(hex: 0x280540),
                secondaryText: secondaryText
            )
        case .pico8:
            return KirupaPalette(
                primary: PlatformColor(hex: 0x7E2553),
                primaryLightest: PlatformColor(hex: 0xFFE4D3),
                backgroundStart: PlatformColor(hex: 0xF9E9D9),
                lighter: PlatformColor(hex: 0xFAFAFA),
                headerBackground: PlatformColor(hex: 0xFFCCAA),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        case .black:
            return KirupaPalette(
                primary: PlatformColor(hex: 0x000000),
                primaryLightest: PlatformColor(hex: 0xC1C1C1),
                backgroundStart: PlatformColor(hex: 0xECECEC),
                lighter: PlatformColor(hex: 0xFAFAFA),
                headerBackground: PlatformColor(hex: 0xD6D6D6),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        case .brown:
            return KirupaPalette(
                primary: PlatformColor(hex: 0x99242C),
                primaryLightest: PlatformColor(hex: 0xD8ABAE),
                backgroundStart: PlatformColor(hex: 0xFFD4D7),
                lighter: PlatformColor(hex: 0xFAFAFA),
                headerBackground: PlatformColor(hex: 0xE48289),
                pageBackground: pageBackground,
                bodyText: bodyText,
                secondaryText: secondaryText
            )
        }
    }

    /// Values transcribed from `html.theme_dark` on https://www.kirupa.com/,
    /// overlaid with each `html.theme_<color>_dark` block.
    static func darkPalette(for color: EditorThemeColor) -> KirupaPalette {
        let bodyText = PlatformColor(hex: 0xF5F9FE)

        switch color {
        case .blue:
            return KirupaPalette(
                primary: PlatformColor(hex: 0x518AC1),
                primaryLightest: PlatformColor(hex: 0x3E4F5F),
                backgroundStart: PlatformColor(hex: 0x000000),
                lighter: PlatformColor(hex: 0x24282D),
                headerBackground: PlatformColor(hex: 0x24282D),
                pageBackground: PlatformColor(hex: 0x383A42),
                bodyText: bodyText,
                secondaryText: PlatformColor(hex: 0xCACACA)
            )
        case .yellow:
            return KirupaPalette(
                primary: PlatformColor(hex: 0x776600),
                primaryLightest: PlatformColor(hex: 0xBFA500),
                backgroundStart: PlatformColor(hex: 0x776703),
                lighter: PlatformColor(hex: 0x27230B),
                headerBackground: PlatformColor(hex: 0x292720),
                pageBackground: PlatformColor(hex: 0x3A382F),
                bodyText: bodyText,
                secondaryText: PlatformColor(hex: 0xCACACA)
            )
        case .pink:
            return KirupaPalette(
                primary: PlatformColor(hex: 0xCA4FB2),
                primaryLightest: PlatformColor(hex: 0xBF8ABF),
                backgroundStart: PlatformColor(hex: 0x7B397B),
                lighter: PlatformColor(hex: 0x270227),
                headerBackground: PlatformColor(hex: 0x1B001B),
                pageBackground: PlatformColor(hex: 0x290229),
                bodyText: bodyText,
                secondaryText: PlatformColor(hex: 0xCACACA)
            )
        case .green:
            return KirupaPalette(
                primary: PlatformColor(hex: 0x2DAA72),
                primaryLightest: PlatformColor(hex: 0x123027),
                backgroundStart: PlatformColor(hex: 0x000000),
                lighter: PlatformColor(hex: 0x061911),
                headerBackground: PlatformColor(hex: 0x0B2C1D),
                pageBackground: PlatformColor(hex: 0x062014),
                bodyText: bodyText,
                secondaryText: PlatformColor(hex: 0xADCABA)
            )
        case .purple:
            return KirupaPalette(
                primary: PlatformColor(hex: 0x972FC6),
                primaryLightest: PlatformColor(hex: 0x551E70),
                backgroundStart: PlatformColor(hex: 0x4D1866),
                lighter: PlatformColor(hex: 0x0C050F),
                headerBackground: PlatformColor(hex: 0x15081C),
                pageBackground: PlatformColor(hex: 0x230D2E),
                bodyText: bodyText,
                secondaryText: PlatformColor(hex: 0xBDADCA)
            )
        case .pico8:
            return KirupaPalette(
                primary: PlatformColor(hex: 0x29ADFF),
                primaryLightest: PlatformColor(hex: 0x551E70),
                backgroundStart: PlatformColor(hex: 0x4F475D),
                lighter: PlatformColor(hex: 0x362531),
                headerBackground: PlatformColor(hex: 0x332E3C),
                pageBackground: PlatformColor(hex: 0x1B1820),
                bodyText: bodyText,
                secondaryText: PlatformColor(hex: 0xBDADCA)
            )
        case .black:
            return KirupaPalette(
                primary: PlatformColor(hex: 0x009AFF),
                primaryLightest: PlatformColor(hex: 0x000000),
                backgroundStart: PlatformColor(hex: 0x212121),
                lighter: PlatformColor(hex: 0x2F2F2F),
                headerBackground: PlatformColor(hex: 0x191919),
                pageBackground: PlatformColor(hex: 0x232323),
                bodyText: bodyText,
                secondaryText: PlatformColor(hex: 0xBDBDBD)
            )
        case .brown:
            return KirupaPalette(
                primary: PlatformColor(hex: 0xA56554),
                primaryLightest: PlatformColor(hex: 0x4A2F28),
                backgroundStart: PlatformColor(hex: 0x4F475D),
                lighter: PlatformColor(hex: 0x201410),
                headerBackground: PlatformColor(hex: 0x432B24),
                pageBackground: PlatformColor(hex: 0x2C1C17),
                bodyText: bodyText,
                secondaryText: PlatformColor(hex: 0xCAADAD)
            )
        }
    }
}

extension PlatformColor {
    public convenience init(hex: UInt32) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        // Explicitly sRGB. AppKit's plain `init(red:...)` historically meant
        // calibrated RGB, and UIKit's means device RGB; naming the space keeps
        // the palettes identical on both platforms and in the generated CSS.
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
        #else
        self.init(red: red, green: green, blue: blue, alpha: 1)
        #endif
    }

    /// WCAG relative luminance, used to pick readable text over a fill.
    public var relativeLuminance: CGFloat {
        guard let srgb = sRGBComponents else { return 0 }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.red)
            + 0.7152 * linear(srgb.green)
            + 0.0722 * linear(srgb.blue)
    }

    public func blended(with other: PlatformColor, fraction: CGFloat) -> PlatformColor {
        mixed(withFraction: fraction, of: other) ?? self
    }

    /// This colour painted over an opaque `background`: source-over in sRGB,
    /// which is what a browser does with an `rgba()` fill.
    public func composited(over background: PlatformColor) -> PlatformColor {
        guard let top = sRGBComponents, let bottom = background.sRGBComponents
        else { return self }
        func channel(_ over: CGFloat, _ under: CGFloat) -> CGFloat {
            over * top.alpha + under * (1 - top.alpha)
        }
        return PlatformColor.sRGB(
            red: channel(top.red, bottom.red),
            green: channel(top.green, bottom.green),
            blue: channel(top.blue, bottom.blue),
            alpha: 1
        )
    }

    public func contrastRatio(with other: PlatformColor) -> CGFloat {
        let first = relativeLuminance
        let second = other.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
