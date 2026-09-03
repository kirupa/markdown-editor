import Foundation
import Testing

@testable import MarkdownEditorCore

@Suite("Keeping critique marks on their words")
struct CritiqueAnchorTrackingTests {
    /// "Caching is important because the cache stores data."
    ///                 ^ 11                             ^ 45
    private let passage = NSRange(location: 11, length: 34)

    @Test("Typing before a passage slides it along")
    func typingBefore() {
        let edit = CritiqueAnchorTracking.Edit(
            location: 3, removed: 0, inserted: 5
        )
        #expect(
            CritiqueAnchorTracking.adjust(passage, for: edit)
                == NSRange(location: 16, length: 34)
        )
    }

    @Test("Typing after a passage leaves it alone")
    func typingAfter() {
        let edit = CritiqueAnchorTracking.Edit(
            location: 60, removed: 0, inserted: 5
        )
        #expect(CritiqueAnchorTracking.adjust(passage, for: edit) == passage)
    }

    /// The failure this exists for: a mark that swallows the next sentence.
    @Test("Typing at the very end does not extend it")
    func typingAtTheEnd() {
        let edit = CritiqueAnchorTracking.Edit(
            location: 45, removed: 0, inserted: 20
        )
        #expect(CritiqueAnchorTracking.adjust(passage, for: edit) == passage)
    }

    /// The mirror of it, and just as easy to get wrong: an insertion at the
    /// start must move the passage, not stretch it backwards over the new text.
    @Test("Typing at the very start moves it rather than stretching it")
    func typingAtTheStart() {
        let edit = CritiqueAnchorTracking.Edit(
            location: 11, removed: 0, inserted: 6
        )
        #expect(
            CritiqueAnchorTracking.adjust(passage, for: edit)
                == NSRange(location: 17, length: 34)
        )
    }

    @Test("Typing inside a passage grows it, because it is still the passage")
    func typingInside() {
        let edit = CritiqueAnchorTracking.Edit(
            location: 20, removed: 0, inserted: 4
        )
        #expect(
            CritiqueAnchorTracking.adjust(passage, for: edit)
                == NSRange(location: 11, length: 38)
        )
    }

    @Test("A line break inside ends the passage there")
    func breakingTheLine() {
        let edit = CritiqueAnchorTracking.Edit(
            location: 25, removed: 0, inserted: 2, insertedBreaksLine: true
        )
        #expect(
            CritiqueAnchorTracking.adjust(passage, for: edit)
                == NSRange(location: 11, length: 14)
        )
    }

    @Test("A line break at the end leaves the passage alone")
    func breakingAtTheEnd() {
        let edit = CritiqueAnchorTracking.Edit(
            location: 45, removed: 0, inserted: 2, insertedBreaksLine: true
        )
        #expect(CritiqueAnchorTracking.adjust(passage, for: edit) == passage)
    }

    /// Typing a return between two words *replaces* the space between them,
    /// so it is not a pure insertion. Testing only insertions passed and let
    /// the mark run across the new paragraph.
    @Test("A line break that replaces a space still ends the passage")
    func breakingTheLineByReplacement() {
        let edit = CritiqueAnchorTracking.Edit(
            location: 25, removed: 1, inserted: 2, insertedBreaksLine: true
        )
        #expect(
            CritiqueAnchorTracking.adjust(passage, for: edit)
                == NSRange(location: 11, length: 14)
        )
    }

    @Test("Deleting inside shortens it")
    func deletingInside() {
        let edit = CritiqueAnchorTracking.Edit(
            location: 20, removed: 5, inserted: 0
        )
        #expect(
            CritiqueAnchorTracking.adjust(passage, for: edit)
                == NSRange(location: 11, length: 29)
        )
    }

    @Test("Deleting across the start keeps what survived")
    func deletingAcrossTheStart() {
        let edit = CritiqueAnchorTracking.Edit(
            location: 5, removed: 10, inserted: 0
        )
        #expect(
            CritiqueAnchorTracking.adjust(passage, for: edit)
                == NSRange(location: 5, length: 30)
        )
    }

    @Test("Deleting the whole passage takes its mark with it")
    func deletingItAll() {
        let edit = CritiqueAnchorTracking.Edit(
            location: 0, removed: 60, inserted: 0
        )
        #expect(CritiqueAnchorTracking.adjust(passage, for: edit) == nil)
    }

    @Test("Replacing the passage leaves the mark on what replaced it")
    func replacingIt() {
        let edit = CritiqueAnchorTracking.Edit(
            location: 11, removed: 34, inserted: 9
        )
        #expect(
            CritiqueAnchorTracking.adjust(passage, for: edit)
                == NSRange(location: 11, length: 9)
        )
    }

    // MARK: - Deriving the edit from two versions of the text

    @Test("One typed character")
    func derivesATypedCharacter() {
        let edit = CritiqueAnchorTracking.edit(from: "Hello world", to: "Hello wworld")
        #expect(edit?.location == 7)
        #expect(edit?.removed == 0)
        #expect(edit?.inserted == 1)
        #expect(edit?.insertedBreaksLine == false)
    }

    @Test("A pasted line break is recognised as one")
    func derivesALineBreak() {
        let edit = CritiqueAnchorTracking.edit(from: "One two", to: "One \n\ntwo")
        #expect(edit?.location == 4)
        #expect(edit?.inserted == 2)
        #expect(edit?.insertedBreaksLine == true)
    }

    @Test("A deletion")
    func derivesADeletion() {
        let edit = CritiqueAnchorTracking.edit(from: "Hello world", to: "Hello")
        #expect(edit?.location == 5)
        #expect(edit?.removed == 6)
        #expect(edit?.inserted == 0)
    }

    @Test("No change is no edit")
    func derivesNothingFromNoChange() {
        #expect(CritiqueAnchorTracking.edit(from: "Same", to: "Same") == nil)
    }

    /// End to end, in the shape the bug was reported in: a mark on one
    /// sentence, a new sentence typed after it, and the mark still on the
    /// sentence it was written about.
    @Test("A mark survives a sentence being added after it")
    func endToEnd() {
        let before = "Caching is important because the cache stores data."
        let after = "Caching is important because the cache stores data. And more."
        let mark = NSRange(location: 0, length: 51)
        let edit = CritiqueAnchorTracking.edit(from: before, to: after)
        let moved = edit.flatMap { CritiqueAnchorTracking.adjust(mark, for: $0) }
        #expect(moved == mark)
        #expect(
            (after as NSString).substring(with: moved!)
                == "Caching is important because the cache stores data."
        )
    }
}
