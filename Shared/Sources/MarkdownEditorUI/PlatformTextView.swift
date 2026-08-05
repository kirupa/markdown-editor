#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

import Foundation

/// Teaches each platform's plain-text view the handful of things the shared
/// source styler asks for.
///
/// These live beside the protocol rather than in the apps so that neither app
/// declares a conformance for a type it does not own, and so the two spellings
/// sit next to each other where a difference between them is obvious.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension NSTextView: MarkdownSourceTextView {
    public var sourceTextStorage: NSTextStorage? { textStorage }
    public var sourceText: String { string }
    public var sourceSelectionLocation: Int { selectedRange().location }
    public var sourceTypingAttributes: [NSAttributedString.Key: Any] {
        get { typingAttributes }
        set { typingAttributes = newValue }
    }
    public var sourceUndoManager: UndoManager? { undoManager }
}
#elseif canImport(UIKit)
extension UITextView: MarkdownSourceTextView {
    public var sourceTextStorage: NSTextStorage? { textStorage }
    public var sourceText: String { text ?? "" }
    public var sourceSelectionLocation: Int { selectedRange.location }
    public var sourceTypingAttributes: [NSAttributedString.Key: Any] {
        get { typingAttributes }
        set { typingAttributes = newValue }
    }
    public var sourceUndoManager: UndoManager? { undoManager }
}
#endif
