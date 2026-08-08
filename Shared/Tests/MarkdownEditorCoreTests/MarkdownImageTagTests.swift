import Foundation
import Testing
@testable import MarkdownEditorCore

/// How an image with a size is written, and read back.
///
/// These mirror `Web/public/tests/image-tag.test.js` case for case. The two
/// implementations have to agree exactly or a document sized on one platform
/// shows raw HTML on another.
@Suite("Image tags")
struct MarkdownImageTagTests {
    private func parse(_ text: String) -> MarkdownImageTag.Parsed? {
        let source = text as NSString
        return MarkdownImageTag.parse(source, at: 0, end: source.length)
    }

    // MARK: - Reading a tag

    @Test("A tag with a source is an image")
    func testATagWithASourceIsAnImage() {
        let text = "<img src=\"a.png\" alt=\"A photo\" width=\"300\" height=\"200\">"
        let tag = parse(text)
        #expect(tag?.destination == "a.png")
        #expect(tag?.altText == "A photo")
        #expect(tag?.width == 300)
        #expect(tag?.height == 200)
        #expect(tag?.end == (text as NSString).length)
    }

    @Test("Attributes are read in any order quoted either way or not at all")
    func testAttributesAreReadInAnyOrderQuotedEitherWayOrNotAtAll() {
        let variants = [
            "<img width=\"300\" src=\"a.png\">", "<img src='a.png' width='300'>", "<img src=a.png width=300>", "<img   src = \"a.png\"   width = \"300\"  >", "<IMG SRC=\"a.png\" WIDTH=\"300\">", "<img src=\"a.png\" width=\"300\"/>"
        ]
        for text in variants {
            let tag = parse(text)
            #expect(tag != nil)
            #expect(tag?.destination == "a.png")
            #expect(tag?.width == 300)
        }
    }

    @Test("A quoted value may contain the characters that would end the tag")
    func testAQuotedValueMayContainTheCharactersThatWouldEndTheTag() {
        let tag = parse("<img src=\"a.png\" alt=\"a > b, 'quoted'\">")
        #expect(tag?.altText == "a > b, 'quoted'")
        #expect(tag?.destination == "a.png")
    }

    @Test("Entities in an attribute are decoded")
    func testEntitiesInAnAttributeAreDecoded() {
        let tag = parse("<img src=\"a.png?x=1&amp;y=2\" alt=\"&quot;Hi&quot; &lt;&gt; &#65;\">")
        #expect(tag?.destination == "a.png?x=1&y=2")
        #expect(tag?.altText == "\"Hi\" <> A")
    }

    @Test("An element that merely starts with img is not an image")
    func testAnElementThatMerelyStartsWithImgIsNotAnImage() {
        // `<imgx>` shares a prefix and nothing else.
        for text in [
            "<imgx src=\"a.png\">", "<image src=\"a.png\">", "<div src=\"a.png\">"
        ] {
            #expect(parse(text) == nil)
        }
    }

    @Test("A tag with nothing to draw is not an image")
    func testATagWithNothingToDrawIsNotAnImage() {
        // Left as text on purpose: an author can see and fix a tag they can
        // read, and cannot fix an empty box.
        #expect(parse("<img>") == nil)
        #expect(parse("<img alt=\"nothing\" width=\"10\">") == nil)
        #expect(parse("<img src=\"\">") == nil)
    }

    @Test("An unterminated tag is not an image")
    func testAnUnterminatedTagIsNotAnImage() {
        // Otherwise text that merely begins like a tag would be swallowed to
        // the end of the line.
        #expect(parse("<img src=\"a.png\"") == nil)
        #expect(parse("<img src=\"a.png") == nil)
    }

    @Test("Text that only looks like a tag keeps its words")
    func testTextThatOnlyLooksLikeATagKeepsItsWords() {
        let line = "Check <img src=\"a.png\" in the docs" as NSString
        #expect(MarkdownImageTag.parse(line, at: 6, end: line.length) == nil)
    }

    @Test("A size that is not a pixel count is simply absent")
    func testASizeThatIsNotAPixelCountIsSimplyAbsent() {
        // `50%` is legal HTML this editor cannot show in a number field. The
        // image still renders; there is just no number to offer, and nothing
        // the author wrote by hand gets quietly rewritten.
        let tag = parse("<img src=\"a.png\" width=\"50%\" height=\"0\">")
        #expect(tag?.destination == "a.png")
        #expect(tag?.width == nil)
        #expect(tag?.height == nil)
    }

    @Test("A tag inside a longer line reports where it ends")
    func testATagInsideALongerLineReportsWhereItEnds() {
        let line = "Before <img src=\"a.png\"> after" as NSString
        let tag = MarkdownImageTag.parse(line, at: 7, end: line.length)
        #expect(line.substring(with: NSRange(location: 7, length: tag!.end - 7)) == "<img src=\"a.png\">")
    }

    // MARK: - Writing a reference

    @Test("An image with no size is plain markdown")
    func testAnImageWithNoSizeIsPlainMarkdown() {
        // The common case stays the common syntax. HTML shows up only where it
        // buys something, which for an unsized image it does not.
        #expect(MarkdownImageTag.reference(destination: "Post.assets/photo.png", altText: "Photo") == "![Photo](Post.assets/photo.png)")
    }

    @Test("An image with a size is html")
    func testAnImageWithASizeIsHTML() {
        #expect(MarkdownImageTag.reference(destination: "a.png", altText: "Photo", size: .init(width: 300, height: 200)) == "<img src=\"a.png\" alt=\"Photo\" width=\"300\" height=\"200\">")
    }

    @Test("One dimension on its own is written on its own")
    func testOneDimensionOnItsOwnIsWrittenOnItsOwn() {
        // A lone width lets the renderer derive the height from the real
        // image, which is more accurate than any number written here.
        #expect(MarkdownImageTag.reference(destination: "a.png", size: .init(width: 300)) == "<img src=\"a.png\" alt=\"\" width=\"300\">")
        #expect(MarkdownImageTag.reference(destination: "a.png", size: .init(height: 200)) == "<img src=\"a.png\" alt=\"\" height=\"200\">")
    }

    @Test("What is written parses back to what was asked for")
    func testWhatIsWrittenParsesBackToWhatWasAskedFor() {
        let cases: [(String, String, MarkdownImageTag.Size)] = [
            ("a.png", "Photo", .init(width: 300, height: 200)), ("dir/a%20b.png", "", .init(width: 12)), ("a.png?x=1&y=2", "He said \"hi\" <loudly>", .init(width: 5, height: 7))
        ]
        for (destination, altText, size) in cases {
            let written = MarkdownImageTag.reference(destination: destination, altText: altText, size: size)
            let tag = parse(written)
            #expect(tag?.destination == destination)
            #expect(tag?.altText == altText)
            #expect(tag?.width == size.width)
            #expect(tag?.height == size.height)
        }
    }

    @Test("Characters that would break out of an attribute are escaped")
    func testCharactersThatWouldBreakOutOfAnAttributeAreEscaped() {
        let written = MarkdownImageTag.reference(destination: "a.png", altText: "\" onerror=\"alert(1)", size: .init(width: 10))
        #expect(!(written.contains("\" onerror=")))
        #expect(parse(written)?.altText == "\" onerror=\"alert(1)")
    }

    @Test("A markdown label escapes the brackets that would end it")
    func testAMarkdownLabelEscapesTheBracketsThatWouldEndIt() {
        #expect(MarkdownImageTag.markdownReference(altText: "a [b] c", destination: "a.png") == "![a \\[b\\] c](a.png)")
    }

    @Test("A space in the path is encoded in the markdown form")
    func testASpaceInThePathIsEncodedInTheMarkdownForm() {
        // An HTML attribute holds `my file.png` happily; the same text in
        // Markdown is not an image at all — GitHub renders it as literal text
        // and the picture is lost. Verified against GitHub's own renderer.
        #expect(MarkdownImageTag.markdownReference(altText: "P", destination: "my file.png") == "![P](my%20file.png)")
    }

    @Test("Encoding a path twice changes nothing")
    func testEncodingAPathTwiceChangesNothing() {
        // Conversions run in both directions, so the encoding has to be safe
        // to apply to a path that already carries it.
        let once = MarkdownImageTag.encodeDestination("my file (1).png")
        #expect(MarkdownImageTag.encodeDestination(once) == once)
    }

    @Test("A size of zero or nonsense is treated as no size at all")
    func testASizeOfZeroOrNonsenseIsTreatedAsNoSizeAtAll() {
        for size in [0, -5] {
            #expect(MarkdownImageTag.reference(destination: "a.png", size: .init(width: size)) == "![](a.png)")
        }
    }

    // MARK: - Keeping an image in proportion

    private let natural = MarkdownImageTag.Size(width: 1600, height: 900)

    @Test("Typing a width derives the height")
    func testTypingAWidthDerivesTheHeight() {
        #expect(MarkdownImageTag.proportionalSize(.init(width: 800), natural: natural, edited: .width) == .init(width: 800, height: 450))
    }

    @Test("Typing a height derives the width")
    func testTypingAHeightDerivesTheWidth() {
        #expect(MarkdownImageTag.proportionalSize(.init(height: 450), natural: natural, edited: .height) == .init(width: 800, height: 450))
    }

    @Test("The number that was typed is the one kept exactly")
    func testTheNumberThatWasTypedIsTheOneKeptExactly() {
        // 777 does not divide evenly, and the typed number must survive
        // anyway — otherwise the field fights the person typing in it.
        let sized = MarkdownImageTag.proportionalSize(.init(width: 777), natural: natural, edited: .width)
        #expect(sized.width == 777)
        #expect(sized.height == 437)
    }

    @Test("A very wide image never derives a height of zero")
    func testAVeryWideImageNeverDerivesAHeightOfZero() {
        // Rounding 0.25 to 0 would make the picture vanish, so the derived
        // side is kept away from zero deliberately.
        let sized = MarkdownImageTag.proportionalSize(.init(width: 10), natural: .init(width: 4000, height: 100), edited: .width)
        #expect(sized.height == 1)
    }

    @Test("With no natural size nothing is derived")
    func testWithNoNaturalSizeNothingIsDerived() {
        // An image that has not loaded has no shape to preserve. Inventing one
        // would distort the picture the moment it did load.
        #expect(MarkdownImageTag.proportionalSize(.init(width: 300), natural: nil, edited: .width) == .init(width: 300, height: nil))
    }

    @Test("Clearing the size clears both sides")
    func testClearingTheSizeClearsBothSides() {
        #expect(MarkdownImageTag.proportionalSize(.none, natural: natural, edited: .width) == .none)
    }
}
