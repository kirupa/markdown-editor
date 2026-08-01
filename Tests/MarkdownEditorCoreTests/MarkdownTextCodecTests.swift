import Foundation
import Testing
@testable import MarkdownEditorCore

@Suite("Markdown text codec")
struct MarkdownTextCodecTests {
    @Test("UTF-8 round trip preserves Markdown exactly")
    func UTF8RoundTripPreservesMarkdownExactly() throws {
        let markdown = "# Café\r\n\r\n- one  \r\n- two 🌱\r\n"

        let encoded = MarkdownTextCodec.encodeUTF8(markdown)
        let decoded = try MarkdownTextCodec.decodeUTF8(encoded)

        #expect(decoded.text == markdown)
        #expect(!decoded.hasByteOrderMark)
    }

    @Test("UTF-8 byte order mark is preserved")
    func UTF8ByteOrderMarkIsPreserved() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("# Title\n".utf8)

        let decoded = try MarkdownTextCodec.decodeUTF8(original)
        let encoded = MarkdownTextCodec.encodeUTF8(
            decoded.text,
            includeByteOrderMark: decoded.hasByteOrderMark
        )

        #expect(decoded.text == "# Title\n")
        #expect(decoded.hasByteOrderMark)
        #expect(encoded == original)
    }

    @Test("Invalid UTF-8 is rejected")
    func invalidUTF8IsRejected() {
        let invalidUTF8 = Data([0xC3, 0x28])

        #expect(throws: MarkdownTextCodec.DecodingError.self) {
            try MarkdownTextCodec.decodeUTF8(invalidUTF8)
        }
    }
}
