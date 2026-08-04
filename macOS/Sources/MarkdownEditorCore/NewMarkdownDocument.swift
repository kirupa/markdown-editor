import Foundation

/// What a brand-new, never-saved document starts as.
///
/// A document almost always opens with a title, so a new one begins on an
/// empty Heading 1 line with the caret already inside it: type the title,
/// press Return, and keep writing. Return at the end of a heading already
/// produced a body paragraph — a heading is not a list and has nothing to
/// continue — so only the starting text and the caret needed to change.
///
/// The heading is ordinary Markdown, not a mode: deleting the `# ` leaves a
/// blank document, exactly as before.
///
/// The web build carries the same constant in `document.js`, and both are
/// byte-identical to what choosing Heading 1 on an empty document produces.
public enum NewMarkdownDocument {
    public static let text = "# "

    /// Where the caret belongs the first time a document is shown.
    ///
    /// Past the heading marker for a new document, so the first keystroke
    /// becomes the title instead of landing in front of the `#` and turning
    /// the heading into a paragraph. Any other document opens at the start,
    /// which is what it did before this existed.
    public static func initialSelection(
        text: String,
        isNewDocument: Bool
    ) -> NSRange {
        guard isNewDocument, text == Self.text else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(location: (Self.text as NSString).length, length: 0)
    }
}
