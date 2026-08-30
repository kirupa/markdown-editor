import Foundation
import Testing

@testable import MarkdownEditorCore

/// Moving a picture is a block move, not a text splice.
///
/// The first version inserted at whatever character the pointer was nearest,
/// which turned a drop aimed at the gap above a paragraph into
/// `Ome![photo](a.png)ga paragraph.` — a real result from a real drag. A
/// picture now always lands as a paragraph of its own.
@Suite("Moving an image")
struct MoveImageTests {
    private let image = "![photo](a.png)"

    /// The document the first end-to-end drag was run against.
    private var document: String {
        "# Drag\n\nAlpha paragraph.\n\n\(image)\n\nOmega paragraph.\n"
    }

    private var imageRange: NSRange {
        NSRange(location: ("# Drag\n\nAlpha paragraph.\n\n" as NSString).length,
                length: (image as NSString).length)
    }

    @Test("a drop inside a word still lands between the lines")
    func neverSplicesIntoAWord() {
        let text = document
        // Aimed at the middle of "Omega", which is what the pointer was over.
        let inside = (text as NSString).range(of: "Omega").location + 3
        let result = MarkdownFormatting.moveImage(in: text, range: imageRange, to: inside)
        // Assert the words survived, not that some substring is absent. The
        // picture is inserted with a blank line either side, so splicing it
        // into "Omega" yields "Ome\n\n![photo](a.png)\n\nga" — which passes a
        // check for "Ome![photo]" while the word is still destroyed. That
        // weaker assertion let a deliberately broken build through.
        #expect(result.text.contains("Omega paragraph."))
        #expect(result.text.contains("Alpha paragraph."))
        #expect(result.text.contains("# Drag"))
    }

    @Test("no word is ever broken, wherever it is dropped")
    func everyWordSurvivesEveryDrop() {
        let text = document
        let words = ["# Drag", "Alpha paragraph.", "Omega paragraph."]
        for target in 0...(text as NSString).length {
            let result = MarkdownFormatting.moveImage(
                in: text,
                range: imageRange,
                to: target
            )
            for word in words {
                #expect(
                    result.text.contains(word),
                    "dropping at \(target) broke \(word.debugDescription): \(result.text.debugDescription)"
                )
            }
        }
    }

    @Test("moving below the last paragraph puts it at the end as its own block")
    func movesToTheEnd() {
        let text = document
        let result = MarkdownFormatting.moveImage(
            in: text,
            range: imageRange,
            to: (text as NSString).length
        )
        #expect(result.text == "# Drag\n\nAlpha paragraph.\n\nOmega paragraph.\n\n\(image)")
    }

    @Test("moving above the first paragraph puts it before it")
    func movesAboveAParagraph() {
        let text = document
        let target = (text as NSString).range(of: "Alpha").location
        let result = MarkdownFormatting.moveImage(in: text, range: imageRange, to: target)
        #expect(result.text == "# Drag\n\n\(image)\n\nAlpha paragraph.\n\nOmega paragraph.\n")
    }

    @Test("the picture does not leave an empty paragraph behind")
    func leavesNoHoleBehind() {
        let text = document
        let target = (text as NSString).range(of: "Alpha").location
        let result = MarkdownFormatting.moveImage(in: text, range: imageRange, to: target)
        #expect(!result.text.contains("\n\n\n"))
    }

    @Test("the picture is always separated by a blank line either side")
    func staysItsOwnBlock() {
        let text = document
        for target in [0, 8, 12, (text as NSString).range(of: "Omega").location] {
            let result = MarkdownFormatting.moveImage(in: text, range: imageRange, to: target)
            let ns = result.text as NSString
            let at = ns.range(of: image)
            #expect(at.location != NSNotFound)
            if at.location > 0 {
                #expect(ns.substring(to: at.location).hasSuffix("\n\n"),
                        "no blank line before, target \(target): \(result.text.debugDescription)")
            }
            let after = ns.substring(from: NSMaxRange(at))
            if !after.isEmpty {
                #expect(after.hasPrefix("\n\n"),
                        "no blank line after, target \(target): \(result.text.debugDescription)")
            }
        }
    }

    @Test("the moved picture stays selected")
    func keepsSelection() {
        let text = document
        let target = (text as NSString).range(of: "Alpha").location
        let result = MarkdownFormatting.moveImage(in: text, range: imageRange, to: target)
        #expect((result.text as NSString).substring(with: result.selection) == image)
    }

    @Test("dropping a picture on itself changes nothing")
    func droppingOnItselfIsNotAMove() {
        let text = document
        for offset in imageRange.location...NSMaxRange(imageRange) {
            let result = MarkdownFormatting.moveImage(in: text, range: imageRange, to: offset)
            #expect(result.text == text, "offset \(offset) rewrote the document")
        }
    }

    @Test("a picture sitting inside a sentence takes only itself")
    func inlineImageDoesNotTakeTheSentence() {
        let text = "Before \(image) after.\n\nTail.\n"
        let range = NSRange(location: 7, length: (image as NSString).length)
        let result = MarkdownFormatting.moveImage(
            in: text,
            range: range,
            to: (text as NSString).length
        )
        #expect(result.text.contains("Before  after."))
        #expect(result.text.hasSuffix("\(image)"))
    }

    @Test("a range that is not an image is refused")
    func refusesNonImages() {
        let text = "Just some words"
        let result = MarkdownFormatting.moveImage(
            in: text,
            range: NSRange(location: 0, length: 4),
            to: 10
        )
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

    @Test("offsets past the end are clamped, not crashed into")
    func clampsOffsets() {
        let text = document
        let far = MarkdownFormatting.moveImage(in: text, range: imageRange, to: 9_999)
        #expect(far.text.contains(image))
        let bad = MarkdownFormatting.moveImage(
            in: "AB",
            range: NSRange(location: 1, length: 500),
            to: 0
        )
        #expect(bad.text == "AB")
    }

    @Test("an HTML img tag moves as one piece and keeps its size")
    func movesHTMLImage() {
        let tag = "<img src=\"a.png\" width=\"320\" height=\"200\">"
        let text = "\(tag)\n\nTail.\n"
        let range = NSRange(location: 0, length: (tag as NSString).length)
        let result = MarkdownFormatting.moveImage(
            in: text,
            range: range,
            to: (text as NSString).length
        )
        #expect(result.text.contains("width=\"320\""))
        #expect(result.text.contains("height=\"200\""))
        #expect(result.text.hasSuffix(tag))
    }

    @Test("moving twice returns the document to where it started")
    func movingBackRestoresTheDocument() {
        let text = document
        let away = MarkdownFormatting.moveImage(
            in: text,
            range: imageRange,
            to: (text as NSString).length
        )
        let back = MarkdownFormatting.moveImage(
            in: away.text,
            range: away.selection,
            to: (away.text as NSString).range(of: "Omega").location
        )
        #expect(back.text == text)
    }

    @Test("a document that is nothing but the picture survives a move")
    func lonePicture() {
        let result = MarkdownFormatting.moveImage(
            in: image,
            range: NSRange(location: 0, length: (image as NSString).length),
            to: 0
        )
        #expect(result.text == image)
    }
}
