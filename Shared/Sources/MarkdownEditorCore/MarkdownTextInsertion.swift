import Foundation

/// Putting literal text in at the caret.
///
/// This is the one edit that is not a `MarkdownFormatting` command: an image
/// reference, which `MarkdownImageImporter` has already built, simply goes in
/// where the caret is. It looks too small to be worth its own type, but the
/// arithmetic has three ways to be wrong — a selection that runs past the end
/// of the text, a location past the end, and a caret that has to land after
/// the inserted text measured in UTF-16 rather than characters — and getting
/// any of them wrong either traps or silently puts the caret somewhere else.
///
/// It lives here, rather than in a view, so it can be tested without a text
/// view, a run loop, or a platform.
public enum MarkdownTextInsertion {
    /// Replaces `selection` with `fragment`, leaving the caret after it.
    ///
    /// `selection` is clamped rather than rejected: a stale selection from
    /// before an external change is normal, not an error, and truncating it
    /// is what a text view would do anyway.
    public static func insert(
        _ fragment: String,
        in text: String,
        selection requestedSelection: NSRange
    ) -> MarkdownEditResult {
        let source = text as NSString
        let location = min(max(0, requestedSelection.location), source.length)
        let length = min(
            max(0, requestedSelection.length),
            source.length - location
        )
        let range = NSRange(location: location, length: length)

        return MarkdownEditResult(
            text: source.replacingCharacters(in: range, with: fragment),
            selection: NSRange(
                location: location + (fragment as NSString).length,
                length: 0
            )
        )
    }
}
