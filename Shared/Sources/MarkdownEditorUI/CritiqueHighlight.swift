import CoreGraphics
import Foundation
import MarkdownEditorCore

/// How strongly a critique's passage is shaded, and what put it that way.
///
/// Three states rather than two, because the rail answers the pointer as well
/// as the click. Hovering a note has to say *this note is about that sentence*
/// while the reader is still deciding whether to go there, and it has to say
/// it without being mistaken for having gone: a hover that looks like a
/// selection makes the click that follows feel like it did nothing.
///
/// The ordering is the whole rule and it is stated once here rather than at
/// each platform's call site: **selection outranks hover.** A reader whose
/// pointer is resting on the card they have already opened is looking at one
/// thing, not two, and dropping the passage back to the weaker wash while the
/// pointer sits over its card reads as the selection being lost.
public enum CritiqueHighlightState: String, CaseIterable, Equatable, Sendable {
    /// Marked, because a critique has something to say about it.
    case resting
    /// The pointer is over this finding's note.
    case hovered
    /// This finding's note is open.
    case selected

    /// Which state a finding's passage is in.
    ///
    /// Written as a function of the two identifiers rather than as a pair of
    /// booleans worked out by the caller, so "selection wins" cannot be
    /// spelled differently by two builds — or by two call sites in one build.
    public static func of(
        _ finding: UUID,
        selected: UUID?,
        hovered: UUID?
    ) -> CritiqueHighlightState {
        if finding == selected { return .selected }
        if finding == hovered { return .hovered }
        return .resting
    }
}

extension CritiqueSeverity {
    /// The wash behind the passage in the text.
    ///
    /// Faint, because it sits under the words the author is trying to read.
    /// Google Docs' comment highlight is the reference: enough to notice, not
    /// enough to fight the text.
    public func highlight(on mode: EditorAppearanceMode) -> PlatformColor {
        switch (self, mode) {
        case (.high, .light):
            return .sRGB(red: 0.85, green: 0.24, blue: 0.24, alpha: 0.16)
        case (.medium, .light):
            return .sRGB(red: 0.95, green: 0.66, blue: 0.13, alpha: 0.20)
        case (.low, .light):
            return .sRGB(red: 0.36, green: 0.55, blue: 0.80, alpha: 0.15)
        // Lighter and a shade stronger, because a wash darker than the page it
        // is on is not a highlight. The red measured 1.11:1 against a dark
        // page — a mark you cannot see is the same as no mark, and the comment
        // beside it then points at nothing.
        case (.high, .dark):
            return .sRGB(red: 1.00, green: 0.46, blue: 0.46, alpha: 0.22)
        case (.medium, .dark):
            return .sRGB(red: 1.00, green: 0.76, blue: 0.30, alpha: 0.22)
        case (.low, .dark):
            return .sRGB(red: 0.55, green: 0.76, blue: 1.00, alpha: 0.20)
        }
    }

    /// The wash for the passage whose note the pointer is over.
    ///
    /// The same colour as the resting wash at an alpha exactly halfway to the
    /// selected one. Both halves of that are deliberate. Keeping the hue means
    /// a hover reads as *more of the mark already there* rather than as a
    /// different kind of mark, which is what it is — the note has not changed
    /// its mind about the sentence, the pointer has arrived. And landing
    /// halfway is what keeps the three legible as an order: a hover a shade
    /// off resting cannot be seen on a pale wash, and one a shade off selected
    /// makes the click that follows look like it did nothing.
    public func hoveredHighlight(on mode: EditorAppearanceMode) -> PlatformColor {
        switch (self, mode) {
        case (.high, .light):
            return .sRGB(red: 0.85, green: 0.24, blue: 0.24, alpha: 0.25)
        case (.medium, .light):
            return .sRGB(red: 0.95, green: 0.66, blue: 0.13, alpha: 0.31)
        case (.low, .light):
            return .sRGB(red: 0.36, green: 0.55, blue: 0.80, alpha: 0.24)
        case (.high, .dark):
            return .sRGB(red: 1.00, green: 0.46, blue: 0.46, alpha: 0.31)
        case (.medium, .dark):
            return .sRGB(red: 1.00, green: 0.76, blue: 0.30, alpha: 0.31)
        case (.low, .dark):
            return .sRGB(red: 0.55, green: 0.76, blue: 1.00, alpha: 0.29)
        }
    }

    /// The wash for the passage whose card is open.
    public func selectedHighlight(on mode: EditorAppearanceMode) -> PlatformColor {
        switch (self, mode) {
        case (.high, .light):
            return .sRGB(red: 0.85, green: 0.24, blue: 0.24, alpha: 0.34)
        case (.medium, .light):
            return .sRGB(red: 0.95, green: 0.62, blue: 0.10, alpha: 0.42)
        case (.low, .light):
            return .sRGB(red: 0.36, green: 0.55, blue: 0.80, alpha: 0.32)
        case (.high, .dark):
            return .sRGB(red: 1.00, green: 0.46, blue: 0.46, alpha: 0.40)
        case (.medium, .dark):
            return .sRGB(red: 1.00, green: 0.76, blue: 0.30, alpha: 0.40)
        case (.low, .dark):
            return .sRGB(red: 0.55, green: 0.76, blue: 1.00, alpha: 0.38)
        }
    }

    /// The wash for a passage in a given state, which is the call site every
    /// build should reach for: it cannot pick a colour the state does not
    /// call for.
    public func highlight(
        _ state: CritiqueHighlightState,
        on mode: EditorAppearanceMode
    ) -> PlatformColor {
        switch state {
        case .resting: return highlight(on: mode)
        case .hovered: return hoveredHighlight(on: mode)
        case .selected: return selectedHighlight(on: mode)
        }
    }

    /// A solid rule drawn under the passage whose note is open, and under no
    /// other.
    ///
    /// A wash cannot carry this on its own. The three alphas are an order, and
    /// an order is readable when you can see two of them at once — but the
    /// press that opens a note usually replaces one wash with another in a
    /// place the reader is not looking, and when the passage was already on
    /// screen there is no scroll to tell them anything happened either. A
    /// difference of eighteen hundredths of an alpha, under text, is a
    /// difference somebody reasonably reports as nothing having happened.
    ///
    /// Making the wash stronger instead is the obvious alternative and the
    /// wrong one: this sits under the words the author is trying to read, and
    /// a wash loud enough to be unmissable is a wash that fights them. A rule
    /// is loud without being in the way, because it is not on top of anything.
    ///
    /// It is the severity's own **tint** — the colour the open note is
    /// bordered in — so the note and the passage read as one object rather
    /// than as two things that happen to be the same kind of red.
    public func selectionRule(on mode: EditorAppearanceMode) -> PlatformColor {
        switch (self, mode) {
        case (.high, .light):
            return .sRGB(red: 0.85, green: 0.24, blue: 0.24, alpha: 1)
        case (.medium, .light):
            return .sRGB(red: 0.90, green: 0.60, blue: 0.10, alpha: 1)
        case (.low, .light):
            return .sRGB(red: 0.36, green: 0.55, blue: 0.80, alpha: 1)
        // The bright members on a dark page, matching the washes: the light
        // theme's blue measured 2.4:1 against the dark page and reads as a
        // smudge rather than as a line drawn on purpose.
        case (.high, .dark):
            return .sRGB(red: 1.00, green: 0.46, blue: 0.46, alpha: 1)
        case (.medium, .dark):
            return .sRGB(red: 1.00, green: 0.76, blue: 0.30, alpha: 1)
        case (.low, .dark):
            return .sRGB(red: 0.55, green: 0.76, blue: 1.00, alpha: 1)
        }
    }

    /// The rule for a passage in a given state, which is `nil` for every state
    /// but the open one.
    ///
    /// Hover deliberately does not get one. The reader asked a question by
    /// pointing and answered it by pressing, and the two answers have to look
    /// different or pressing feels like it did nothing.
    public func selectionRule(
        _ state: CritiqueHighlightState,
        on mode: EditorAppearanceMode
    ) -> PlatformColor? {
        state == .selected ? selectionRule(on: mode) : nil
    }

    /// How thick that rule is drawn.
    public static let selectionRuleThickness: CGFloat = 2
}
