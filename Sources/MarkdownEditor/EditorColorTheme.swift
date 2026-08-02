import AppKit
import SwiftUI

enum EditorColorTheme: String, CaseIterable, Identifiable {
    case light
    case dark
    case beige

    static let storageKey = "editorColorTheme"

    static var systemDefault: Self {
        let globalPreferences = UserDefaults.standard.persistentDomain(
            forName: UserDefaults.globalDomain
        )
        return globalPreferences?["AppleInterfaceStyle"] as? String == "Dark"
            ? .dark
            : .light
    }

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .light:
            "Light"
        case .dark:
            "Dark"
        case .beige:
            "Beige"
        }
    }

    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }

    var appKitAppearance: NSAppearance? {
        NSAppearance(
            named: self == .dark ? .darkAqua : .aqua
        )
    }

    var editorBackgroundColor: NSColor {
        switch self {
        case .light:
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .dark:
            NSColor(
                srgbRed: 0.105,
                green: 0.105,
                blue: 0.115,
                alpha: 1
            )
        case .beige:
            NSColor(
                srgbRed: 0.965,
                green: 0.925,
                blue: 0.82,
                alpha: 1
            )
        }
    }

    var canvasBackgroundColor: NSColor {
        switch self {
        case .light:
            NSColor(
                srgbRed: 0.94,
                green: 0.94,
                blue: 0.95,
                alpha: 1
            )
        case .dark:
            NSColor(
                srgbRed: 0.075,
                green: 0.075,
                blue: 0.085,
                alpha: 1
            )
        case .beige:
            NSColor(
                srgbRed: 0.91,
                green: 0.855,
                blue: 0.735,
                alpha: 1
            )
        }
    }

    var sidebarBackgroundColor: NSColor {
        switch self {
        case .light:
            NSColor(
                srgbRed: 0.955,
                green: 0.955,
                blue: 0.965,
                alpha: 1
            )
        case .dark:
            NSColor(
                srgbRed: 0.12,
                green: 0.12,
                blue: 0.13,
                alpha: 1
            )
        case .beige:
            NSColor(
                srgbRed: 0.925,
                green: 0.875,
                blue: 0.765,
                alpha: 1
            )
        }
    }

    var primaryTextColor: NSColor {
        switch self {
        case .light, .beige:
            .black
        case .dark:
            NSColor(
                srgbRed: 0.92,
                green: 0.92,
                blue: 0.94,
                alpha: 1
            )
        }
    }

    var secondaryTextColor: NSColor {
        switch self {
        case .light:
            NSColor(white: 0.34, alpha: 1)
        case .dark:
            NSColor(white: 0.68, alpha: 1)
        case .beige:
            NSColor(white: 0.28, alpha: 1)
        }
    }

    var separatorColor: NSColor {
        switch self {
        case .light:
            NSColor(white: 0.75, alpha: 1)
        case .dark:
            NSColor(white: 0.28, alpha: 1)
        case .beige:
            NSColor(
                srgbRed: 0.68,
                green: 0.61,
                blue: 0.48,
                alpha: 1
            )
        }
    }

    var selectionBackgroundColor: NSColor {
        switch self {
        case .light:
            NSColor(
                srgbRed: 0.2,
                green: 0.45,
                blue: 0.82,
                alpha: 1
            )
        case .dark:
            NSColor(
                srgbRed: 0.28,
                green: 0.42,
                blue: 0.67,
                alpha: 1
            )
        case .beige:
            NSColor(
                srgbRed: 0.78,
                green: 0.67,
                blue: 0.46,
                alpha: 1
            )
        }
    }

    var selectionTextColor: NSColor {
        self == .beige ? .black : .white
    }

    var inlineCodeBackgroundColor: NSColor {
        switch self {
        case .light:
            NSColor.black.withAlphaComponent(0.07)
        case .dark:
            NSColor.white.withAlphaComponent(0.12)
        case .beige:
            NSColor.black.withAlphaComponent(0.08)
        }
    }

    var codeBlockBackgroundColor: NSColor {
        switch self {
        case .light:
            NSColor(white: 0.93, alpha: 1)
        case .dark:
            NSColor(
                srgbRed: 0.16,
                green: 0.16,
                blue: 0.18,
                alpha: 1
            )
        case .beige:
            NSColor(
                srgbRed: 0.9,
                green: 0.84,
                blue: 0.7,
                alpha: 1
            )
        }
    }

    var canvasBackground: Color {
        Color(nsColor: canvasBackgroundColor)
    }

    var sidebarBackground: Color {
        Color(nsColor: sidebarBackgroundColor)
    }

    @MainActor
    func menuPreviewImage(isSelected: Bool) -> NSImage {
        let size = NSSize(width: 72, height: 20)
        let image = NSImage(
            size: size,
            flipped: false
        ) { bounds in
            let previewBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(
                roundedRect: previewBounds,
                xRadius: 4,
                yRadius: 4
            )
            editorBackgroundColor.setFill()
            path.fill()
            separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let textBounds = NSRect(
                x: 0,
                y: 2,
                width: bounds.width,
                height: bounds.height - 4
            )
            title.draw(
                in: textBounds,
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: primaryTextColor,
                    .paragraphStyle: paragraphStyle
                ]
            )
            if isSelected {
                "✓".draw(
                    at: NSPoint(x: 6, y: 3),
                    withAttributes: [
                        .font: NSFont.systemFont(
                            ofSize: 11,
                            weight: .semibold
                        ),
                        .foregroundColor: primaryTextColor
                    ]
                )
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    @MainActor
    func apply(to textView: NSTextView, in scrollView: NSScrollView) {
        textView.appearance = appKitAppearance
        scrollView.appearance = appKitAppearance
        textView.drawsBackground = true
        textView.backgroundColor = editorBackgroundColor
        textView.textColor = primaryTextColor
        textView.insertionPointColor = primaryTextColor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = editorBackgroundColor
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = editorBackgroundColor
    }

    @MainActor
    func apply(
        to outlineView: NSOutlineView,
        in scrollView: NSScrollView
    ) {
        outlineView.appearance = appKitAppearance
        scrollView.appearance = appKitAppearance
        outlineView.backgroundColor = sidebarBackgroundColor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = sidebarBackgroundColor
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = sidebarBackgroundColor
    }
}
