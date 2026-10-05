import Foundation

/// How long a draft is, said the way the window's title bar says it:
/// `1,234 words · 6 min read`, or `56 of 1,234 words` while a selection holds
/// some.
///
/// The two numbers somebody writing for an audience checks most, and the
/// editor had neither: the only way to know whether a draft fit a 600-word
/// slot was to paste it into something that counts. Words are
/// `MarkdownProse.wordCount`, the same count that decides whether a draft is
/// long enough to critique (I-273), so the title bar and the critique can
/// never disagree about how much was written.
public struct DocumentLength: Equatable, Sendable {
    public var words: Int

    /// The words in the selection, or `nil` when nothing with a word in it is
    /// selected — a caret, or a selection of only spaces and Markdown marks.
    public var selectedWords: Int?

    public init(words: Int, selectedWords: Int? = nil) {
        self.words = words
        self.selectedWords = selectedWords.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Counted from the draft and, when there is one, its selection.
    ///
    /// The selection is counted on its own text rather than taken as a share
    /// of the whole: a share would have to know where the code blocks and
    /// link addresses fall, which is the one thing the count exists to know.
    public init(text: String, selection: NSRange? = nil) {
        let words = MarkdownProse.wordCount(text)
        var selected: Int?
        if let selection, selection.length > 0 {
            let source = text as NSString
            let start = min(max(selection.location, 0), source.length)
            let end = min(max(selection.location + selection.length, 0), source.length)
            if end > start {
                selected = MarkdownProse.wordCount(
                    source.substring(with: NSRange(location: start, length: end - start))
                )
            }
        }
        self.init(words: words, selectedWords: selected)
    }

    /// Silent reading of English non-fiction, from Brysbaert's 2019 review of
    /// 190 studies. The 200 that most counters use is a round number rather
    /// than a measurement, and adds a minute to every five.
    public static let wordsPerMinute = 238

    /// Whole minutes, rounded up: a 250-word post is a two-minute read, and a
    /// single sentence is still a minute rather than none.
    public var readingMinutes: Int {
        words == 0 ? 0 : (words + Self.wordsPerMinute - 1) / Self.wordsPerMinute
    }

    public func summary(locale: Locale = .current) -> String {
        let total = words.formatted(.number.locale(locale))
        let noun = words == 1 ? "word" : "words"
        if let selectedWords {
            let selected = selectedWords.formatted(.number.locale(locale))
            return "\(selected) of \(total) \(noun)"
        }
        guard words > 0 else {
            return "0 words"
        }
        let minutes = readingMinutes.formatted(.number.locale(locale))
        return "\(total) \(noun) · \(minutes) min read"
    }
}
