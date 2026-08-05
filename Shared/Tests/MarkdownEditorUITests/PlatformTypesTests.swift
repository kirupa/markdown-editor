import Foundation
import Testing
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif
@testable import MarkdownEditorUI

/// The platform shim is the one piece of shared code with two implementations,
/// so it is the one piece that can disagree with itself. These pin down the
/// behavior both sides have to produce.
@Suite("Platform types")
struct PlatformTypesTests {
    @Test("A hex literal becomes the same sRGB values it names")
    func hexInitializerIsSRGB() {
        let color = PlatformColor(hex: 0x3366CC)
        let components = color.sRGBComponents

        #expect(components != nil)
        #expect(Int(((components?.red ?? 0) * 255).rounded()) == 0x33)
        #expect(Int(((components?.green ?? 0) * 255).rounded()) == 0x66)
        #expect(Int(((components?.blue ?? 0) * 255).rounded()) == 0xCC)
        #expect(components?.alpha == 1)
    }

    @Test("Blending reproduces AppKit's Generic RGB interpolation")
    func blendingUsesGenericRGB() {
        let black = PlatformColor(hex: 0x000000)
        let white = PlatformColor(hex: 0xFFFFFF)

        for blend in [
            black.mixed(withFraction:of:),
            black.genericRGBMixed(withFraction:of:),
        ] {
            #expect(abs(blend(0, white)?.sRGBComponents?.red ?? 1) < 0.0001)
            #expect(abs((blend(1, white)?.sRGBComponents?.red ?? 0) - 1) < 0.0001)
            #expect(abs((blend(0.5, white)?.sRGBComponents?.red ?? 0) - 0.57231) < 0.0005)
        }

        // The number that matters: AppKit mixes in gamma 1.8, so halfway
        // between black and white is 0.572 in sRGB, not 0.5. Interpolating
        // sRGB directly would land on 0.5 and quietly restyle every theme.
    }

    @Test("Contrast picks the readable text color over a fill")
    func contrastRatioOrdersCorrectly() {
        let white = PlatformColor(hex: 0xFFFFFF)
        let black = PlatformColor(hex: 0x000000)

        // WCAG's maximum ratio, and the same both ways round.
        #expect(abs(white.contrastRatio(with: black) - 21) < 0.01)
        #expect(
            abs(
                white.contrastRatio(with: black)
                    - black.contrastRatio(with: white)
            ) < 0.0001
        )
    }

    @Test("Bold and italic actually change the font")
    func fontTraitsApply() {
        let base = PlatformFont.systemFont(ofSize: 15)

        #expect(base.markdownFont(withTrait: .bold) != base)
        #expect(base.markdownFont(withTrait: .italic) != base)
        #expect(base.markdownFont(withTrait: .bold).pointSize == 15)
        #expect(base.markdownFont(withTrait: .italic).pointSize == 15)
    }

    @Test("Every theme resolves a full set of colors")
    func everyThemeResolves() {
        for color in EditorThemeColor.allCases {
            for mode in EditorAppearanceMode.allCases {
                let theme = EditorColorTheme(color: color, mode: mode)
                #expect(theme.editorBackgroundColor.sRGBComponents != nil)
                #expect(theme.primaryTextColor.sRGBComponents != nil)
                #expect(theme.secondaryTextColor.sRGBComponents != nil)
                #expect(theme.sidebarBackgroundColor.sRGBComponents != nil)
                #expect(theme.selectionTextColor.sRGBComponents != nil)
                #expect(theme.codeBlockBackgroundColor.sRGBComponents != nil)
            }
        }
    }

    @Test("Body text stays readable on its own background")
    func bodyTextIsReadable() {
        for color in EditorThemeColor.allCases {
            for mode in EditorAppearanceMode.allCases {
                let theme = EditorColorTheme(color: color, mode: mode)
                let ratio = theme.primaryTextColor.contrastRatio(
                    with: theme.editorBackgroundColor
                )
                #expect(
                    ratio >= 4.5,
                    "\(theme.title) body text contrast is \(ratio)"
                )
            }
        }
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    /// The real check, and the reason the gamma transform is written out by
    /// hand. Every blend the palettes could perform, run through both the
    /// portable implementation and `NSColor.blended(withFraction:of:)`.
    ///
    /// They are held to within three steps of 0-255 across the whole range,
    /// and to one step on the mid-tones the themes actually blend. macOS still
    /// calls AppKit, so `themes.css` cannot move; this bounds how far the iOS
    /// build is allowed to sit from it.
    @Test("Portable blending matches NSColor across the palettes")
    func blendingAgreesWithNSColor() {
        var samples: [PlatformColor] = [
            PlatformColor(hex: 0x000000), PlatformColor(hex: 0xFFFFFF),
        ]
        for color in EditorThemeColor.allCases {
            for mode in EditorAppearanceMode.allCases {
                let theme = EditorColorTheme(color: color, mode: mode)
                samples.append(theme.accentColor)
                samples.append(theme.editorBackgroundColor)
                samples.append(theme.primaryTextColor)
                samples.append(theme.canvasBackgroundColor)
            }
        }
        let fractions: [CGFloat] = [
            0, 0.08, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.55, 0.6, 0.75,
            0.85, 1,
        ]

        var compared = 0
        var skipped = 0
        var worst = 0
        var worstNote = ""
        for start in samples {
            for end in samples {
                // sRGB is wider than Generic RGB in the magentas, and AppKit
                // handles the colors that fall outside it inconsistently: it
                // returns the receiver untouched at a fraction of 0, clips it
                // at 1, and clips a blend of a color with itself back to a
                // different color. Those cases are pinned separately below.
                guard
                    Self.isInGenericRGBGamut(start),
                    Self.isInGenericRGBGamut(end)
                else {
                    skipped += 1
                    continue
                }
                for fraction in fractions {
                    guard
                        let mine = start
                            .genericRGBMixed(withFraction: fraction, of: end)?
                            .sRGBComponents,
                        let appKit = start
                            .blended(withFraction: fraction, of: end)?
                            .sRGBComponents
                    else {
                        Issue.record("blend produced no components")
                        continue
                    }
                    compared += 1
                    let distance = Self.byteDistance(mine, appKit)
                    if distance > worst {
                        worst = distance
                        worstNote = """
                        \(Self.describe(start.sRGBComponents)) -> \
                        \(Self.describe(end.sRGBComponents)) at \(fraction): \
                        got \(Self.describe(mine)) want \(Self.describe(appKit))
                        """
                    }
                }
            }
        }
        #expect(compared > 10_000)
        #expect(skipped < samples.count * samples.count * 2 / 5)
        // Interpolating sRGB directly — the obvious implementation, and the
        // one this replaced — scores 46 here. The residual is colors near the
        // edge of Generic RGB, on blends the app does not perform; the ones it
        // does perform are held to 1/255 by the test below.
        #expect(worst <= 5, "worst was \(worst)/255: \(worstNote)")
    }

    /// Is `color` inside Generic RGB, asked of the implementation itself: an
    /// in-gamut color survives the round trip, an out-of-gamut one is clipped
    /// to a different color.
    private static func isInGenericRGBGamut(_ color: PlatformColor) -> Bool {
        guard
            let original = color.sRGBComponents,
            let roundTripped = color
                .genericRGBMixed(withFraction: 0.5, of: color)?
                .sRGBComponents
        else {
            return false
        }
        return byteDistance(original, roundTripped) == 0
    }

    /// The palettes do contain colors sRGB can express and Generic RGB cannot,
    /// so this records what happens to them rather than leaving it unstated.
    /// Nothing in the app blends these; the test above skips them.
    @Test("Out-of-gamut colors are clipped, as AppKit clips them")
    func outOfGamutColorsAreClipped() {
        let magenta = PlatformColor(hex: 0xFF0767)
        #expect(!Self.isInGenericRGBGamut(magenta))

        // AppKit returns the receiver untouched at 0 and this matches it.
        #expect(
            Self.byteDistance(
                magenta.genericRGBMixed(withFraction: 0, of: magenta)?
                    .sRGBComponents,
                magenta.sRGBComponents
            ) == 0
        )

        // Everywhere else the color is clipped into Generic RGB, which moves
        // it by a visible amount. AppKit does this too, at a fraction of 1.
        let clipped = magenta.genericRGBMixed(withFraction: 0.5, of: magenta)
        #expect(Self.byteDistance(clipped?.sRGBComponents, magenta.sRGBComponents) > 8)
        #expect(
            Self.byteDistance(
                clipped?.sRGBComponents,
                PlatformColor(hex: 0x000000)
                    .blended(withFraction: 1, of: magenta)?.sRGBComponents
            ) <= 2
        )
    }

    /// The question that actually matters, asked directly: rebuild every
    /// theme through the portable blend and compare each resolved color
    /// against the same theme built through AppKit's.
    ///
    /// This covers only the blends the app really performs, at the precision
    /// `themes.css` is generated with. macOS ships AppKit's, so the stylesheet
    /// cannot move; this bounds how far iOS sits from macOS and the web.
    @Test("No color the app shows moves when blending portably")
    func themeColorsDoNotMove() {
        func resolve() -> [String: Components] {
            var result: [String: Components] = [:]
            for color in EditorThemeColor.allCases {
                for mode in EditorAppearanceMode.allCases {
                    let theme = EditorColorTheme(color: color, mode: mode)
                    let key = "\(color.rawValue)/\(mode.rawValue)"
                    for (name, value) in [
                        ("accent", theme.accentColor),
                        ("canvas", theme.canvasBackgroundColor),
                        ("codeBlock", theme.codeBlockBackgroundColor),
                        ("editor", theme.editorBackgroundColor),
                        ("inlineCode", theme.inlineCodeBackgroundColor),
                        ("primaryText", theme.primaryTextColor),
                        ("secondaryText", theme.secondaryTextColor),
                        ("selection", theme.selectionBackgroundColor),
                        ("selectionText", theme.selectionTextColor),
                        ("separator", theme.separatorColor),
                        ("sidebar", theme.sidebarBackgroundColor),
                    ] {
                        result["\(key)/\(name)"] = value.sRGBComponents
                    }
                }
            }
            return result
        }

        let appKit = resolve()
        PlatformColorBlending.usesPortableBlending = true
        let portable = resolve()
        PlatformColorBlending.usesPortableBlending = false

        #expect(appKit.count == 176)
        #expect(appKit.count == portable.count)
        var worst = 0
        for (key, reference) in appKit {
            guard let candidate = portable[key] else {
                Issue.record("\(key) missing")
                continue
            }
            let distance = Self.byteDistance(candidate, reference)
            worst = max(worst, distance)
            #expect(distance <= 1, "\(key) moved by \(distance)/255")
        }
        #expect(worst <= 1, "worst shown-color difference was \(worst)/255")
    }

    private typealias Components = (
        red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    )?

    /// The largest per-channel gap once both are rounded the way the
    /// stylesheet generator rounds them.
    private static func describe(_ components: Components) -> String {
        guard let components else { return "nil" }
        func byte(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(
            format: "%02X%02X%02X",
            byte(components.red), byte(components.green), byte(components.blue)
        )
    }

    private static func byteDistance(
        _ lhs: Components,
        _ rhs: Components
    ) -> Int {
        guard let lhs, let rhs else { return .max }
        func byte(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return max(
            abs(byte(lhs.red) - byte(rhs.red)),
            max(
                abs(byte(lhs.green) - byte(rhs.green)),
                abs(byte(lhs.blue) - byte(rhs.blue))
            )
        )
    }
    #endif
}
