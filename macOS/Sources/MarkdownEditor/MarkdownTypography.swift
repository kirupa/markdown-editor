import AppKit

enum MarkdownTypography {
    static let bodyFontSize: CGFloat = 15
    static let codeFontSize: CGFloat = 13

    static func headingFontSize(level: Int) -> CGFloat {
        let sizes: [CGFloat] = [30, 25, 21, 18, 16, 15]
        return sizes[min(max(level, 1), 6) - 1]
    }
}
