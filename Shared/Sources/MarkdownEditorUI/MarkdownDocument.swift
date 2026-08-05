import MarkdownEditorCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    public static let markdownDocument = UTType(
        importedAs: "net.daringfireball.markdown",
        conformingTo: .plainText
    )
}

public struct MarkdownDocument: FileDocument {
    public static var readableContentTypes: [UTType] {
        [.markdownDocument]
    }

    public var text: String
    private var hasUTF8ByteOrderMark: Bool

    /// A new document starts on an empty Heading 1 line — see
    /// ``NewMarkdownDocument``. Reading a file from disk goes through
    /// `init(configuration:)` and is unaffected.
    public init(text: String = NewMarkdownDocument.text) {
        self.text = text
        hasUTF8ByteOrderMark = false
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let decodedText = try MarkdownTextCodec.decodeUTF8(data)
        text = decodedText.text
        hasUTF8ByteOrderMark = decodedText.hasByteOrderMark
    }

    public func fileWrapper(
        configuration: WriteConfiguration
    ) throws -> FileWrapper {
        FileWrapper(
            regularFileWithContents: MarkdownTextCodec.encodeUTF8(
                text,
                includeByteOrderMark: hasUTF8ByteOrderMark
            )
        )
    }
}
