import Foundation

public enum MarkdownTypography {
    public static let bodyFontSize: CGFloat = 15
    public static let codeFontSize: CGFloat = 13

    public static func headingFontSize(level: Int) -> CGFloat {
        let sizes: [CGFloat] = [30, 25, 21, 18, 16, 15]
        return sizes[min(max(level, 1), 6) - 1]
    }
}
