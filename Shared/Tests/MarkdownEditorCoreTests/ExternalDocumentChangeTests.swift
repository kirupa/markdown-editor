import Foundation
import Testing

@testable import MarkdownEditorCore

@Suite("External document change")
struct ExternalDocumentChangeTests {
    /// The case that dwarfs every other in practice: autosave fires every 1.5
    /// seconds, so most of what this ever sees is the app's own writing.
    @Test("The app's own save is not somebody else's change")
    func ownSaveIsNotAChange() {
        #expect(
            ExternalDocumentChange.detect(
                editorText: "hello",
                lastKnownDiskText: "hello",
                diskText: "hello"
            ) == ExternalDocumentChange.none
        )
    }

    /// The bug this whole design exists to avoid. Autosave writes a version,
    /// the person keeps typing, and the write event arrives afterwards — so at
    /// the moment it is read, the file genuinely differs from the screen
    /// without anybody else having touched it.
    @Test("A save whose event arrives late is still the app's own")
    func lateEventFromOwnSaveIsNotAChange() {
        #expect(
            ExternalDocumentChange.detect(
                editorText: "hello there",
                lastKnownDiskText: "hello",
                diskText: "hello"
            ) == ExternalDocumentChange.none
        )
    }

    @Test("A change with nothing unsaved on screen can just be taken")
    func externalChangeWithCleanEditorIsReloadable() {
        #expect(
            ExternalDocumentChange.detect(
                editorText: "hello",
                lastKnownDiskText: "hello",
                diskText: "hello, world"
            ) == .reloadable
        )
    }

    @Test("A change on top of unsaved edits is a conflict")
    func externalChangeWithDirtyEditorConflicts() {
        #expect(
            ExternalDocumentChange.detect(
                editorText: "mine",
                lastKnownDiskText: "original",
                diskText: "theirs"
            ) == .conflict
        )
    }

    /// The branch that makes an untracked save harmless. `File ▸ Save` goes
    /// through `NSDocument` without telling the watcher, so the only evidence
    /// that the new file contents are ours is that they match the screen.
    @Test("A save this app forgot to record is recognised by matching the screen")
    func untrackedOwnSaveIsRecognised() {
        #expect(
            ExternalDocumentChange.detect(
                editorText: "edited",
                lastKnownDiskText: "original",
                diskText: "edited"
            ) == ExternalDocumentChange.none
        )
    }

    /// Two people arriving at the same text is not a conflict; there is
    /// nothing left to disagree about.
    @Test("Another app writing exactly what is on screen says nothing")
    func convergentChangeIsSilent() {
        #expect(
            ExternalDocumentChange.detect(
                editorText: "same",
                lastKnownDiskText: "different",
                diskText: "same"
            ) == ExternalDocumentChange.none
        )
    }

    @Test("Emptying the file is a change like any other")
    func truncationIsAChange() {
        #expect(
            ExternalDocumentChange.detect(
                editorText: "content",
                lastKnownDiskText: "content",
                diskText: ""
            ) == .reloadable
        )
    }

    /// Whitespace is content in Markdown — a trailing blank line separates
    /// paragraphs — so it must not be normalised away before comparing.
    @Test("A whitespace-only difference still counts")
    func whitespaceOnlyDifferenceCounts() {
        #expect(
            ExternalDocumentChange.detect(
                editorText: "line",
                lastKnownDiskText: "line",
                diskText: "line\n"
            ) == .reloadable
        )
    }

    @Test("Text that differs only by line ending counts as a change")
    func lineEndingDifferenceCounts() {
        #expect(
            ExternalDocumentChange.detect(
                editorText: "a\nb",
                lastKnownDiskText: "a\nb",
                diskText: "a\r\nb"
            ) == .reloadable
        )
    }

    /// Comparison is by value, not by length or hash, so a same-length rewrite
    /// is caught like any other.
    @Test("A same-length rewrite is caught")
    func sameLengthRewriteIsCaught() {
        #expect(
            ExternalDocumentChange.detect(
                editorText: "aaaa",
                lastKnownDiskText: "aaaa",
                diskText: "bbbb"
            ) == .reloadable
        )
    }

    @Test("An empty document that gains content elsewhere is reloadable")
    func emptyDocumentGainingContent() {
        #expect(
            ExternalDocumentChange.detect(
                editorText: "",
                lastKnownDiskText: "",
                diskText: "new"
            ) == .reloadable
        )
    }

    /// Every combination of three texts drawn from a small alphabet, checked
    /// against the property each case is supposed to have. Cheaper than
    /// trusting that the four branches were written in the right order.
    @Test("The decision is exactly determined by which texts are equal")
    func decisionIsDeterminedByEquality() {
        let texts = ["", "a", "b", "ab"]
        for editor in texts {
            for known in texts {
                for disk in texts {
                    let decision = ExternalDocumentChange.detect(
                        editorText: editor,
                        lastKnownDiskText: known,
                        diskText: disk
                    )
                    if disk == known || disk == editor {
                        #expect(
                            decision == ExternalDocumentChange.none,
                            "\(editor)/\(known)/\(disk)"
                        )
                    } else if editor == known {
                        #expect(decision == .reloadable, "\(editor)/\(known)/\(disk)")
                    } else {
                        #expect(decision == .conflict, "\(editor)/\(known)/\(disk)")
                    }
                }
            }
        }
    }

    /// Nothing that reports `.none` may leave work on screen at risk, and
    /// nothing that reports `.reloadable` may have work on screen to lose.
    /// Stated separately from the branch order so that reordering the branches
    /// cannot quietly break it.
    @Test("Reloadable never has unsaved work to lose")
    func reloadableNeverLosesWork() {
        let texts = ["", "a", "b", "ab", "abc"]
        for editor in texts {
            for known in texts {
                for disk in texts {
                    let decision = ExternalDocumentChange.detect(
                        editorText: editor,
                        lastKnownDiskText: known,
                        diskText: disk
                    )
                    guard decision == .reloadable else { continue }
                    // Taking the file's text discards `editor`; that is only
                    // safe when `editor` holds nothing the file does not.
                    #expect(editor == known, "\(editor)/\(known)/\(disk)")
                }
            }
        }
    }
}
