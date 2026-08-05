import Foundation

public struct DecodedMarkdownText: Equatable {
    public let text: String
    public let hasByteOrderMark: Bool

    public init(text: String, hasByteOrderMark: Bool) {
        self.text = text
        self.hasByteOrderMark = hasByteOrderMark
    }
}

public enum MarkdownTextCodec {
    private static let UTF8ByteOrderMark = Data([0xEF, 0xBB, 0xBF])

    public enum DecodingError: Error, LocalizedError {
        case invalidUTF8

        public var errorDescription: String? {
            "The file is not valid UTF-8 Markdown."
        }

        public var recoverySuggestion: String? {
            "Convert the file to UTF-8 and try opening it again."
        }
    }

    public static func decodeUTF8(_ data: Data) throws -> DecodedMarkdownText {
        guard String(data: data, encoding: .utf8) != nil else {
            throw DecodingError.invalidUTF8
        }

        let hasByteOrderMark = data.starts(with: UTF8ByteOrderMark)
        let content = hasByteOrderMark
            ? data.dropFirst(UTF8ByteOrderMark.count)
            : data[...]

        return DecodedMarkdownText(
            text: String(decoding: content, as: UTF8.self),
            hasByteOrderMark: hasByteOrderMark
        )
    }

    public static func encodeUTF8(
        _ text: String,
        includeByteOrderMark: Bool = false
    ) -> Data {
        var data = includeByteOrderMark ? UTF8ByteOrderMark : Data()
        data.append(contentsOf: text.utf8)
        return data
    }
}
