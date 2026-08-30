import Foundation
import Testing

@testable import MarkdownEditorCore
@testable import MarkdownEditorUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

/// Which image paths in a real document actually draw a picture.
///
/// This is the gap that hides every image bug. A picture that does not resolve
/// is not a broken picture: the renderer produces no attachment at all, so the
/// line is plain text. It cannot be clicked, selected, resized, or dragged,
/// and nothing anywhere says why. Every other test in the styler suite passes
/// `documentURL: nil`, which means resolution was never exercised once.
///
/// A document written by somebody else — or by an earlier version of this app,
/// or by any other Markdown editor — does not necessarily keep its pictures in
/// the folder this app would have chosen. These are the shapes that turn up in
/// real files.
@Suite("Local image resolution")
struct LocalImageResolutionTests {
    // MARK: - Shapes that must work

    @Test("A picture beside the document resolves")
    func resolvesSibling() throws {
        try withDocument(
            image: "photo.png",
            at: ["photo.png"]
        ) { drew in
            #expect(drew, "a sibling picture should draw")
        }
    }

    @Test("A picture in the app's own assets folder resolves")
    func resolvesAssetsFolder() throws {
        try withDocument(
            image: "Doc.assets/photo.png",
            at: ["Doc.assets", "photo.png"]
        ) { drew in
            #expect(drew)
        }
    }

    @Test("A picture in any subfolder resolves")
    func resolvesSubfolder() throws {
        try withDocument(
            image: "images/photo.png",
            at: ["images", "photo.png"]
        ) { drew in
            #expect(drew, "images/ is the commonest layout there is")
        }
    }

    @Test("An explicitly relative path resolves")
    func resolvesDotSlash() throws {
        try withDocument(
            image: "./photo.png",
            at: ["photo.png"]
        ) { drew in
            #expect(drew)
        }
    }

    @Test("A name with a space resolves, written plainly")
    func resolvesSpaceInName() throws {
        try withDocument(
            image: "My Photo.png",
            at: ["My Photo.png"]
        ) { drew in
            #expect(drew)
        }
    }

    @Test("A name with a space resolves, written percent-encoded")
    func resolvesPercentEncodedName() throws {
        // How most editors write it, and what this app's own importer produces.
        try withDocument(
            image: "My%20Photo.png",
            at: ["My Photo.png"]
        ) { drew in
            #expect(drew)
        }
    }

    // MARK: - Shapes a real document uses that this app refuses

    /// A shared picture folder beside the document's folder.
    ///
    /// ```
    /// Notes/
    ///   images/photo.png
    ///   posts/article.md   ->  ../images/photo.png
    /// ```
    ///
    /// This is an ordinary way to keep one picture used by several documents,
    /// and it is what every static site generator produces. The renderer
    /// refuses it, so the picture silently does not appear.
    @Test("A picture in a sibling folder above the document")
    func resolvesParentRelativePath() throws {
        try withDocument(
            image: "../images/photo.png",
            at: ["images", "photo.png"],
            documentIn: ["posts"]
        ) { drew in
            #expect(
                drew,
                "a picture one level up is still the reader's own file"
            )
        }
    }

    @Test("A picture named by absolute path")
    func resolvesAbsolutePath() throws {
        try withAbsoluteDocument { drew in
            #expect(
                drew,
                "an absolute path is unambiguous and names a real file"
            )
        }
    }

    // MARK: - Shapes that must keep failing

    @Test("A path climbing out to somewhere unrelated is refused")
    func refusesUnrelatedPath() throws {
        try withTemporaryDirectory { directory in
            let elsewhere = directory.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(
                at: elsewhere,
                withIntermediateDirectories: true
            )
            try writePNG(at: elsewhere.appendingPathComponent("secret.png"))

            let home = directory.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(
                at: home,
                withIntermediateDirectories: true
            )
            let documentURL = home.appendingPathComponent("Doc.md")
            try "x".write(to: documentURL, atomically: true, encoding: .utf8)

            // Far enough out that no reasonable reading of "near the document"
            // includes it. The root of the volume is the limit case.
            #expect(
                !drewRealPicture(
                    for: "../../../../../../../../etc/passwd",
                    documentURL: documentURL
                )
            )
        }
    }

    @Test("A remote destination draws no local picture")
    func refusesRemoteDestination() throws {
        try withTemporaryDirectory { directory in
            let documentURL = directory.appendingPathComponent("Doc.md")
            try "x".write(to: documentURL, atomically: true, encoding: .utf8)
            // Remote pictures are fetched by RemoteImageStore, not read as a
            // file. This only asserts the local reader declines to guess.
            #expect(
                !drewRealPicture(
                    for: "https://example.com/photo.png",
                    documentURL: documentURL
                )
            )
        }
    }

    @Test("An unsaved document draws no local picture")
    func refusesWithoutDocumentURL() {
        #expect(!drewRealPicture(for: "photo.png", documentURL: nil))
    }

    // MARK: - Helpers

    /// Whether the renderer drew the reader's actual picture.
    ///
    /// Not "is there an attachment": there always is. An image that cannot be
    /// resolved falls back to an SF Symbol placeholder, so the only honest
    /// question is whether what was drawn is the file on disk. The fixtures are
    /// written 2:1, a shape no placeholder has, so the drawn aspect ratio
    /// answers it without reading pixels.
    private func drewRealPicture(
        for destination: String,
        documentURL: URL?
    ) -> Bool {
        guard let attachment = attachment(for: destination, documentURL: documentURL)
        else { return false }
        let size = attachment.bounds.size
        guard size.width > 0, size.height > 0 else { return false }
        return abs(size.width / size.height - 2) < 0.05
    }

    private func attachment(
        for destination: String,
        documentURL: URL?
    ) -> NSTextAttachment? {
        let model = MarkdownRenderer.render("![photo](\(destination))")
        let styled = RichMarkdownStyler.attributedString(
            for: model,
            documentURL: documentURL,
            colorTheme: EditorColorTheme(color: .blue, mode: .light)
        )
        var found: NSTextAttachment?
        styled.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: styled.length)
        ) { value, _, stop in
            if let attachment = value as? NSTextAttachment {
                found = attachment
                stop.pointee = true
            }
        }
        return found
    }

    private func withDocument(
        image destination: String,
        at components: [String],
        documentIn documentFolder: [String] = [],
        _ body: (Bool) throws -> Void
    ) throws {
        try withTemporaryDirectory { directory in
            let imageURL = components.dropLast().reduce(directory) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            .appendingPathComponent(components[components.count - 1])
            try FileManager.default.createDirectory(
                at: imageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writePNG(at: imageURL)

            let documentDirectory = documentFolder.reduce(directory) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            try FileManager.default.createDirectory(
                at: documentDirectory,
                withIntermediateDirectories: true
            )
            let documentURL = documentDirectory.appendingPathComponent("Doc.md")
            try "x".write(to: documentURL, atomically: true, encoding: .utf8)

            try body(drewRealPicture(for: destination, documentURL: documentURL))
        }
    }

    private func withAbsoluteDocument(
        _ body: (Bool) throws -> Void
    ) throws {
        try withTemporaryDirectory { directory in
            let pictures = directory.appendingPathComponent("Pictures", isDirectory: true)
            try FileManager.default.createDirectory(
                at: pictures,
                withIntermediateDirectories: true
            )
            let imageURL = pictures.appendingPathComponent("photo.png")
            try writePNG(at: imageURL)

            let documentURL = directory.appendingPathComponent("Doc.md")
            try "x".write(to: documentURL, atomically: true, encoding: .utf8)

            try body(
                drewRealPicture(for: imageURL.path, documentURL: documentURL)
            )
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    /// Deliberately 2:1 — a shape the placeholder symbol does not have, so the
    /// drawn aspect ratio distinguishes the real picture from the fallback.
    private func writePNG(at url: URL) throws {
        let width = 48
        let height = 24
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                pixels.append(UInt8((x &* 7) % 256))
                pixels.append(UInt8((y &* 5) % 256))
                pixels.append(UInt8((x &+ y) % 256))
                pixels.append(255)
            }
        }
        let data = try #require(
            makePNGData(pixels: pixels, width: width, height: height)
        )
        try data.write(to: url)
    }

    private func makePNGData(pixels: [UInt8], width: Int, height: Int) -> Data? {
        var pixels = pixels
        guard
            let provider = CGDataProvider(
                data: Data(bytes: &pixels, count: pixels.count) as CFData
            ),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else { return nil }

        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData,
                "public.png" as CFString,
                1,
                nil
            )
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
