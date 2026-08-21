import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

/// Images copied in beside the document, held in memory between keystrokes.
///
/// Styling re-runs on **every keystroke** and rebuilds every attachment in the
/// document, so without this each character typed re-read and re-decoded every
/// picture on the page. Measured on a document of forty photo-sized
/// references: 65.7 ms per keystroke, of which 64.6 ms was the images — about
/// 15 fps while typing. With the cache the same document styles in roughly the
/// 1 ms the prose alone costs.
///
/// This is the local counterpart to ``RemoteImageStore``, and the two differ in
/// the way that matters: a file can be edited underneath us. So the key carries
/// the file's modification date and size, and a picture changed in another app
/// misses the cache and is read again. `stat` costs a microsecond or so against
/// the millisecond-odd a decode costs, which is what makes checking on every
/// lookup worth it.
///
/// `NSCache` rather than a dictionary, for two reasons: it is already
/// thread-safe, and it releases its contents when the system comes under memory
/// pressure. A text editor should give a hundred megabytes of decoded images
/// back to the OS long before it lets the machine swap.
public final class LocalImageStore: @unchecked Sendable {
    /// Roughly how much decoded image data is worth keeping. Images are far
    /// larger decoded than on disk — a 34 MB photo is about 48 MB of pixels —
    /// so this is a ceiling on pixels, not on files.
    ///
    /// A document whose images do not all fit will evict and re-read as the
    /// reader moves through it. That is the right trade: holding every picture
    /// in a long illustrated document could cost more memory than the rest of
    /// the app put together.
    public static let maximumByteCount = 192 * 1024 * 1024

    public static let shared = LocalImageStore()

    private let cache = NSCache<NSString, PlatformImage>()

    public init(byteLimit: Int = maximumByteCount) {
        cache.totalCostLimit = byteLimit
    }

    /// The image at `url`, from memory when the file on disk is unchanged.
    ///
    /// Returns `nil` for anything unreadable or undecodable, exactly as reading
    /// the file directly does, so a broken reference still draws the
    /// placeholder rather than failing the document.
    public func image(at url: URL) -> PlatformImage? {
        guard let key = Self.cacheKey(for: url) else {
            // No usable identity for the file — it is missing, or unreadable.
            // Fall back to a plain read so behaviour matches the uncached path
            // rather than inventing a failure of its own.
            return PlatformImage.markdownImage(contentsOf: url)
        }

        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let image = PlatformImage.markdownImage(contentsOf: url) else {
            return nil
        }
        cache.setObject(image, forKey: key, cost: Self.estimatedByteCount(of: image))
        return image
    }

    /// Forgets everything. For tests, and for anywhere that wants the memory
    /// back immediately rather than waiting for the system to ask.
    public func removeAll() {
        cache.removeAllObjects()
    }

    /// A key that changes whenever the bytes on disk could have changed.
    ///
    /// Modification date *and* size, because a same-size edit within the same
    /// second is not far-fetched for generated or scripted images, and size
    /// catches what a coarse timestamp misses.
    static func cacheKey(for url: URL) -> NSString? {
        guard
            let attributes = try? FileManager.default
                .attributesOfItem(atPath: url.path)
        else {
            return nil
        }
        let modified = (attributes[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? Int) ?? 0
        return "\(url.path)|\(modified)|\(size)" as NSString
    }

    /// What the decoded picture costs in memory, near enough for a budget:
    /// four bytes a pixel.
    ///
    /// `NSImage` reports its size in points rather than pixels, so an image
    /// with a Retina representation would be under-counted from `size` alone —
    /// the pixel dimensions of the representation are what is asked for.
    static func estimatedByteCount(of image: PlatformImage) -> Int {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let pixels = image.representations.reduce(0) { widest, representation in
            max(widest, representation.pixelsWide * representation.pixelsHigh)
        }
        if pixels > 0 {
            return pixels * 4
        }
        return Int(image.size.width * image.size.height) * 4
        #else
        let scale = image.scale
        return Int(image.size.width * scale * image.size.height * scale) * 4
        #endif
    }
}
