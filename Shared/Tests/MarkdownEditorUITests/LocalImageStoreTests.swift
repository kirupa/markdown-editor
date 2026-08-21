import Foundation
import Testing

@testable import MarkdownEditorUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

/// The cache exists to keep typing responsive on an illustrated document —
/// without it every keystroke re-decoded every picture on the page, measured at
/// 65.7 ms per character against 3.8 ms with it.
///
/// Speed is the easy half. The half that can actually hurt a reader is
/// staleness: a picture edited in another app must not go on drawing its old
/// self, so most of what follows is about the file changing underneath us.
@Suite("Local image cache")
struct LocalImageStoreTests {
    // MARK: - Serving from memory

    @Test("The same unchanged file is served from memory")
    func servesRepeatedReadsFromMemory() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("photo.png")
            try writePNG(at: url, width: 8, height: 8, seed: 1)

            let store = LocalImageStore()
            let first = store.image(at: url)
            let second = store.image(at: url)

            #expect(first != nil)
            // The very same object, which is what makes it free the second
            // time. An equal-looking copy would mean it had been decoded again.
            #expect(first === second)
        }
    }

    @Test("Two different files do not collide")
    func distinguishesFiles() throws {
        try withTemporaryDirectory { directory in
            let first = directory.appendingPathComponent("a.png")
            let second = directory.appendingPathComponent("b.png")
            try writePNG(at: first, width: 8, height: 8, seed: 1)
            try writePNG(at: second, width: 16, height: 16, seed: 2)

            let store = LocalImageStore()
            let a = store.image(at: first)
            let b = store.image(at: second)

            #expect(a !== b)
            #expect(a?.size != b?.size)
        }
    }

    // MARK: - The file changing underneath us

    /// The failure this guards against is a reader editing a picture in another
    /// app and the editor going on drawing the old one.
    @Test("A file edited after being cached is read again, not served stale")
    func rereadsAfterTheFileChanges() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("photo.png")
            try writePNG(at: url, width: 8, height: 8, seed: 1)

            let store = LocalImageStore()
            let before = store.image(at: url)
            #expect(before?.size.width == 8)

            // A different picture at the same path, as an external edit leaves
            // things.
            try writePNG(at: url, width: 32, height: 32, seed: 2)
            let after = store.image(at: url)

            #expect(after !== before)
            #expect(after?.size.width == 32)
        }
    }

    /// A timestamp alone is coarse, and a scripted or generated image can be
    /// rewritten within the same second. Size is what catches that.
    ///
    /// The timestamp is pinned to a whole second on both writes deliberately.
    /// Reading a modification date back and setting it again does *not*
    /// round-trip exactly — the filesystem keeps nanoseconds that `Date` does
    /// not reproduce, so the two differ in the last digit or two and the key
    /// changes for a reason that has nothing to do with size. An earlier
    /// version of this test did that and passed whether or not size was in the
    /// key at all.
    @Test("A same-timestamp edit is still noticed, because size is in the key")
    func noticesEditsThatKeepTheTimestamp() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("photo.png")
            let pinned = Date(timeIntervalSince1970: 1_700_000_000)

            try writePNG(at: url, width: 8, height: 8, seed: 1)
            try FileManager.default.setAttributes(
                [.modificationDate: pinned],
                ofItemAtPath: url.path
            )
            let original = try #require(LocalImageStore.cacheKey(for: url))

            // A different picture, written back to the very same instant.
            try writePNG(at: url, width: 32, height: 32, seed: 2)
            try FileManager.default.setAttributes(
                [.modificationDate: pinned],
                ofItemAtPath: url.path
            )
            let rewritten = try #require(LocalImageStore.cacheKey(for: url))

            // Proves the premise: the timestamps really are identical, so only
            // size can tell these two apart.
            let timestamp = try #require(
                FileManager.default.attributesOfItem(atPath: url.path)[
                    .modificationDate
                ] as? Date
            )
            #expect(timestamp.timeIntervalSince1970 == pinned.timeIntervalSince1970)
            #expect(rewritten != original)
        }
    }

    @Test("The key changes when the file changes and holds still when it does not")
    func keyTracksTheFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("photo.png")
            try writePNG(at: url, width: 8, height: 8, seed: 1)

            let first = try #require(LocalImageStore.cacheKey(for: url))
            let unchanged = try #require(LocalImageStore.cacheKey(for: url))
            #expect(first == unchanged)

            try writePNG(at: url, width: 8, height: 8, seed: 99)
            let changed = try #require(LocalImageStore.cacheKey(for: url))
            #expect(changed != first)
        }
    }

    // MARK: - Files that are not there

    @Test("A missing file has no key and yields no image")
    func missingFileIsNotCached() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("absent.png")
            #expect(LocalImageStore.cacheKey(for: url) == nil)
            #expect(LocalImageStore().image(at: url) == nil)
        }
    }

    /// A file that exists but is not a picture must fail the same way an
    /// uncached read fails, so a broken reference still draws the placeholder.
    @Test("A file that is not an image yields nothing, and is not remembered as one")
    func undecodableFileYieldsNothing() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("notreally.png")
            try Data("this is not a png".utf8).write(to: url)

            let store = LocalImageStore()
            #expect(store.image(at: url) == nil)
            // Asked twice, in case a nil had been stored and then handed back
            // as though it were an answer.
            #expect(store.image(at: url) == nil)
        }
    }

    /// A file replaced by a real picture must start working without the app
    /// being restarted.
    @Test("A broken file that later becomes a real image starts working")
    func recoversWhenTheFileBecomesValid() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("photo.png")
            try Data("not a png yet".utf8).write(to: url)

            let store = LocalImageStore()
            #expect(store.image(at: url) == nil)

            try writePNG(at: url, width: 8, height: 8, seed: 3)
            #expect(store.image(at: url) != nil)
        }
    }

    // MARK: - Staying inside a memory budget

    @Test("An image is costed by its pixels, not its bytes on disk")
    func costsByPixelArea() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("photo.png")
            try writePNG(at: url, width: 100, height: 50, seed: 1)

            let image = try #require(LocalImageStore().image(at: url))
            let cost = LocalImageStore.estimatedByteCount(of: image)

            // 100 x 50 at four bytes a pixel.
            #expect(cost == 100 * 50 * 4)
        }
    }

    @Test("Clearing the cache releases what it held")
    func clearsOnRequest() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("photo.png")
            try writePNG(at: url, width: 8, height: 8, seed: 1)

            let store = LocalImageStore()
            let first = store.image(at: url)
            store.removeAll()
            let afterClearing = store.image(at: url)

            #expect(afterClearing != nil)
            #expect(afterClearing !== first)
        }
    }

    /// The budget has to be a real ceiling, or an illustrated document could
    /// cost more memory than the rest of the app together.
    ///
    /// Costing every image the same would make the limit meaningless — a cap
    /// of 192 MB would come to mean "192 million pictures". So this checks the
    /// pixel cost is really handed to the cache, by giving it room for one
    /// image and adding a second.
    @Test("The pixel cost is applied, so a full cache evicts")
    func appliesTheCostToTheBudget() throws {
        try withTemporaryDirectory { directory in
            let first = directory.appendingPathComponent("a.png")
            let second = directory.appendingPathComponent("b.png")
            try writePNG(at: first, width: 64, height: 64, seed: 1)
            try writePNG(at: second, width: 64, height: 64, seed: 2)

            // Room for one 64x64 image (16,384 bytes) but not two.
            let store = LocalImageStore(byteLimit: 20_000)
            let original = store.image(at: first)
            #expect(original != nil)
            // Cached while it is the only one.
            #expect(store.image(at: first) === original)

            // Adding the second pushes the first out.
            #expect(store.image(at: second) != nil)
            #expect(store.image(at: first) !== original)
        }
    }

    @Test("A cache too small for a single image still answers correctly")
    func honoursItsByteLimit() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("photo.png")
            try writePNG(at: url, width: 64, height: 64, seed: 1)

            // Room for far less than one image.
            let store = LocalImageStore(byteLimit: 128)
            // Still answers correctly whether or not it kept anything — the
            // cache is an optimisation with a correct fallback.
            #expect(store.image(at: url) != nil)
            #expect(store.image(at: url) != nil)
        }
    }

    // MARK: - Helpers

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

    /// Writes a real PNG, built here rather than checked in so a test can ask
    /// for whatever size it needs. `seed` varies the pixels, so two files of
    /// the same size still differ in content and in length once compressed.
    private func writePNG(at url: URL, width: Int, height: Int, seed: UInt8) throws {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                pixels.append(UInt8((x &* 7 &+ Int(seed)) % 256))
                pixels.append(UInt8((y &* 5 &+ Int(seed)) % 256))
                pixels.append(UInt8((x &+ y &+ Int(seed)) % 256))
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
        else {
            return nil
        }

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:])
        #else
        return UIImage(cgImage: image).pngData()
        #endif
    }
}
