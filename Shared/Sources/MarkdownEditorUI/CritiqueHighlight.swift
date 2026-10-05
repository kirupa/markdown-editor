import CoreGraphics
import Foundation
import MarkdownEditorCore

/// How strongly a critique's passage is shaded, and what put it that way.
///
/// Four states rather than two, because the rail answers the pointer as well
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
    /// Another finding's note is open.
    ///
    /// Quieter than at rest rather than gone. With every passage at the
    /// same wash, the open one's neighbours in a busy paragraph read as
    /// more of it — "hard to tell which note owns which span" was the
    /// report. Hiding them instead loses the map of what else the critique
    /// said, and the click that raises a neighbour's note.
    case receded

    /// Which state a finding's passage is in.
    ///
    /// Written as a function of the two identifiers rather than as a pair of
    /// booleans worked out by the caller, so "selection wins" cannot be
    /// spelled differently by two builds — or by two call sites in one build.
    ///
    /// A hover still lifts a receded passage: pointing at a note is asking
    /// where it is, whichever note is open.
    public static func of(
        _ finding: UUID,
        selected: UUID?,
        hovered: UUID?
    ) -> CritiqueHighlightState {
        if finding == selected { return .selected }
        if finding == hovered { return .hovered }
        if selected != nil { return .receded }
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

    /// The wash for a passage while another finding's note is open.
    ///
    /// The resting colour at about three fifths of its alpha. Far enough
    /// under resting to be seen as a step, so the open passage stands out
    /// from its neighbours by more than its rule; not so far that the other
    /// notes vanish, since they are still there to be pressed.
    public func recededHighlight(on mode: EditorAppearanceMode) -> PlatformColor {
        switch (self, mode) {
        case (.high, .light):
            return .sRGB(red: 0.85, green: 0.24, blue: 0.24, alpha: 0.10)
        case (.medium, .light):
            return .sRGB(red: 0.95, green: 0.66, blue: 0.13, alpha: 0.12)
        case (.low, .light):
            return .sRGB(red: 0.36, green: 0.55, blue: 0.80, alpha: 0.09)
        case (.high, .dark):
            return .sRGB(red: 1.00, green: 0.46, blue: 0.46, alpha: 0.13)
        case (.medium, .dark):
            return .sRGB(red: 1.00, green: 0.76, blue: 0.30, alpha: 0.13)
        case (.low, .dark):
            return .sRGB(red: 0.55, green: 0.76, blue: 1.00, alpha: 0.12)
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
        case .receded: return recededHighlight(on: mode)
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

/// Where one passage's highlight stops and the next one's starts.
///
/// Each passage is drawn as one box per line it is on, and each box is
/// grown a little past the glyphs it covers — 3pt either side, 1pt above and
/// below — so the ink is not touching the edge of its own wash. Measured in
/// a 700pt column, that air is exactly what made two notes read as one: two
/// sentences side by side overlapped by 2pt in the space between them, and
/// a passage ending one line above another's start overlapped it by 2pt as
/// well, in the same colour, so the eye saw one long mark. The report this
/// answers was "hard to tell which note owns which span".
///
/// So passages that are about different words give way to each other,
/// leaving a gap between them. Passages that share words — one sentence
/// inside a paragraph somebody else's note is about — are left as they are:
/// drawing one over the other *is* the truthful picture.
public enum CritiqueHighlightLayout {
    /// The gap left between neighbouring passages.
    ///
    /// Two points, because that is what the boxes overlap by. Trimming each
    /// side of a line boundary by it leaves the passage's own next line
    /// touching it — lines are 2pt apart before the 1pt of air on each — so
    /// a passage stays one shape while its neighbour stops at a visible
    /// edge. Sideways it leaves a point of air past the ink on each side.
    public static let separation: CGFloat = 2

    /// The boxes each passage should be drawn as, in the order given.
    ///
    /// Every passage keeps every box, in the same order — callers draw the
    /// selection rule against the box it measured, so they need the two to
    /// line up. A box is only ever made smaller.
    ///
    /// - Parameters:
    ///   - passages: what each highlight covers in the text, and the boxes it
    ///     measured as, one per line, in a flipped coordinate space.
    ///   - gap: how far apart neighbours end up.
    public static func separated(
        _ passages: [(range: NSRange, boxes: [CGRect])],
        gap: CGFloat = separation
    ) -> [[CGRect]] {
        var edges = passages.map { passage in
            passage.boxes.map {
                (minX: $0.minX, maxX: $0.maxX, minY: $0.minY, maxY: $0.maxY)
            }
        }
        for first in passages.indices {
            for second in passages.indices where second > first {
                guard areApart(passages[first].range, passages[second].range)
                else { continue }
                for (i, one) in passages[first].boxes.enumerated() {
                    for (j, other) in passages[second].boxes.enumerated() {
                        // Measured from the boxes as they came, never from a
                        // box an earlier pair has already trimmed, so the
                        // answer does not depend on the order notes arrived.
                        let shorter = min(one.height, other.height)
                        let acrossY = min(one.maxY, other.maxY)
                            - max(one.minY, other.minY)
                        let acrossX = min(one.maxX, other.maxX)
                            - max(one.minX, other.minX)
                        if acrossY >= shorter / 2 {
                            // The same line: split in the space between.
                            guard acrossX > -gap else { continue }
                            let oneIsLeft = one.midX <= other.midX
                            let left = oneIsLeft ? one : other
                            let right = oneIsLeft ? other : one
                            let cut = (left.maxX + right.minX) / 2
                            let leftEdge = cut - gap / 2
                            let rightEdge = cut + gap / 2
                            if oneIsLeft {
                                edges[first][i].maxX = min(edges[first][i].maxX, leftEdge)
                                edges[second][j].minX = max(edges[second][j].minX, rightEdge)
                            } else {
                                edges[second][j].maxX = min(edges[second][j].maxX, leftEdge)
                                edges[first][i].minX = max(edges[first][i].minX, rightEdge)
                            }
                        } else if acrossY > -gap, acrossX > 0 {
                            // One line over the next: split in the leading.
                            let oneIsAbove = one.midY <= other.midY
                            let upper = oneIsAbove ? one : other
                            let lower = oneIsAbove ? other : one
                            let cut = (upper.maxY + lower.minY) / 2
                            let upperEdge = cut - gap / 2
                            let lowerEdge = cut + gap / 2
                            if oneIsAbove {
                                edges[first][i].maxY = min(edges[first][i].maxY, upperEdge)
                                edges[second][j].minY = max(edges[second][j].minY, lowerEdge)
                            } else {
                                edges[second][j].maxY = min(edges[second][j].maxY, upperEdge)
                                edges[first][i].minY = max(edges[first][i].minY, lowerEdge)
                            }
                        }
                    }
                }
            }
        }
        return zip(passages, edges).map { passage, trimmed in
            zip(passage.boxes, trimmed).map { measured, edge in
                // A box squeezed to nothing between two neighbours keeps its
                // measured extent on that axis: a passage that cannot be seen
                // is worse than one that touches the next.
                let keepsWidth = edge.maxX - edge.minX >= minimumSide
                let keepsHeight = edge.maxY - edge.minY >= minimumSide
                let minX = keepsWidth ? edge.minX : measured.minX
                let maxX = keepsWidth ? edge.maxX : measured.maxX
                let minY = keepsHeight ? edge.minY : measured.minY
                let maxY = keepsHeight ? edge.maxY : measured.maxY
                return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
        }
    }

    private static let minimumSide: CGFloat = 2

    /// Whether two passages are about different words.
    private static func areApart(_ one: NSRange, _ other: NSRange) -> Bool {
        NSMaxRange(one) <= other.location || NSMaxRange(other) <= one.location
    }
}
