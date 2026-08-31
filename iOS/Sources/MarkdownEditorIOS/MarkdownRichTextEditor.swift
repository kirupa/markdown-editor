import MarkdownEditorCore
import MarkdownEditorUI
import SwiftUI
import UIKit

/// The rendered pane, which is also editable.
///
/// What is on screen is the *rendered* text — no `#`, no `**` — but typing in
/// it edits the Markdown. The trick, and it is the same one the Mac and web
/// builds use, is that `MarkdownRenderModel` records where every rendered
/// range came from in the source. An edit is turned back into a source edit by
/// diffing the surface text and mapping the changed range through that model,
/// so Markdown the renderer does not show is still preserved untouched.
struct MarkdownRichTextEditor: UIViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: EditorController
    let documentURL: URL?
    let theme: EditorColorTheme
    /// Write a new size for the image occupying a source range.
    var onResizeImage: ((NSRange, MarkdownImageTag.Size) -> Void)?
    /// Move the image occupying a source range to a source offset.
    var onMoveImage: ((NSRange, Int) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.textContainerInset = UIEdgeInsets(
            top: 16, left: 12, bottom: 24, right: 12
        )
        context.coordinator.textView = textView
        context.coordinator.installImageOverlay(on: textView)
        context.coordinator.render(text, theme: theme, documentURL: documentURL)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncIfNeeded(
            text: text,
            revision: controller.externalRevision,
            theme: theme,
            documentURL: documentURL
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: MarkdownRichTextEditor
        weak var textView: UITextView?

        private var model = MarkdownRenderer.render("")
        private var appliedRevision = -1
        private var appliedTheme: EditorColorTheme?
        private var appliedText: String?
        private var isApplyingProgrammatically = false

        init(parent: MarkdownRichTextEditor) {
            self.parent = parent
            super.init()
            // An image given as a web address is not on disk when the document
            // is first styled, so it draws as a placeholder. Styling again when
            // the bytes arrive is what puts the picture on screen; otherwise it
            // would not appear until the next keystroke happened to redraw.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(remoteImageDidLoad),
                name: RemoteImageStore.didLoadImage,
                object: nil
            )
        }

        // MARK: - Selecting, resizing and moving a picture

        private var imageOverlay: MarkdownImageOverlayView?

        /// Put the overlay over the text and attach the two gestures that
        /// belong to the *text view* rather than to a handle.
        ///
        /// A tap selects; a long press begins a move. Both are on the text view
        /// because the overlay claims only its handles — anything else it
        /// swallowed would be a scroll or a caret placement taken away.
        func installImageOverlay(on textView: UITextView) {
            let overlay = MarkdownImageOverlayView(textView: textView)
            overlay.isHidden = true
            overlay.frame = textView.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.onResize = { [weak self] range, size in
                self?.parent.onResizeImage?(range, size)
            }
            overlay.onMove = { [weak self] range, destination in
                self?.parent.onMoveImage?(range, destination)
            }
            overlay.naturalSizeForImage = { [weak self] range in
                self?.naturalSize(forImageAt: range)
            }
            textView.addSubview(overlay)
            imageOverlay = overlay

            let tap = UITapGestureRecognizer(target: self, action: #selector(didTap))
            tap.delegate = self
            textView.addGestureRecognizer(tap)

            let press = UILongPressGestureRecognizer(target: self, action: #selector(didLongPress))
            press.minimumPressDuration = 0.35
            press.delegate = self
            textView.addGestureRecognizer(press)
        }

        @objc private func didTap(_ recogniser: UITapGestureRecognizer) {
            guard let textView else { return }
            let point = recogniser.location(in: textView)
            guard let found = image(at: point, in: textView) else {
                imageOverlay?.show(range: nil, rect: nil)
                return
            }
            imageOverlay?.show(range: found.source, rect: found.rect)
        }

        /// A long press on a picture picks it up.
        ///
        /// Not travel alone, as on macOS: a short drag on a touch screen is how
        /// the document is scrolled, so treating it as a move would make a
        /// document with pictures in it impossible to read.
        @objc private func didLongPress(_ recogniser: UILongPressGestureRecognizer) {
            guard let textView, let overlay = imageOverlay else { return }
            let point = recogniser.location(in: textView)
            switch recogniser.state {
            case .began:
                guard let found = image(at: point, in: textView) else { return }
                overlay.show(range: found.source, rect: found.rect)
                textView.isScrollEnabled = false
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                overlay.beginMove(
                    range: found.source,
                    at: point,
                    image: found.image,
                    size: found.rect.size
                )
            case .changed:
                overlay.continueMove(to: point, boundary: dropBoundary(at: point, in: textView))
            case .ended, .cancelled, .failed:
                textView.isScrollEnabled = true
                overlay.endMove()
            default:
                break
            }
        }

        /// The picture drawn under `point`, with its source range and rect.
        private func image(
            at point: CGPoint,
            in textView: UITextView
        ) -> (source: NSRange, rect: CGRect, image: UIImage?)? {
            let storage = textView.textStorage
            let layout = textView.layoutManager
            let container = textView.textContainer
            let origin = CGPoint(
                x: textView.textContainerInset.left,
                y: textView.textContainerInset.top
            )
            let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            let index = layout.characterIndex(
                for: inContainer,
                in: container,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
            // The nearest insertion point can be the character after the
            // picture, so both neighbours are tried and the rect decides.
            for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
                let range = NSRange(location: candidate, length: 1)
                guard
                    let attachment = storage.attribute(.attachment, at: candidate, effectiveRange: nil)
                        as? NSTextAttachment
                else { continue }
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                rect = rect.offsetBy(dx: origin.x, dy: origin.y)
                guard rect.contains(point) else { continue }
                let source = model.sourceRange(for: range, includingMarkup: true)
                return (source, rect, attachment.image)
            }
            return nil
        }

        /// Where a picture dropped at `point` would land, and the y to draw the
        /// rule at, mirroring the macOS rule: paragraph edges only.
        private func dropBoundary(
            at point: CGPoint,
            in textView: UITextView
        ) -> (location: Int, y: CGFloat)? {
            let storage = textView.textStorage
            guard storage.length > 0 else { return nil }
            let layout = textView.layoutManager
            let container = textView.textContainer
            let origin = CGPoint(
                x: textView.textContainerInset.left,
                y: textView.textContainerInset.top
            )
            let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            let glyph = layout.glyphIndex(for: inContainer, in: container)
            let character = min(
                layout.characterIndexForGlyph(at: glyph),
                max(0, storage.length - 1)
            )
            // Whole paragraphs, not line fragments: a fragment is a *visual*
            // line, so a wrapped paragraph's fragment ends mid-sentence and
            // taking its edge would put the picture inside a word.
            let paragraph = (storage.string as NSString).lineRange(
                for: NSRange(location: character, length: 0)
            )
            let glyphs = layout.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return nil }
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            let below = point.y > rect.midY
            let rendered = below ? NSMaxRange(paragraph) : paragraph.location
            let source = model.sourceRange(
                for: NSRange(location: rendered, length: 0)
            ).location
            return (source, below ? rect.maxY : rect.minY)
        }

        private func naturalSize(forImageAt range: NSRange) -> MarkdownImageTag.Size? {
            guard let textView else { return nil }
            let rendered = model.renderedRange(for: range)
            guard rendered.length == 1, rendered.location < textView.textStorage.length else {
                return nil
            }
            guard
                let attachment = textView.textStorage.attribute(
                    .attachment, at: rendered.location, effectiveRange: nil
                ) as? NSTextAttachment,
                let image = attachment.image
            else { return nil }
            return MarkdownImageTag.Size(
                width: Int(image.size.width.rounded()),
                height: Int(image.size.height.rounded())
            )
        }

        /// Share the text view with its own recognisers.
        ///
        /// UITextView already has a tap that places the caret and a long press
        /// that opens the selection loupe. Refusing to run alongside them would
        /// mean either the picture gestures or ordinary text editing stops
        /// working, so both run and each acts only on what belongs to it.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func remoteImageDidLoad() {
            guard !isApplyingProgrammatically, let applied = appliedText,
                  let theme = appliedTheme
            else { return }
            render(applied, theme: theme, documentURL: parent.documentURL)
        }

        /// Re-styles the document in place.
        ///
        /// Assigning `attributedText` throws away the text view's layout and
        /// takes the reader back to the top with it, so the offset has to be
        /// carried across the assignment by hand. Enough of the document is
        /// laid out first for the offset to survive being clamped against a
        /// content size that has not caught up yet.
        func render(
            _ source: String,
            theme: EditorColorTheme,
            documentURL: URL?
        ) {
            guard let textView else { return }
            isApplyingProgrammatically = true
            defer { isApplyingProgrammatically = false }

            let restoredOffset = textView.contentOffset
            model = MarkdownRenderer.render(source)
            let selected = textView.selectedRange
            textView.attributedText = RichMarkdownStyler.attributedString(
                for: model,
                documentURL: documentURL,
                colorTheme: theme
            )
            textView.backgroundColor = theme.editorBackgroundColor
            textView.tintColor = theme.accentColor
            textView.typingAttributes = MarkdownSourceStyler.baseAttributes(
                colorTheme: theme
            )
            let length = (textView.text ?? "" as String).utf16.count
            textView.selectedRange = NSRange(
                location: min(selected.location, length), length: 0
            )
            restoreOffset(restoredOffset, in: textView)
            appliedText = source
            appliedTheme = theme
        }

        private func restoreOffset(
            _ offset: CGPoint,
            in textView: UITextView
        ) {
            textView.layoutIfNeeded()
            let geometry = EditorScrollGeometry(
                documentHeight: textView.contentSize.height,
                viewportHeight: textView.bounds.height,
                offset: textView.contentOffset.y
            )
            let target = geometry.clampedOffset(offset.y)
            guard geometry.shouldMove(to: target) else {
                return
            }
            textView.contentOffset = CGPoint(x: offset.x, y: target)
        }

        func syncIfNeeded(
            text: String,
            revision: Int,
            theme: EditorColorTheme,
            documentURL: URL?
        ) {
            let themeChanged = appliedTheme != theme
            let textChanged = appliedText != text
            let cameFromElsewhere = revision != appliedRevision
                && parent.controller.lastEditingSurface != .rich

            if themeChanged || (textChanged && cameFromElsewhere) {
                render(text, theme: theme, documentURL: documentURL)
            } else if textChanged {
                appliedText = text
            }
            appliedRevision = revision
        }

        /// Turns an edit to the rendered text into an edit to the source.
        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard !isApplyingProgrammatically else { return true }

            let sourceRange = model.sourceRange(for: range)
            let source = parent.text as NSString
            let clamped = NSRange(
                location: min(sourceRange.location, source.length),
                length: min(
                    sourceRange.length,
                    max(0, source.length - min(sourceRange.location, source.length))
                )
            )
            let updated = source.replacingCharacters(
                in: clamped, with: replacement
            )

            // Where the caret should end up, expressed in the *rendered* text,
            // which is what the user is looking at.
            let renderedCaret = range.location + (replacement as NSString).length

            parent.text = updated
            parent.controller.recordEdit(from: .rich)
            render(
                updated,
                theme: parent.theme,
                documentURL: parent.documentURL
            )
            appliedRevision = parent.controller.externalRevision

            let length = (textView.text ?? "").utf16.count
            let caret = NSRange(
                location: min(max(0, renderedCaret), length), length: 0
            )
            textView.selectedRange = caret
            parent.controller.selection = model.sourceRange(for: caret)
            return false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingProgrammatically else { return }
            parent.controller.selection = model.sourceRange(
                for: textView.selectedRange
            )
        }
    }
}
