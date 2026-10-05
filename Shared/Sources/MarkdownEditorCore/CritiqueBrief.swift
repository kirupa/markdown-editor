import Foundation

/// Who a draft is for and what it has to do: the reader every note is held to.
///
/// The critic used to guess this afresh on every run, and word the guess
/// differently each time — "developers who want a practical mental model",
/// then "a web developer audience reading a technical blog post" — with no
/// way for the author to say it was wrong. A note is only as good as the
/// reader it is written for, so a wrong guess made every note on the rail
/// advice for somebody else, and a drifting one made two runs over the same
/// draft disagree for no reason the author could see.
public struct CritiqueBrief: Equatable, Sendable {
    public let text: String
    /// The critic's read of an earlier draft, not the author's words.
    ///
    /// Still sent: holding the next run to the first read is what stops the
    /// reader drifting from one critique to the next. It is sent as a read the
    /// author has not corrected rather than as their word, and the rail says
    /// it was guessed so that correcting it is an obvious thing to do.
    public let isGuess: Bool

    public init(_ text: String = "", isGuess: Bool = false) {
        self.text = Self.normalized(text)
        // Nothing read is nothing guessed. Before the first critique the rail
        // headed its empty line "GUESSED", claiming a read nobody had made.
        self.isGuess = isGuess && !self.text.isEmpty
    }

    public var isEmpty: Bool { text.isEmpty }

    /// One line of plain words, however it was typed or pasted.
    ///
    /// Collapsed because two briefs are compared to decide whether a critique
    /// was written for the reader now named. A trailing space or a pasted line
    /// break is not a different reader, and treating it as one would throw
    /// away every carried note for nothing.
    public static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
