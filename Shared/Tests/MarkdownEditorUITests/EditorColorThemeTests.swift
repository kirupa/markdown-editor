#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

import CoreGraphics
import Foundation
import Testing
@testable import MarkdownEditorUI

/// The sixteen palettes, checked for the one thing that actually matters
/// about a colour scheme: that the text can be read on it.
///
/// These are transcribed from kirupa.com's stylesheet and then blended
/// programmatically to derive sidebar tints, secondary text, separators and
/// code backgrounds. A blend that goes wrong does not fail anything — it
/// produces grey text on a grey background in one combination out of sixteen,
/// which is exactly the sort of thing nobody notices until someone is trying
/// to work in it.
///
/// The thresholds are WCAG's, not this project's, so they stay meaningful
/// independently of what the current colours happen to score.
@Suite("Editor color themes")
struct EditorColorThemeTests {
    private static var allThemes: [EditorColorTheme] {
        EditorThemeColor.allCases.flatMap { color in
            EditorAppearanceMode.allCases.map { mode in
                EditorColorTheme(color: color, mode: mode)
            }
        }
    }

    @Test("There are sixteen distinct themes")
    func themeCountIsSixteen() {
        #expect(Self.allThemes.count == 16)
        #expect(Set(Self.allThemes).count == 16)
    }

    // MARK: - Readability

    /// Body text against the page it is written on, at WCAG AAA.
    @Test("Body text is comfortably readable on every theme")
    func bodyTextIsReadable() {
        for theme in Self.allThemes {
            let ratio = theme.primaryTextColor.contrastRatio(
                with: theme.editorBackgroundColor
            )
            #expect(
                ratio >= 7,
                "\(theme.title): body text scores \(ratio):1"
            )
        }
    }

    /// Secondary text is smaller and greyer by design, so it is held to
    /// WCAG AA rather than AAA.
    @Test("Secondary text is readable on every theme")
    func secondaryTextIsReadable() {
        for theme in Self.allThemes {
            let ratio = theme.secondaryTextColor.contrastRatio(
                with: theme.editorBackgroundColor
            )
            #expect(
                ratio >= 4.5,
                "\(theme.title): secondary text scores \(ratio):1"
            )
        }
    }

    /// A selected row or pressed control is the case that goes wrong most
    /// easily, because the fill is the theme's saturated accent rather than a
    /// near-white or near-black. Its label is picked by contrast for that
    /// reason, and this is the check that it worked.
    @Test("Row and control labels are readable on the selection fill")
    func selectionTextIsReadable() {
        for theme in Self.allThemes {
            let ratio = theme.selectionTextColor.contrastRatio(
                with: theme.selectionBackgroundColor
            )
            #expect(
                ratio >= 4.5,
                "\(theme.title): selected label scores \(ratio):1"
            )
        }
    }

    /// Selected text keeps its own colour, so the tint behind it has to be
    /// light enough to read through. It used to be the full accent, and in
    /// Blue Dark that was a slab of dark blue with the words forced to black.
    ///
    /// The tint is translucent, so it is measured where it lands: over the
    /// page, and over a code block, where the page is already a shade darker.
    @Test("Selected text stays readable on the selection tint")
    func textSelectionTintIsReadable() {
        for theme in Self.allThemes {
            let tint = theme.textSelectionBackgroundColor
            let opacity = tint.sRGBComponents?.alpha ?? 1
            #expect(
                opacity > 0 && opacity <= 0.4,
                "\(theme.title): the tint is \(opacity) opaque"
            )
            let page = theme.editorBackgroundColor
            let onPage = tint.composited(over: page)
            let weight = onPage.contrastRatio(with: page)
            #expect(
                weight <= 1.401,
                "\(theme.title): the tint is \(weight):1 against the page"
            )
            let text = theme.primaryTextColor.contrastRatio(with: onPage)
            #expect(
                text >= 7,
                "\(theme.title): selected text scores \(text):1"
            )
            let code = theme.primaryTextColor.contrastRatio(
                with: tint.composited(over: theme.codeBlockBackgroundColor)
            )
            #expect(
                code >= 4.5,
                "\(theme.title): selected code scores \(code):1"
            )
        }
    }

    /// Subtle is not the same as invisible. The tint has to show on the page,
    /// read as something other than inline code, and still show on a code
    /// block.
    ///
    /// Measured as a CIELAB difference, not a WCAG ratio, because the ratio
    /// only sees lightness. In the dark themes the inline-code fill and the
    /// tint come out about equally light, and it is the hue that tells them
    /// apart. A difference of about 2.3 is the smallest anyone can see.
    @Test("The selection tint shows against the page and against code")
    func textSelectionTintIsVisible() {
        for theme in Self.allThemes {
            let tint = theme.textSelectionBackgroundColor
            let page = theme.editorBackgroundColor
            let onPage = tint.composited(over: page)
            let fromPage = Self.colorDifference(onPage, page)
            #expect(
                fromPage >= 10,
                "\(theme.title): the tint is \(fromPage) from the page"
            )
            let inlineCode = theme.inlineCodeBackgroundColor.composited(
                over: page
            )
            let fromInlineCode = Self.colorDifference(onPage, inlineCode)
            #expect(
                fromInlineCode >= 6,
                "\(theme.title): the tint is \(fromInlineCode) from inline code"
            )
            let codeBlock = theme.codeBlockBackgroundColor
            let fromCodeBlock = Self.colorDifference(
                tint.composited(over: codeBlock),
                codeBlock
            )
            #expect(
                fromCodeBlock >= 7,
                "\(theme.title): the tint is \(fromCodeBlock) from a code block"
            )
        }
    }

    /// CIE76: straight-line distance in CIELAB, with a D65 white.
    private static func colorDifference(
        _ lhs: PlatformColor,
        _ rhs: PlatformColor
    ) -> Double {
        func lab(_ color: PlatformColor) -> (Double, Double, Double) {
            guard let srgb = color.sRGBComponents else { return (0, 0, 0) }
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045
                    ? value / 12.92
                    : pow((value + 0.055) / 1.055, 2.4)
            }
            let red = linear(srgb.red)
            let green = linear(srgb.green)
            let blue = linear(srgb.blue)
            let x = (0.4124 * red + 0.3576 * green + 0.1805 * blue) / 0.95047
            let y = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            let z = (0.0193 * red + 0.1192 * green + 0.9505 * blue) / 1.08883
            func f(_ t: Double) -> Double {
                t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116
            }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let (l1, a1, b1) = lab(lhs)
        let (l2, a2, b2) = lab(rhs)
        return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2)
            + (b1 - b2) * (b1 - b2)).squareRoot()
    }

    /// Code has to look like code. If the fill matches the page it is on,
    /// a fenced block is invisible.
    @Test("Code backgrounds are distinguishable from the page")
    func codeBackgroundsAreVisible() {
        for theme in Self.allThemes {
            for fill in [
                theme.inlineCodeBackgroundColor,
                theme.codeBlockBackgroundColor
            ] {
                let ratio = fill.contrastRatio(with: theme.editorBackgroundColor)
                #expect(
                    ratio > 1.02,
                    "\(theme.title): code fill is \(ratio):1 against the page"
                )
            }
            let ratio = theme.primaryTextColor.contrastRatio(
                with: theme.codeBlockBackgroundColor
            )
            #expect(
                ratio >= 4.5,
                "\(theme.title): code text scores \(ratio):1"
            )
        }
    }

    // MARK: - Every colour has to be a real colour

    /// Every palette colour must convert to sRGB.
    ///
    /// A colour that cannot is not merely awkward here: `themes.css` for the
    /// web build is *generated* by compiling this file, so one that returns
    /// nothing produces a stylesheet with a missing value rather than an
    /// error, and the browser falls back to something unrelated.
    @Test("Every theme colour resolves to sRGB")
    func everyColorResolvesToSRGB() {
        for theme in Self.allThemes {
            let colors: [(String, PlatformColor)] = [
                ("editorBackground", theme.editorBackgroundColor),
                ("canvasBackground", theme.canvasBackgroundColor),
                ("sidebarBackground", theme.sidebarBackgroundColor),
                ("primaryText", theme.primaryTextColor),
                ("secondaryText", theme.secondaryTextColor),
                ("separator", theme.separatorColor),
                ("accent", theme.accentColor),
                ("selectionBackground", theme.selectionBackgroundColor),
                ("selectionText", theme.selectionTextColor),
                ("textSelectionBackground", theme.textSelectionBackgroundColor),
                ("inlineCodeBackground", theme.inlineCodeBackgroundColor),
                ("codeBlockBackground", theme.codeBlockBackgroundColor)
            ]
            for (name, color) in colors {
                let components = color.sRGBComponents
                #expect(
                    components != nil,
                    "\(theme.title): \(name) does not convert to sRGB"
                )
                guard let components else { continue }
                for channel in [
                    components.red, components.green, components.blue
                ] {
                    #expect(
                        channel.isFinite && channel >= -0.001
                            && channel <= 1.001,
                        "\(theme.title): \(name) has channel \(channel)"
                    )
                }
                #expect(components.alpha > 0.05, "\(theme.title): \(name) is transparent")
            }
        }
    }

    /// Palette colours are read while the view is being laid out, so an
    /// accessor that produced a fresh blend each time would be both slow and
    /// a source of flicker.
    @Test("Reading a theme twice gives the same colours")
    func themesAreStable() {
        for theme in Self.allThemes {
            let first = theme.primaryTextColor.sRGBComponents
            let second = theme.primaryTextColor.sRGBComponents
            #expect(first?.red == second?.red)
            #expect(first?.green == second?.green)
            #expect(first?.blue == second?.blue)
        }
    }

    // MARK: - Identity and persistence

    /// The chosen theme is stored as a raw string, so the cases have to
    /// survive the round trip or everyone's preference silently resets.
    @Test("Every theme choice round-trips through its stored value")
    func choicesRoundTripThroughStorage() {
        for color in EditorThemeColor.allCases {
            #expect(EditorThemeColor(rawValue: color.rawValue) == color)
            #expect(!color.rawValue.isEmpty)
        }
        for mode in EditorAppearanceMode.allCases {
            #expect(EditorAppearanceMode(rawValue: mode.rawValue) == mode)
            #expect(!mode.rawValue.isEmpty)
        }
        #expect(!EditorThemeColor.storageKey.isEmpty)
        #expect(
            EditorThemeColor.storageKey != EditorAppearanceMode.storageKey,
            "both preferences would be written to the same key"
        )
    }

    @Test("Every theme has a distinct, non-empty title")
    func titlesAreDistinctAndPresent() {
        let titles = Self.allThemes.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count, "two themes share a name")
        #expect(Set(EditorThemeColor.allCases.map(\.title)).count == 8)
    }

    @Test("The colour scheme follows the appearance mode")
    func colorSchemeFollowsMode() {
        for color in EditorThemeColor.allCases {
            #expect(
                EditorColorTheme(color: color, mode: .light).colorScheme
                    == .light
            )
            #expect(
                EditorColorTheme(color: color, mode: .dark).colorScheme == .dark
            )
        }
    }

    /// Light and dark have to actually differ, in every colour.
    @Test("Light and dark are genuinely different")
    func lightAndDarkDiffer() {
        for color in EditorThemeColor.allCases {
            let light = EditorColorTheme(color: color, mode: .light)
            let dark = EditorColorTheme(color: color, mode: .dark)
            let lightBackground = light.editorBackgroundColor.sRGBComponents
            let darkBackground = dark.editorBackgroundColor.sRGBComponents
            guard let lightBackground, let darkBackground else {
                Issue.record("\(color) has an unresolvable background")
                continue
            }
            let lightSum = lightBackground.red + lightBackground.green
                + lightBackground.blue
            let darkSum = darkBackground.red + darkBackground.green
                + darkBackground.blue
            #expect(
                lightSum > darkSum,
                "\(color): the dark page is not darker than the light one"
            )
        }
    }

    /// The swatches in the theme picker have to be visible against whatever
    /// they are drawn on, which is why they carry a border colour at all.
    @Test("Every swatch is distinguishable from its border")
    func swatchesAreDistinguishable() {
        for color in EditorThemeColor.allCases {
            #expect(color.swatchFillColor.sRGBComponents != nil)
            #expect(color.swatchBorderColor.sRGBComponents != nil)
            let ratio = color.swatchFillColor.contrastRatio(
                with: color.swatchBorderColor
            )
            #expect(ratio > 1.02, "\(color): swatch and border match")
        }
    }

    @Test("The default theme is one of the sixteen")
    func defaultThemeIsValid() {
        let fallback = EditorColorTheme.systemDefault
        #expect(EditorThemeColor.allCases.contains(fallback.color))
        #expect(EditorAppearanceMode.allCases.contains(fallback.mode))
    }
}

/// The three editor layouts.
@Suite("Editor view mode")
struct EditorViewModeTests {
    @Test("Every mode round-trips through its stored value")
    func modesRoundTrip() {
        for mode in EditorViewMode.allCases {
            #expect(EditorViewMode(rawValue: mode.rawValue) == mode)
            #expect(!mode.systemImage.isEmpty)
        }
        #expect(EditorViewMode.allCases.count == 3)
        #expect(!EditorViewMode.storageKey.isEmpty)
    }

    @Test("Each mode has its own icon")
    func iconsAreDistinct() {
        let icons = EditorViewMode.allCases.map(\.systemImage)
        #expect(Set(icons).count == icons.count)
    }
}
