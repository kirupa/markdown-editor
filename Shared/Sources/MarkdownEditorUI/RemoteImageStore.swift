import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

/// Images referenced by a web address rather than copied in beside the
/// document.
///
/// Styling a document is synchronous and re-runs on every keystroke, so it
/// cannot wait for the network. This store answers immediately from memory and
/// starts a download on a miss; when the bytes arrive it posts
/// ``didLoadImage`` and the editor styles the document again, this time with a
/// real picture. Until then the reference draws as the usual placeholder
/// symbol, which is what a document with a mistyped address keeps forever.
///
/// Three things it deliberately does *not* do:
///
/// - **Retry a failure.** A miss records the URL as failed so a broken address
///   costs one request rather than one per keystroke.
/// - **Follow anything but `http`/`https`.** A `file:` address would read the
///   disk from inside the renderer, which is the sandbox escape the local path
///   check exists to prevent.
/// - **Download without a limit.** The stream is abandoned as soon as it passes
///   ``maximumByteCount``, so a link to a huge file cannot stall the editor or
///   exhaust memory.
public final class RemoteImageStore: @unchecked Sendable {
    /// Posted on the main thread once an image has been fetched and decoded.
    /// The `object` is the `URL` that finished, so an observer can ignore a
    /// document it is not showing.
    public static let didLoadImage = Notification.Name(
        "MarkdownEditor.RemoteImageStore.didLoadImage"
    )

    /// The largest image worth holding in memory for a text editor.
    public static let maximumByteCount = 25 * 1024 * 1024

    public static let shared = RemoteImageStore()

    private let session: URLSession
    private let byteLimit: Int
    // One lock over all three, because they are one decision: a URL is either
    // loaded, known bad, already being fetched, or new.
    private let lock = NSLock()
    private var loaded: [URL: PlatformImage] = [:]
    private var failed: Set<URL> = []
    private var inFlight: Set<URL> = []

    /// - Parameter byteLimit: The ceiling on a single download. Injectable so a
    ///   test can prove the stream is abandoned without moving 25 MB.
    public init(session: URLSession? = nil, byteLimit: Int = maximumByteCount) {
        self.byteLimit = byteLimit
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.requestCachePolicy = .returnCacheDataElseLoad
            self.session = URLSession(configuration: configuration)
        }
    }

    /// The image for `destination`, if it is already in memory.
    ///
    /// Returns `nil` both for "not an address we will load" and for "not here
    /// yet". The caller draws a placeholder either way; the difference is that
    /// the second case starts a download and will lead to a ``didLoadImage``.
    public func image(for destination: String) -> PlatformImage? {
        guard let url = Self.remoteURL(for: destination) else { return nil }

        let outcome: (image: PlatformImage?, shouldStart: Bool) = withLock {
            if let image = loaded[url] { return (image, false) }
            let isNew = !failed.contains(url) && !inFlight.contains(url)
            if isNew { inFlight.insert(url) }
            return (nil, isNew)
        }

        if outcome.shouldStart { start(url) }
        return outcome.image
    }

    /// `NSLock.lock()` is unavailable from an async context, and rightly: a
    /// suspension while holding it would block a cooperative thread. Every
    /// critical section here is synchronous and short, so they all go through
    /// this one non-async helper.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func finish(_ url: URL, with image: PlatformImage?) {
        withLock {
            inFlight.remove(url)
            if let image {
                loaded[url] = image
            } else {
                failed.insert(url)
            }
        }
    }

    /// The image for `destination` only if it is already in memory. Never
    /// starts a download, so a caller that merely wants to measure a picture
    /// cannot cause one to be fetched.
    public func loadedImage(for destination: String) -> PlatformImage? {
        guard let url = Self.remoteURL(for: destination) else { return nil }
        return withLock { loaded[url] }
    }

    /// The address a destination refers to, or `nil` if it is not one this
    /// store will load.
    ///
    /// Only `http` and `https` qualify. A relative path, a `file:` URL, and a
    /// `data:` URL all return `nil`: the first two are the local loader's job
    /// and are bounded to the document's own folder, and the third is already
    /// bytes, needing no fetch.
    public static func remoteURL(for destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Written into Markdown, a `)` in a URL is escaped; undo that before
        // the URL is parsed or the address is subtly not the one intended.
        let unescaped = trimmed.replacingOccurrences(of: "\\)", with: ")")
        guard let url = URL(string: unescaped),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return url
    }

    /// Whether a response of `expectedByteCount` is small enough to download.
    /// A negative count means the server did not say, which is not grounds to
    /// refuse — the stream is measured as it arrives instead.
    public static func isWithinLimit(
        expectedByteCount: Int64,
        limit: Int = maximumByteCount
    ) -> Bool {
        expectedByteCount < 0 || expectedByteCount <= Int64(limit)
    }

    private func start(_ url: URL) {
        Task { [weak self] in
            guard let self else { return }
            let image = await Self.download(url, using: session, limit: byteLimit)
            finish(url, with: image)

            guard image != nil else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Self.didLoadImage,
                    object: url
                )
            }
        }
    }

    static func download(
        _ url: URL,
        using session: URLSession,
        limit: Int = maximumByteCount
    ) async -> PlatformImage? {
        do {
            let (stream, response) = try await session.bytes(from: url)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard isWithinLimit(
                expectedByteCount: response.expectedContentLength,
                limit: limit
            ) else { return nil }

            var buffer: [UInt8] = []
            if response.expectedContentLength > 0 {
                buffer.reserveCapacity(Int(min(
                    response.expectedContentLength,
                    Int64(limit)
                )))
            }
            // Accumulated into an array rather than straight into `Data`:
            // `AsyncBytes` yields one byte at a time and `Data.append` per byte
            // measures about ten times slower, which at the ceiling above is the
            // difference between 0.07s and 0.7s of a core.
            for try await byte in stream {
                buffer.append(byte)
                // Measured as it arrives, because a server may understate or
                // omit its length. This is the check that actually bounds the
                // transfer; the one above only saves starting it.
                if buffer.count > limit { return nil }
            }
            return decode(Data(buffer))
        } catch {
            return nil
        }
    }

    /// Bytes to a picture, or `nil` if they are not one. A server that answers
    /// an HTML error page with a 200 lands here, which is why the result is
    /// checked rather than assumed.
    static func decode(_ data: Data) -> PlatformImage? {
        guard !data.isEmpty else { return nil }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        guard let image = NSImage(data: data), image.size.width > 0 else {
            return nil
        }
        return image
        #else
        return UIImage(data: data)
        #endif
    }
}
