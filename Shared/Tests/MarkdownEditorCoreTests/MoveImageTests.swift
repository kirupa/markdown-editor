import Foundation
import Testing

@testable import MarkdownEditorCore

/// Moving a picture is a text move, and the arithmetic has one trap in it: the
/// destination is measured against the text as it stands, but the image is
/// removed before it is re-inserted, so every offset after it shifts.
@Suite("Moving an image")
struct MoveImageTests {
    private let image = "![photo](a.png)"

    private func document(_ body: String) -> String { body }

    @Test("moving forwards lands where the pointer was, not an image later")
    func movesForwards() {
        let text = "\(image)BC"
        let range = NSRange(location: 0, length: (image as NSString).length)
        let result = MarkdownFormatting.moveImage(in: text, range: range, to: (text as NSString).length)
        #expect(result.text == "BC\(image)")
    }

    @Test("moving backwards lands exactly at the offset given")
    func movesBackwards() {
        let text = "AB\(image)"
        let range = NSRange(location: 2, length: (image as NSString).length)
        let result = MarkdownFormatting.moveImage(in: text, range: range, to: 0)
        #expect(result.text == "\(image)AB")
    }

    @Test("moving into the middle of a line puts it between the characters")
    func movesIntoTheMiddle() {
        let text = "\(image)ABCD"
        let range = NSRange(location: 0, length: (image as NSString).length)
        let imageLength = (image as NSString).length
        let result = MarkdownFormatting.moveImage(in: text, range: range, to: imageLength + 2)
        #expect(result.text == "AB\(image)CD")
    }

    @Test("the moved picture stays selected")
    func keepsSelection() {
        let text = "AB\(image)"
        let range = NSRange(location: 2, length: (image as NSString).length)
        let result = MarkdownFormatting.moveImage(in: text, range: range, to: 0)
        #expect(result.selection == NSRange(location: 0, length: (image as NSString).length))
        let moved = (result.text as NSString).substring(with: result.selection)
        #expect(moved == image)
    }

    @Test("across paragraphs the surrounding text closes up behind it")
    func movesAcrossParagraphs() {
        let text = "# Title\n\n\(image)\n\nTail\n"
        let range = NSRange(location: (("# Title\n\n") as NSString).length,
                            length: (image as NSString).length)
        let result = MarkdownFormatting.moveImage(in: text, range: range, to: (text as NSString).length)
        #expect(result.text == "# Title\n\n\n\nTail\n\(image)")
        #expect(!result.text.contains("\(image)\n\nTail"))
    }

    @Test("dropping a picture on itself changes nothing")
    func droppingOnItselfIsNotAMove() {
        let text = "AB\(image)CD"
        let range = NSRange(location: 2, length: (image as NSString).length)
        for offset in range.location...NSMaxRange(range) {
            let result = MarkdownFormatting.moveImage(in: text, range: range, to: offset)
            #expect(result.text == text, "offset \(offset) rewrote the document")
        }
    }

    @Test("a range that is not an image is refused")
    func refusesNonImages() {
        let text = "Just some words"
        let range = NSRange(location: 0, length: 4)
        let result = MarkdownFormatting.moveImage(in: text, range: range, to: 10)
        #expect(result.text == text)
    }

    @Test("an empty range is refused")
    func refusesEmptyRange() {
        let text = "AB\(image)"
        let result = MarkdownFormatting.moveImage(
            in: text,
            range: NSRange(location: 2, length: 0),
            to: 0
        )
        #expect(result.text == text)
    }

    @Test("a destination past the end is clamped, not crashed into")
    func clampsDestination() {
        let text = "\(image)AB"
        let range = NSRange(location: 0, length: (image as NSString).length)
        let result = MarkdownFormatting.moveImage(in: text, range: range, to: 9_999)
        #expect(result.text == "AB\(image)")
    }

    @Test("a range past the end is clamped, not crashed into")
    func clampsRange() {
        let text = "AB"
        let result = MarkdownFormatting.moveImage(
            in: text,
            range: NSRange(location: 1, length: 500),
            to: 0
        )
        #expect(result.text == text)
    }

    @Test("an HTML img tag moves as one piece")
    func movesHTMLImage() {
        let tag = "<img src=\"a.png\" width=\"200\">"
        let text = "AB\(tag)"
        let range = NSRange(location: 2, length: (tag as NSString).length)
        let result = MarkdownFormatting.moveImage(in: text, range: range, to: 0)
        #expect(result.text == "\(tag)AB")
    }

    @Test("a picture keeps its size when it moves")
    func keepsSizeWhenMoving() {
        let sized = "<img src=\"a.png\" width=\"320\" height=\"200\">"
        let text = "\(sized)\n\nTail"
        let range = NSRange(location: 0, length: (sized as NSString).length)
        let result = MarkdownFormatting.moveImage(
            in: text,
            range: range,
            to: (text as NSString).length
        )
        #expect(result.text.contains("width=\"320\""))
        #expect(result.text.contains("height=\"200\""))
        #expect(result.text.hasSuffix(sized))
    }

    @Test("moving twice returns the document to where it started")
    func movingBackRestoresTheDocument() {
        let text = "\(image)AB"
        let length = (image as NSString).length
        let forwards = MarkdownFormatting.moveImage(
            in: text,
            range: NSRange(location: 0, length: length),
            to: (text as NSString).length
        )
        #expect(forwards.text == "AB\(image)")
        let back = MarkdownFormatting.moveImage(
            in: forwards.text,
            range: forwards.selection,
            to: 0
        )
        #expect(back.text == text)
    }
}
