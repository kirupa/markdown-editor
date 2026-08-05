#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

import CoreGraphics
import Foundation

/// The handful of type names that differ between AppKit and UIKit.
///
/// The two frameworks disagree on the spelling of colors and fonts far more
/// than they disagree on behavior. Naming the differences once means the
/// palette, the type scale, and both attributed-string builders are a single
/// implementation compiled twice, rather than two implementations that have to
/// be kept in agreement by hand.
///
/// This is why the iOS app is a port of nothing. Everything in
/// `MarkdownEditorUI` and below is shared source; everything above it is
/// genuinely platform-specific interface code that *should* differ.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformFontDescriptor = NSFontDescriptor
#else
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformFontDescriptor = UIFontDescriptor
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
/// Lets the tests build a whole theme through the portable blend and compare
/// it against the same theme built through AppKit's.
///
/// The comparison that matters is not "are two arbitrary colors close" but
/// "does any color the app actually shows move", and the only way to ask that
/// is to rebuild the palettes. macOS ships with this off.
enum PlatformColorBlending {
    nonisolated(unsafe) static var usesPortableBlending = false
}
#endif

extension PlatformColor {
    /// sRGB components, or `nil` if the color cannot be converted.
    ///
    /// Blending and the WCAG contrast check both need real numbers, and on
    /// macOS a named or catalog color has none until it is converted.
    var sRGBComponents: (
        red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    )? {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        guard let converted = usingColorSpace(.sRGB) else { return nil }
        return (
            converted.redComponent,
            converted.greenComponent,
            converted.blueComponent,
            converted.alphaComponent
        )
        #else
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return (red, green, blue, alpha)
        #endif
    }

    /// The one blending primitive, and the subtlest thing in this file.
    ///
    /// `NSColor.blended(withFraction:of:)` does **not** interpolate sRGB
    /// components. It converts both colors into Generic RGB — Apple's own
    /// primaries at gamma 1.8 — mixes there, and converts back. Mixing black
    /// and white halfway gives sRGB 0.572, not 0.5.
    ///
    /// That matters well beyond macOS. `Web/public/css/themes.css` is
    /// *generated* by compiling this file, so the colors the web build ships
    /// are AppKit's numbers, and an iOS build that interpolated sRGB directly
    /// would be visibly different on every blended value — the sidebar tint,
    /// secondary text, separators, and the code-block backgrounds. Measured,
    /// that shortcut is wrong by up to 35/255 on saturated colors.
    ///
    /// Generic RGB is not a per-channel regamma of sRGB; the primaries differ
    /// too, so the transform is a matrix. Rather than transcribe one, this
    /// asks Core Graphics for the conversion through `genericRGBLinear`, which
    /// exists on both platforms, and applies the 1.8 curve on either side of
    /// the mix. `PlatformTypesTests` holds the result against real `NSColor`
    /// output across every palette color.
    func mixed(
        withFraction fraction: CGFloat,
        of other: PlatformColor
    ) -> PlatformColor? {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        if PlatformColorBlending.usesPortableBlending {
            return genericRGBMixed(withFraction: fraction, of: other)
        }
        return blended(withFraction: fraction, of: other)
        #else
        return genericRGBMixed(withFraction: fraction, of: other)
        #endif
    }

    /// The portable stand-in for `NSColor.blended(withFraction:of:)`.
    ///
    /// Compiled on macOS as well, purely so the tests can hold it against the
    /// real thing on the platform that has one.
    func genericRGBMixed(
        withFraction fraction: CGFloat,
        of other: PlatformColor
    ) -> PlatformColor? {
        let amount = min(max(fraction, 0), 1)
        // AppKit short-circuits a fraction of 0 and returns the receiver
        // untouched, but does not do the same at 1 — where it hands back a
        // gamut-clipped color instead. Asymmetric, and worth 37/255 on a
        // saturated magenta, so it is reproduced rather than tidied up.
        if amount == 0 { return self }
        guard let start = sRGBComponents, let end = other.sRGBComponents else {
            return nil
        }
        let from = Self.genericRGBComponents(start)
        let to = Self.genericRGBComponents(end)
        let mixed = (0..<3).map { from[$0] + (to[$0] - from[$0]) * amount }
        let result = Self.sRGBComponents(fromGenericRGB: mixed)
        return PlatformColor.sRGB(
            red: result[0],
            green: result[1],
            blue: result[2],
            alpha: start.alpha + (end.alpha - start.alpha) * amount
        )
    }

    /// Gamma of the Generic RGB profile AppKit blends in.
    private static let genericRGBGamma: CGFloat = 1.8

    /// Builds a color from sRGB components on either platform.
    ///
    /// Spelled out rather than using `init(red:green:blue:alpha:)`, whose
    /// color space is an AppKit/UIKit difference that would stay invisible
    /// until the two builds were held side by side.
    static func sRGB(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat
    ) -> PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return PlatformColor(
            srgbRed: red, green: green, blue: blue, alpha: alpha
        )
        #else
        return PlatformColor(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }

    private static func genericRGBGammaEncode(_ linear: CGFloat) -> CGFloat {
        // Signed, not clamped. sRGB is wider than Generic RGB in places, so a
        // saturated color converts to a negative component, and folding those
        // to zero throws away the part of the color that is out of gamut —
        // worth up to 36/255 on the blend.
        copysign(pow(abs(linear), 1 / genericRGBGamma), linear)
    }

    private static func genericRGBGammaDecode(_ encoded: CGFloat) -> CGFloat {
        copysign(pow(abs(encoded), genericRGBGamma), encoded)
    }

    /// sRGB linear to Generic RGB linear, and back.
    ///
    /// Generic RGB is not a regamma of sRGB — it carries Apple's own primaries
    /// (0.625/0.340, 0.280/0.595, 0.155/0.070) against a D65 white — so the
    /// transform is a matrix. These are `inverse(genericToXYZ) * sRGBToXYZ`
    /// and its inverse, built from those primaries the usual way.
    ///
    /// Written out rather than obtained from a `CGColor` conversion, which
    /// clips to the destination gamut. sRGB is wider than Generic RGB in the
    /// magentas this palette contains, and clipping there costs 36/255 and
    /// stops a color blended with itself from coming back as itself.
    private static let sRGBToGenericRGB: [[CGFloat]] = [
        [0.93398742, 0.07680844, -0.01079585],
        [-0.02343562, 1.04018984, -0.01675421],
        [-0.00095285, -0.03207936, 1.03303222],
    ]

    private static let genericRGBToSRGB: [[CGFloat]] = [
        [1.06871585, -0.07860970, 0.00989384],
        [0.02410626, 0.96007093, 0.01582282],
        [0.00173435, 0.02974114, 0.96852450],
    ]

    private static func transform(
        _ components: [CGFloat],
        by matrix: [[CGFloat]]
    ) -> [CGFloat] {
        matrix.map { row in
            row[0] * components[0] + row[1] * components[1]
                + row[2] * components[2]
        }
    }

    /// The sRGB transfer function and its inverse, signed so out-of-gamut
    /// components survive the trip instead of being folded to zero.
    private static func sRGBLinear(_ encoded: CGFloat) -> CGFloat {
        let magnitude = abs(encoded)
        let linear = magnitude <= 0.04045
            ? magnitude / 12.92
            : pow((magnitude + 0.055) / 1.055, 2.4)
        return copysign(linear, encoded)
    }

    private static func sRGBEncoded(_ linear: CGFloat) -> CGFloat {
        let magnitude = abs(linear)
        let encoded = magnitude <= 0.0031308
            ? magnitude * 12.92
            : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return copysign(encoded, linear)
    }

    /// sRGB components expressed in Generic RGB.
    ///
    /// Clamped into gamut, because AppKit's blend is: `NSColor` really does
    /// return a slightly different magenta than the one handed to it when the
    /// fraction is 1. Matching macOS matters more here than being right.
    private static func genericRGBComponents(
        _ components: (
            red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
        )
    ) -> [CGFloat] {
        let linear = [components.red, components.green, components.blue]
            .map(sRGBLinear)
        return transform(linear, by: sRGBToGenericRGB)
            .map(genericRGBGammaEncode)
            .map { min(max($0, 0), 1) }
    }

    /// Generic RGB components expressed in sRGB.
    private static func sRGBComponents(
        fromGenericRGB components: [CGFloat]
    ) -> [CGFloat] {
        transform(components.map(genericRGBGammaDecode), by: genericRGBToSRGB)
            .map(sRGBEncoded)
            .map { min(max($0, 0), 1) }
    }
}

extension PlatformFont {
    /// The system font at `size`, italicized where the platform can do it.
    ///
    /// Both frameworks expose the trait through a font descriptor, but the
    /// option set is named differently, and AppKit can hand back a descriptor
    /// with no installed font behind it. Falling back to the upright face is
    /// correct: a missing italic must not mean missing text.
    public static func markdownItalicSystemFont(
        ofSize size: CGFloat
    ) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size)
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        return PlatformFont(descriptor: descriptor, size: size) ?? base
        #else
        guard
            let descriptor = base.fontDescriptor.withSymbolicTraits(
                base.fontDescriptor.symbolicTraits.union(.traitItalic)
            )
        else {
            return base
        }
        return PlatformFont(descriptor: descriptor, size: size)
        #endif
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
public typealias PlatformImage = NSImage
#else
public typealias PlatformImage = UIImage
#endif

extension PlatformImage {
    /// An image read from a file URL.
    ///
    /// `NSImage(contentsOf:)` takes a URL; `UIImage` only offers
    /// `init(contentsOfFile:)`. Both return `nil` rather than throwing when the
    /// bytes are not a decodable image, which is the behavior the renderer
    /// wants: a broken image reference falls back to the placeholder symbol
    /// instead of failing the whole document.
    public static func markdownImage(contentsOf url: URL) -> PlatformImage? {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return NSImage(contentsOf: url)
        #else
        return UIImage(contentsOfFile: url.path)
        #endif
    }

    /// An SF Symbol, used as the placeholder for an image that will not load.
    public static func markdownSymbol(
        named name: String,
        accessibilityDescription: String
    ) -> PlatformImage? {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return NSImage(
            systemSymbolName: name,
            accessibilityDescription: accessibilityDescription
        )
        #else
        return UIImage(systemName: name)
        #endif
    }

    /// A blank image of `size`, the last resort when even the symbol is
    /// missing, so an attachment always has something to lay out.
    public static func markdownBlank(size: CGSize) -> PlatformImage {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return NSImage(size: size)
        #else
        return UIGraphicsImageRenderer(size: size).image { _ in }
        #endif
    }
}

/// Bold and italic, the only two font traits Markdown can express.
public enum MarkdownFontTrait {
    case bold
    case italic
}

extension PlatformFont {
    /// This font with `trait` added.
    ///
    /// macOS keeps going through `NSFontManager`, which is what it has always
    /// done and what the rendered view was tuned against. UIKit has no font
    /// manager, so iOS adds the matching symbolic trait to the descriptor —
    /// and falls back to the original font when the family has no such face,
    /// because losing the text would be far worse than losing the emphasis.
    public func markdownFont(withTrait trait: MarkdownFontTrait)
        -> PlatformFont
    {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let mask: NSFontTraitMask = trait == .bold ? .boldFontMask
            : .italicFontMask
        return NSFontManager.shared.convert(self, toHaveTrait: mask)
        #else
        let symbolic: UIFontDescriptor.SymbolicTraits = trait == .bold
            ? .traitBold
            : .traitItalic
        guard
            let descriptor = fontDescriptor.withSymbolicTraits(
                fontDescriptor.symbolicTraits.union(symbolic)
            )
        else {
            return self
        }
        return PlatformFont(descriptor: descriptor, size: pointSize)
        #endif
    }
}

extension NSAttributedString.Key {
    /// Marks the runs that make up one fenced code block.
    ///
    /// Defined here rather than next to the view that draws it, because the
    /// shared styler is what applies it and both platforms' text views read
    /// it back to paint a single rounded rectangle behind the whole block.
    public static let markdownCodeBlockBackground = Self(
        "com.kirupa.markdown-editor.code-block-background"
    )
}

extension PlatformColor {
    /// The system's link color. AppKit and UIKit both have one; they disagree
    /// only on the name.
    public static var markdownLinkColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return .linkColor
        #else
        return .link
        #endif
    }

    /// The system accent color, used for list markers.
    ///
    /// macOS follows the user's General accent setting. iOS has no such
    /// setting, so it takes the system blue that `tintColor` defaults to.
    public static var markdownAccentColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return .controlAccentColor
        #else
        return .systemBlue
        #endif
    }
}
