#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

import CoreGraphics
import Foundation

/// The faces the app offers anything to be written in.
///
/// One list for two choices: the hand the critique's notes are written in, and
/// the face the document itself is set in (Customize Theme ▸ Font). They are
/// the same list on purpose — a face somebody liked for the notes is one they
/// can have for the page, and two catalogs would drift the first time either
/// one gained a face.
///
/// The raw values are stored in preferences, so they must never change.
public enum EditorTypeface: String, CaseIterable, Identifiable, Sendable {
    /// The system face. Not a hand at all, and the default for both choices.
    ///
    /// The handwriting says "somebody wrote on your draft", which is the right
    /// tone and the wrong trade at length: a page full of marker is slower to
    /// read than one in the system face. The faces are here for anyone who
    /// wants them.
    case sans

    // Bundled with the Mac app under the SIL Open Font License. Shipped rather
    // than assumed because macOS carries none of them, and a picker offering a
    // face that is not there is worse than not offering it.
    case architectsDaughter
    case caveat
    case indieFlower
    case patrickHand
    case shadowsIntoLight
    case gloriaHallelujah
    case kalam
    case permanentMarker

    // Already on the machine. Free to offer, and genuinely good — but macOS
    // makes some faces optional downloads and any face can be switched off in
    // Font Book, so these are filtered by what actually resolves. See
    // `available`.
    case bradleyHand
    case markerFelt
    case noteworthy
    case chalkboard

    public var id: Self { self }

    public var title: String {
        switch self {
        case .sans: return "System Sans"
        case .architectsDaughter: return "Architects Daughter"
        case .caveat: return "Caveat"
        case .indieFlower: return "Indie Flower"
        case .patrickHand: return "Patrick Hand"
        case .shadowsIntoLight: return "Shadows Into Light"
        case .gloriaHallelujah: return "Gloria Hallelujah"
        case .kalam: return "Kalam"
        case .permanentMarker: return "Permanent Marker"
        case .bradleyHand: return "Bradley Hand"
        case .markerFelt: return "Marker Felt"
        case .noteworthy: return "Noteworthy"
        case .chalkboard: return "Chalkboard"
        }
    }

    /// Empty for the system face, which is asked for by weight rather than by
    /// name — there is no one PostScript name for it across OS versions.
    public var fontName: String {
        switch self {
        case .sans: return ""
        case .architectsDaughter: return "ArchitectsDaughter-Regular"
        case .caveat: return "Caveat-Regular"
        case .indieFlower: return "IndieFlower-Regular"
        case .patrickHand: return "PatrickHand-Regular"
        case .shadowsIntoLight: return "ShadowsIntoLight"
        case .gloriaHallelujah: return "GloriaHallelujah"
        case .kalam: return "Kalam-Regular"
        case .permanentMarker: return "PermanentMarker-Regular"
        case .bradleyHand: return "BradleyHandITCTT-Bold"
        case .markerFelt: return "MarkerFelt-Thin"
        case .noteworthy: return "Noteworthy-Light"
        case .chalkboard: return "ChalkboardSE-Light"
        }
    }

    /// What to multiply a requested point size by so every face lands at the
    /// same *read* size.
    ///
    /// Measured, not guessed, and measured from **x-height** — the ratio of the
    /// system face's x-height to this one's. Almost every word anybody reads is
    /// lowercase, and these faces disagree about capitals far more than about
    /// lowercase: Gloria Hallelujah's cap height is 0.88 against Bradley Hand's
    /// 0.54, while their x-heights are 0.57 and 0.49. Matching capitals would
    /// set the text people actually read as much as a third too small.
    public var opticalScale: CGFloat {
        switch self {
        case .sans: return 1.0
        case .architectsDaughter: return 1.19
        case .caveat: return 1.28
        case .indieFlower: return 1.12
        case .patrickHand: return 1.09
        case .shadowsIntoLight: return 0.84
        case .gloriaHallelujah: return 0.90
        case .kalam: return 0.97
        case .permanentMarker: return 0.84
        case .bradleyHand: return 1.03
        case .markerFelt: return 0.88
        case .noteworthy: return 0.94
        case .chalkboard: return 1.01
        }
    }

    /// Whether this face can actually be drawn on this machine.
    ///
    /// The bundled ones can wherever the app ships them. The system ones
    /// usually can and sometimes cannot: macOS makes several faces optional
    /// downloads, and any face at all can be switched off in Font Book. A
    /// picker is where that matters most, because choosing an entry that
    /// silently draws something else looks like the app ignoring you.
    public var isAvailable: Bool {
        guard self != .sans else { return true }
        return PlatformFont(name: fontName, size: 12) != nil
    }

    /// The faces to offer, in the order they should be offered.
    public static var available: [EditorTypeface] {
        allCases.filter(\.isAvailable)
    }

    /// Whether this face is one the app ships, as opposed to one it found.
    ///
    /// Only used to group a picker: a list of thirteen faces is a wall, and
    /// "these came with the app / these came with your Mac" is the one division
    /// a reader can act on.
    public var isBundled: Bool {
        switch self {
        case .sans, .bradleyHand, .markerFelt, .noteworthy, .chalkboard:
            return false
        default:
            return true
        }
    }

    /// This face at a size that reads as `size` does in the system face.
    ///
    /// `weight` is only honoured by the system face. Every hand here ships in
    /// one weight, so a heading set in one is carried by its size — which is
    /// how the critique's notes have always carried theirs. A face that cannot
    /// be found falls back to the system face rather than to nothing, because
    /// words nobody can read are worse than words in the wrong face.
    public func font(
        ofSize size: CGFloat,
        weight: PlatformFont.Weight? = nil
    ) -> PlatformFont {
        if self != .sans,
            let found = PlatformFont(name: fontName, size: size * opticalScale)
        {
            return found
        }
        // Exactly the calls the styler made before there was a choice, so the
        // default document is drawn identically to how it always was.
        guard let weight else {
            return PlatformFont.systemFont(ofSize: size)
        }
        return PlatformFont.systemFont(ofSize: size, weight: weight)
    }
}
