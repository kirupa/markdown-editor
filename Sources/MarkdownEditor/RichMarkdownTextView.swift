import AppKit

@MainActor
final class RichMarkdownTextView: NSTextView {
    static let markdownPasteboardType = NSPasteboard.PasteboardType(
        "com.kirupa.markdown-editor.source"
    )

    var compositionDidBegin: ((NSRange) -> Void)?
    var compositionDidCommit: (() -> Void)?
    var markdownForRenderedRange: ((NSRange) -> String)?
    var replaceSelectionWithMarkdown: ((String, String) -> Void)?

    private(set) var isUpdatingComposition = false
    private var compositionIsActive = false
    private weak var compositionUndoManager: UndoManager?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCodeBlockBackgrounds(in: rect)
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        if !compositionIsActive {
            compositionIsActive = true
            compositionUndoManager = undoManager
            compositionUndoManager?.disableUndoRegistration()
            let range = replacementRange.location == NSNotFound
                ? self.selectedRange()
                : replacementRange
            compositionDidBegin?(range)
        }

        isUpdatingComposition = true
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        isUpdatingComposition = false
    }

    override func insertText(
        _ insertString: Any,
        replacementRange: NSRange
    ) {
        guard compositionIsActive else {
            super.insertText(
                insertString,
                replacementRange: replacementRange
            )
            return
        }

        isUpdatingComposition = true
        super.insertText(
            insertString,
            replacementRange: replacementRange
        )
        isUpdatingComposition = false
        finishComposition()
    }

    override func unmarkText() {
        super.unmarkText()
        if !isUpdatingComposition {
            finishComposition()
        }
    }

    func finishPendingComposition() {
        guard compositionIsActive else {
            return
        }
        isUpdatingComposition = true
        super.unmarkText()
        isUpdatingComposition = false
        finishComposition()
    }

    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0,
            let markdown = markdownForRenderedRange?(selection)
        else {
            super.copy(sender)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            markdown,
            forType: Self.markdownPasteboardType
        )
        pasteboard.setString(markdown, forType: .string)
    }

    override func cut(_ sender: Any?) {
        finishPendingComposition()
        guard selectedRange().length > 0 else {
            return
        }
        copy(sender)
        replaceSelectionWithMarkdown?("", "Cut")
    }

    override func paste(_ sender: Any?) {
        finishPendingComposition()
        let pasteboard = NSPasteboard.general
        if let markdown = pasteboard.string(
            forType: Self.markdownPasteboardType
        ) {
            replaceSelectionWithMarkdown?(markdown, "Paste")
            return
        }
        if let plainText = pasteboard.string(forType: .string) {
            insertText(plainText, replacementRange: selectedRange())
            return
        }

        NSSound.beep()
    }

    private func finishComposition() {
        guard compositionIsActive else {
            return
        }
        compositionIsActive = false
        compositionUndoManager?.enableUndoRegistration()
        compositionUndoManager = nil
        compositionDidCommit?()
    }

    private func drawCodeBlockBackgrounds(in dirtyRect: NSRect) {
        guard let textStorage,
            let layoutManager,
            let textContainer,
            textStorage.length > 0
        else {
            return
        }

        let textContainerOrigin = self.textContainerOrigin
        textStorage.enumerateAttribute(
            .markdownCodeBlockBackground,
            in: NSRange(location: 0, length: textStorage.length)
        ) { value, characterRange, _ in
            guard let backgroundColor = value as? NSColor else {
                return
            }

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else {
                return
            }

            var verticalBounds = NSRect.null
            layoutManager.enumerateLineFragments(
                forGlyphRange: glyphRange
            ) { lineRect, _, _, lineGlyphRange, _ in
                guard NSIntersectionRange(
                    glyphRange,
                    lineGlyphRange
                ).length > 0 else {
                    return
                }
                let positionedLineRect = lineRect.offsetBy(
                    dx: textContainerOrigin.x,
                    dy: textContainerOrigin.y
                )
                verticalBounds = verticalBounds.isNull
                    ? positionedLineRect
                    : verticalBounds.union(positionedLineRect)
            }

            guard !verticalBounds.isNull,
                textContainer.size.width.isFinite
            else {
                return
            }

            let horizontalInset: CGFloat = 4
            let verticalPadding: CGFloat = 3
            let blockRect = NSRect(
                x: textContainerOrigin.x + horizontalInset,
                y: verticalBounds.minY - verticalPadding,
                width: max(
                    0,
                    textContainer.size.width - (horizontalInset * 2)
                ),
                height: verticalBounds.height + (verticalPadding * 2)
            )
            guard blockRect.width > 0,
                blockRect.intersects(dirtyRect)
            else {
                return
            }

            backgroundColor.setFill()
            NSBezierPath(
                roundedRect: blockRect,
                xRadius: 5,
                yRadius: 5
            ).fill()
        }
    }
}

extension NSAttributedString.Key {
    static let markdownCodeBlockBackground = Self(
        "com.kirupa.markdown-editor.code-block-background"
    )
}
