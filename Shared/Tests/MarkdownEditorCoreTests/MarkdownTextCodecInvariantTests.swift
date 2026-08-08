import Foundation
import MarkdownEditorContract
import Testing
@testable import MarkdownEditorCore

/// The read and write path, which is the only place in this program where a
/// mistake is permanent.
///
/// Everything else can be undone. If the codec drops a byte, normalises a
/// line ending, or eats a byte order mark on the way out, the file on disk is
/// changed and the original is gone. So the standard here is byte-exactness,
/// not "close enough to render the same".
@Suite("Markdown text codec invariants")
struct MarkdownTextCodecInvariantTests {
    // MARK: - Round trips over the shared corpus

    /// Text in, identical text out, for every document in the corpus —
    /// including the ones that exist precisely to break this: CRLF line
    /// endings, emoji, a ZWJ sequence, and escapes.
    @Test("Every corpus document survives a write and read")
    func corpusRoundTripsExactly() throws {
        for document in ContractCorpus.documents {
            let encoded = MarkdownTextCodec.encodeUTF8(document.text)
            let decoded = try MarkdownTextCodec.decodeUTF8(encoded)
            #expect(
                decoded.text == document.text,
                "\(document.id) changed on the way through"
            )
            #expect(!decoded.hasByteOrderMark)
            #expect(
                encoded.count == document.text.utf8.count,
                "\(document.id) did not encode to its own UTF-8 length"
            )
        }
    }

    /// And with a byte order mark, which some Windows editors write and
    /// which must therefore be given back unchanged rather than quietly
    /// dropped or quietly added.
    @Test("Every corpus document survives a round trip with a BOM")
    func corpusRoundTripsWithByteOrderMark() throws {
        for document in ContractCorpus.documents {
            let encoded = MarkdownTextCodec.encodeUTF8(
                document.text,
                includeByteOrderMark: true
            )
            #expect(encoded.starts(with: [0xEF, 0xBB, 0xBF]))
            let decoded = try MarkdownTextCodec.decodeUTF8(encoded)
            #expect(decoded.text == document.text, "\(document.id) with BOM")
            #expect(decoded.hasByteOrderMark)

            // Re-encoding with what was reported must reproduce the file
            // byte for byte — this is what happens on every save.
            let rewritten = MarkdownTextCodec.encodeUTF8(
                decoded.text,
                includeByteOrderMark: decoded.hasByteOrderMark
            )
            #expect(rewritten == encoded, "\(document.id) rewrote differently")
        }
    }

    /// The other direction: bytes in, identical bytes out. A file that is
    /// opened and saved without being touched must not change on disk.
    @Test("Opening and saving an untouched file changes no bytes")
    func untouchedFilesAreUnchanged() throws {
        for document in ContractCorpus.documents {
            for includeBOM in [false, true] {
                let original = MarkdownTextCodec.encodeUTF8(
                    document.text,
                    includeByteOrderMark: includeBOM
                )
                let decoded = try MarkdownTextCodec.decodeUTF8(original)
                let saved = MarkdownTextCodec.encodeUTF8(
                    decoded.text,
                    includeByteOrderMark: decoded.hasByteOrderMark
                )
                #expect(
                    saved == original,
                    "\(document.id) (BOM \(includeBOM)) changed on disk"
                )
            }
        }
    }

    // MARK: - Line endings

    /// Line endings must be preserved exactly, not normalised.
    ///
    /// A CRLF document silently converted to LF looks identical in the editor
    /// and shows every line as modified in the author's version control.
    @Test("Line endings are preserved exactly")
    func lineEndingsArePreserved() throws {
        let samples = [
            "a\r\nb\r\n",
            "a\nb\n",
            "a\rb\r",
            "a\r\nb\nc\r",
            "\r\n",
            "\n\n\n",
            "no trailing newline",
            "trailing spaces  \r\n"
        ]
        for sample in samples {
            let decoded = try MarkdownTextCodec.decodeUTF8(
                MarkdownTextCodec.encodeUTF8(sample)
            )
            #expect(
                decoded.text == sample,
                "\(sample.debugDescription) did not survive"
            )
            #expect(
                decoded.text.unicodeScalars.count
                    == sample.unicodeScalars.count,
                "\(sample.debugDescription) changed length"
            )
        }
    }

    // MARK: - Characters that break naive encoders

    @Test("Characters outside the basic plane survive")
    func astralCharactersSurvive() throws {
        let samples = [
            "🌱",
            "𝄞 clef",
            "🇬🇧 flag",
            "👩‍💻 zero width joiner",
            "e\u{0301} combining acute",
            "text with \u{FEFF} inside it",
            "\u{0000} a null",
            "\u{200B}zero width space",
            String(repeating: "🌱", count: 500)
        ]
        for sample in samples {
            let decoded = try MarkdownTextCodec.decodeUTF8(
                MarkdownTextCodec.encodeUTF8(sample)
            )
            #expect(decoded.text == sample, "\(sample.debugDescription) changed")
        }
    }

    /// Text that *begins* with U+FEFF cannot survive a round trip, and no
    /// UTF-8 editor can make it. The bytes a leading zero-width no-break
    /// space encodes to are the same three bytes as a byte order mark, so a
    /// reader has to choose one reading, and every editor chooses the mark.
    ///
    /// This is a property of the file format rather than a defect here, but
    /// it is pinned so that the day it changes it is a decision rather than
    /// an accident.
    @Test("A leading zero-width no-break space is read as a mark")
    func leadingMarkCharacterIsReadAsAMark() throws {
        let text = "\u{FEFF}starts with a no-break space"
        let decoded = try MarkdownTextCodec.decodeUTF8(
            MarkdownTextCodec.encodeUTF8(text)
        )
        #expect(decoded.hasByteOrderMark)
        #expect(decoded.text == "starts with a no-break space")

        // What matters in practice: the *file* still round-trips, because
        // the mark is reported and written back.
        let original = MarkdownTextCodec.encodeUTF8(text)
        let saved = MarkdownTextCodec.encodeUTF8(
            decoded.text,
            includeByteOrderMark: decoded.hasByteOrderMark
        )
        #expect(saved == original, "the bytes on disk changed")
    }

    /// A byte order mark is only a mark at the very start of the file.
    /// The same bytes in the middle are a zero-width no-break space and must
    /// be kept as content.
    @Test("A mark in the middle of a file is content, not a mark")
    func markInTheMiddleIsContent() throws {
        let data = Data("a".utf8) + Data([0xEF, 0xBB, 0xBF]) + Data("b".utf8)
        let decoded = try MarkdownTextCodec.decodeUTF8(data)
        #expect(!decoded.hasByteOrderMark)
        #expect(decoded.text == "a\u{FEFF}b")
        #expect(MarkdownTextCodec.encodeUTF8(decoded.text) == data)
    }

    /// Two marks: the first is the mark, the second is content.
    @Test("Only the first byte order mark is a mark")
    func onlyTheFirstMarkIsAMark() throws {
        let mark = Data([0xEF, 0xBB, 0xBF])
        let decoded = try MarkdownTextCodec.decodeUTF8(mark + mark + Data("x".utf8))
        #expect(decoded.hasByteOrderMark)
        #expect(decoded.text == "\u{FEFF}x")
    }

    // MARK: - Degenerate input

    @Test("An empty file decodes to empty text")
    func emptyFileDecodesToEmptyText() throws {
        let decoded = try MarkdownTextCodec.decodeUTF8(Data())
        #expect(decoded.text.isEmpty)
        #expect(!decoded.hasByteOrderMark)
        #expect(MarkdownTextCodec.encodeUTF8("").isEmpty)
    }

    /// A file containing nothing but a mark is an empty document that had a
    /// mark, and saving it must not add a stray character.
    @Test("A file of nothing but a byte order mark is empty")
    func markOnlyFileIsEmpty() throws {
        let decoded = try MarkdownTextCodec.decodeUTF8(
            Data([0xEF, 0xBB, 0xBF])
        )
        #expect(decoded.text.isEmpty)
        #expect(decoded.hasByteOrderMark)
    }

    @Test("A truncated byte order mark is content, not a mark")
    func truncatedMarkIsNotAMark() throws {
        // 0xEF 0xBB alone is not valid UTF-8 and must be refused rather than
        // half-read as a mark.
        #expect(throws: MarkdownTextCodec.DecodingError.self) {
            try MarkdownTextCodec.decodeUTF8(Data([0xEF, 0xBB]))
        }
    }

    /// Every shape of malformed UTF-8 must be refused, because the
    /// alternative is opening the file with the bad bytes replaced by U+FFFD
    /// and then writing that back over the original.
    @Test("Malformed UTF-8 is refused rather than repaired")
    func malformedUTF8IsRefused() {
        let malformed: [(String, [UInt8])] = [
            ("lone continuation byte", [0x80]),
            ("truncated two-byte sequence", [0xC3]),
            ("truncated three-byte sequence", [0xE2, 0x82]),
            ("truncated four-byte sequence", [0xF0, 0x9F, 0x8C]),
            ("overlong encoding of /", [0xC0, 0xAF]),
            ("surrogate half encoded as UTF-8", [0xED, 0xA0, 0x80]),
            ("out of range code point", [0xF5, 0x80, 0x80, 0x80]),
            ("continuation without a lead", [0xE2, 0x28, 0xA1]),
            ("valid text then a bad byte", Array("# Title\n".utf8) + [0xFF])
        ]
        for (name, bytes) in malformed {
            #expect(
                throws: MarkdownTextCodec.DecodingError.self,
                "\(name) was accepted"
            ) {
                try MarkdownTextCodec.decodeUTF8(Data(bytes))
            }
        }
    }

    /// The error has to be something a person can act on, since it is shown
    /// in a dialog.
    @Test("The decoding failure explains itself")
    func decodingFailureExplainsItself() {
        let error = MarkdownTextCodec.DecodingError.invalidUTF8
        #expect(!(error.errorDescription ?? "").isEmpty)
        #expect(!(error.recoverySuggestion ?? "").isEmpty)
    }

    // MARK: - Size

    /// A large document must round-trip too; nothing here should be
    /// quadratic or bounded.
    @Test("A large document round-trips")
    func largeDocumentRoundTrips() throws {
        let line = "The quick brown fox jumps over the lazy dog. 🌱\n"
        let large = String(repeating: line, count: 20_000)
        let decoded = try MarkdownTextCodec.decodeUTF8(
            MarkdownTextCodec.encodeUTF8(large)
        )
        #expect(decoded.text == large)
    }
}
