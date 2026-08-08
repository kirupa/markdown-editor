import Foundation
import Testing

@testable import MarkdownEditorUI

@Suite("Remote images")
struct RemoteImageStoreTests {
    // MARK: - Which addresses are fetched at all

    @Test("An http or https address is fetched")
    func acceptsWebAddresses() {
        #expect(
            RemoteImageStore.remoteURL(for: "https://example.com/a.png")?
                .absoluteString == "https://example.com/a.png"
        )
        #expect(
            RemoteImageStore.remoteURL(for: "http://example.com/a.png") != nil
        )
    }

    @Test("The scheme is matched without regard to case")
    func schemeIsCaseInsensitive() {
        #expect(RemoteImageStore.remoteURL(for: "HTTPS://example.com/a.png") != nil)
        #expect(RemoteImageStore.remoteURL(for: "Http://example.com/a.png") != nil)
    }

    @Test("A relative path is left to the local loader")
    func ignoresRelativePaths() {
        #expect(RemoteImageStore.remoteURL(for: "photo.png") == nil)
        #expect(RemoteImageStore.remoteURL(for: "notes.assets/photo.png") == nil)
        #expect(RemoteImageStore.remoteURL(for: "../up.png") == nil)
    }

    /// The local loader confines itself to the document's own folder. If this
    /// store followed a `file:` URL it would read anywhere on disk from inside
    /// the renderer, which is exactly the check being sidestepped.
    @Test("A file URL is refused, so the renderer cannot read arbitrary disk")
    func refusesFileURLs() {
        #expect(RemoteImageStore.remoteURL(for: "file:///etc/passwd") == nil)
        #expect(RemoteImageStore.remoteURL(for: "FILE:///etc/passwd") == nil)
        // The three-slash forms above carry no host, so they would be refused
        // even by a store that had forgotten to check the scheme. This one has
        // a host and is refused only because `file` is not `http`.
        #expect(RemoteImageStore.remoteURL(for: "file://localhost/etc/passwd") == nil)
    }

    /// Same reasoning as `file:`, for the other schemes a URL initialiser will
    /// happily accept. Each carries a host, so only the scheme check stops them.
    @Test("Other schemes with a host are refused")
    func refusesOtherSchemes() {
        #expect(RemoteImageStore.remoteURL(for: "ftp://example.com/a.png") == nil)
        #expect(RemoteImageStore.remoteURL(for: "javascript://example.com/a.png") == nil)
        #expect(RemoteImageStore.remoteURL(for: "ws://example.com/a.png") == nil)
    }

    @Test("A data URL needs no fetch")
    func refusesDataURLs() {
        #expect(
            RemoteImageStore.remoteURL(for: "data:image/png;base64,iVBORw0KGgo=")
                == nil
        )
    }

    @Test("An address with no host is refused")
    func refusesHostlessAddresses() {
        #expect(RemoteImageStore.remoteURL(for: "https://") == nil)
        #expect(RemoteImageStore.remoteURL(for: "https:///just/a/path") == nil)
    }

    @Test("Empty and whitespace destinations are refused")
    func refusesEmptyDestinations() {
        #expect(RemoteImageStore.remoteURL(for: "") == nil)
        #expect(RemoteImageStore.remoteURL(for: "   \n ") == nil)
    }

    @Test("Surrounding whitespace is trimmed before parsing")
    func trimsWhitespace() {
        #expect(
            RemoteImageStore.remoteURL(for: "  https://example.com/a.png\n")?
                .absoluteString == "https://example.com/a.png"
        )
    }

    /// Markdown escapes a closing parenthesis in a destination. Parsing the
    /// escaped form would request a URL containing a backslash, which is not
    /// the address the writer gave.
    @Test("An escaped parenthesis is unescaped before the URL is parsed")
    func unescapesParentheses() {
        let url = RemoteImageStore.remoteURL(for: #"https://example.com/a\).png"#)
        #expect(url?.absoluteString == "https://example.com/a).png")
    }

    @Test("A query string and a port survive")
    func keepsQueryAndPort() {
        let url = RemoteImageStore.remoteURL(
            for: "https://example.com:8443/a.png?token=abc&v=2"
        )
        #expect(url?.absoluteString == "https://example.com:8443/a.png?token=abc&v=2")
    }

    /// Cloud documents reference their pictures by Storage download URL, so
    /// this is the shape that has to work for a cloud document to render.
    @Test("A Firebase Storage download URL is fetched")
    func acceptsStorageDownloadURLs() {
        let url = RemoteImageStore.remoteURL(
            for: "https://firebasestorage.googleapis.com/v0/b/kirupa-markdown"
                + ".firebasestorage.app/o/users%2Fabc%2Fp.png?alt=media&token=x"
        )
        #expect(url != nil)
    }

    // MARK: - The size limit

    @Test("A response within the limit is downloaded")
    func allowsSmallResponses() {
        #expect(RemoteImageStore.isWithinLimit(expectedByteCount: 0))
        #expect(RemoteImageStore.isWithinLimit(expectedByteCount: 1024))
        #expect(
            RemoteImageStore.isWithinLimit(
                expectedByteCount: Int64(RemoteImageStore.maximumByteCount)
            )
        )
    }

    @Test("A response over the limit is refused before it is read")
    func refusesLargeResponses() {
        #expect(
            !RemoteImageStore.isWithinLimit(
                expectedByteCount: Int64(RemoteImageStore.maximumByteCount) + 1
            )
        )
        #expect(!RemoteImageStore.isWithinLimit(expectedByteCount: 5_000_000_000))
    }

    /// A server that does not send `Content-Length` reports -1. Refusing that
    /// would rule out chunked responses, which are ordinary; the stream is
    /// measured as it arrives instead.
    @Test("An unknown length is not by itself a refusal")
    func allowsUnknownLength() {
        #expect(RemoteImageStore.isWithinLimit(expectedByteCount: -1))
    }

    // MARK: - Decoding

    @Test("Bytes that are not an image decode to nothing")
    func rejectsNonImageBytes() {
        #expect(RemoteImageStore.decode(Data()) == nil)
        #expect(RemoteImageStore.decode(Data("<html>Not found</html>".utf8)) == nil)
    }

    @Test("A real PNG decodes")
    func decodesPNG() throws {
        let image = try #require(RemoteImageStore.decode(Self.fourToOnePNG))
        #expect(image.size.width == 400)
        #expect(image.size.height == 100)
    }

    // MARK: - The cache

    @Test("An address not yet loaded reports no image but is recognised")
    func missReportsNothingYet() {
        let store = RemoteImageStore()
        let address = "https://example.invalid/never-resolves.png"
        #expect(RemoteImageStore.remoteURL(for: address) != nil)
        #expect(store.loadedImage(for: address) == nil)
    }

    @Test("A destination the store will not fetch is not claimed")
    func doesNotClaimLocalPaths() {
        let store = RemoteImageStore()
        #expect(RemoteImageStore.remoteURL(for: "notes.assets/photo.png") == nil)
        #expect(store.loadedImage(for: "notes.assets/photo.png") == nil)
    }

    /// Asking to measure an image must never cause a download: the size sheet
    /// calls this while the writer waits, and every keystroke re-renders.
    @Test("Measuring never starts a fetch")
    func measuringDoesNotFetch() {
        let store = RemoteImageStore()
        #expect(store.loadedImage(for: "https://example.com/a.png") == nil)
        #expect(store.loadedImage(for: "https://example.com/a.png") == nil)
    }

    // MARK: - The transfer itself
    //
    // Against a stubbed `URLProtocol`, so the loop that actually bounds the
    // download is exercised. Without these, deleting the ceiling check inside
    // it left the whole suite green.

    @Test("A PNG served over HTTP is downloaded and decoded")
    func downloadsAnImage() async throws {
        let address = "https://example.com/grid.png"
        StubURLProtocol.stub(
            address,
            with: .init(body: Self.fourToOnePNG)
        )
        let image = await RemoteImageStore.download(
            URL(string: address)!,
            using: StubURLProtocol.session()
        )
        #expect(try #require(image).size.width == 400)
    }

    @Test("A 404 is not an image")
    func refusesErrorStatus() async {
        let address = "https://example.com/gone.png"
        StubURLProtocol.stub(
            address,
            with: .init(statusCode: 404, body: Self.fourToOnePNG)
        )
        let image = await RemoteImageStore.download(
            URL(string: address)!,
            using: StubURLProtocol.session()
        )
        #expect(image == nil)
    }

    /// The case that makes checking the decode worth its line: the server says
    /// 200 and sends an error page.
    @Test("An HTML error page returned with a 200 is not an image")
    func refusesHTMLServedAsSuccess() async {
        let address = "https://example.com/oops.png"
        StubURLProtocol.stub(
            address,
            with: .init(body: Data("<html><body>Not found</body></html>".utf8))
        )
        let image = await RemoteImageStore.download(
            URL(string: address)!,
            using: StubURLProtocol.session()
        )
        #expect(image == nil)
    }

    @Test("A declared length over the limit is refused")
    func refusesDeclaredOversize() async {
        let address = "https://example.com/huge.png"
        StubURLProtocol.stub(address, with: .init(body: Self.fourToOnePNG))
        let image = await RemoteImageStore.download(
            URL(string: address)!,
            using: StubURLProtocol.session(),
            limit: Self.fourToOnePNG.count - 1
        )
        #expect(image == nil)
    }

    /// The one that matters: a server that understates its length, or sends
    /// none at all, must not be able to push past the ceiling anyway. Only the
    /// check inside the streaming loop stops this.
    @Test("A body larger than its declared length is still cut off")
    func refusesUndeclaredOversize() async {
        let address = "https://example.com/lying.png"
        StubURLProtocol.stub(
            address,
            with: .init(body: Self.fourToOnePNG, declaredLength: .some(nil))
        )
        let image = await RemoteImageStore.download(
            URL(string: address)!,
            using: StubURLProtocol.session(),
            limit: 32
        )
        #expect(image == nil)
    }

    /// A body of exactly the ceiling is allowed; the check is "over", not
    /// "at". An off-by-one here would refuse a legitimate image.
    @Test("A body of exactly the limit is allowed")
    func allowsExactlyTheLimit() async throws {
        let address = "https://example.com/exact.png"
        StubURLProtocol.stub(
            address,
            with: .init(body: Self.fourToOnePNG, declaredLength: .some(nil))
        )
        let image = await RemoteImageStore.download(
            URL(string: address)!,
            using: StubURLProtocol.session(),
            limit: Self.fourToOnePNG.count
        )
        #expect(try #require(image).size.width == 400)
    }

    @Test("A transport failure is not an image")
    func refusesTransportFailure() async {
        let image = await RemoteImageStore.download(
            URL(string: "https://example.com/never-stubbed.png")!,
            using: StubURLProtocol.session()
        )
        #expect(image == nil)
    }

    // MARK: - The cache, end to end

    /// The whole point of the store: the first ask misses and starts a fetch,
    /// the notification arrives, and the second ask hits.
    @Test("A miss fetches, notifies, and is cached")
    func missFetchesThenHits() async throws {
        let address = "https://example.com/cached.png"
        StubURLProtocol.stub(address, with: .init(body: Self.fourToOnePNG))
        let store = RemoteImageStore(session: StubURLProtocol.session())

        #expect(store.image(for: address) == nil)
        try await Self.waitForImage(store, address)
        #expect(store.image(for: address) != nil)
        // And measuring now works, which is what lets an address be resized.
        #expect(store.loadedImage(for: address) != nil)
    }

    /// A failure has to be remembered, or a mistyped address costs one request
    /// per keystroke for as long as the document is open.
    @Test("A failure is remembered rather than retried")
    func failureIsNotRetried() async throws {
        let address = "https://example.com/broken.png"
        StubURLProtocol.stub(
            address,
            with: .init(statusCode: 500, body: Data())
        )
        let store = RemoteImageStore(session: StubURLProtocol.session())

        #expect(store.image(for: address) == nil)
        // Let the first attempt finish and be recorded.
        try await Task.sleep(nanoseconds: 300_000_000)

        // Now make the address work. A store that retried would pick it up.
        StubURLProtocol.stub(address, with: .init(body: Self.fourToOnePNG))
        #expect(store.image(for: address) == nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(store.image(for: address) == nil)
    }

    private static func waitForImage(
        _ store: RemoteImageStore,
        _ address: String,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if store.loadedImage(for: address) != nil { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for \(address)")
    }

    /// A 400x100 PNG, built by hand so the test does not depend on a fixture
    /// file. Deliberately not square, so a wrong width/height cannot pass.
    static let fourToOnePNG: Data = {
        func chunk(_ type: String, _ payload: Data) -> Data {
            var out = Data()
            out.append(contentsOf: withUnsafeBytes(
                of: UInt32(payload.count).bigEndian
            ) { Data($0) })
            let body = Data(type.utf8) + payload
            out.append(body)
            out.append(contentsOf: withUnsafeBytes(
                of: crc32(body).bigEndian
            ) { Data($0) })
            return out
        }

        func crc32(_ data: Data) -> UInt32 {
            var table = [UInt32](repeating: 0, count: 256)
            for i in 0..<256 {
                var c = UInt32(i)
                for _ in 0..<8 {
                    c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
                }
                table[i] = c
            }
            var c: UInt32 = 0xFFFF_FFFF
            for byte in data {
                c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
            return c ^ 0xFFFF_FFFF
        }

        // zlib stored (uncompressed) deflate blocks, so no compressor is needed.
        func zlibStored(_ raw: Data) -> Data {
            var out = Data([0x78, 0x01])
            var offset = 0
            while offset < raw.count {
                let size = min(65535, raw.count - offset)
                let isLast = offset + size >= raw.count
                out.append(isLast ? 1 : 0)
                out.append(UInt8(size & 0xFF))
                out.append(UInt8((size >> 8) & 0xFF))
                out.append(UInt8(~size & 0xFF))
                out.append(UInt8((~size >> 8) & 0xFF))
                out.append(raw[raw.startIndex + offset..<raw.startIndex + offset + size])
                offset += size
            }
            var s1: UInt32 = 1, s2: UInt32 = 0
            for byte in raw {
                s1 = (s1 + UInt32(byte)) % 65521
                s2 = (s2 + s1) % 65521
            }
            out.append(contentsOf: withUnsafeBytes(
                of: ((s2 << 16) | s1).bigEndian
            ) { Data($0) })
            return out
        }

        let width = 400, height = 100
        var raw = Data()
        for _ in 0..<height {
            raw.append(0)  // filter: none
            raw.append(contentsOf: [UInt8](repeating: 0x40, count: width * 3))
        }

        var header = Data()
        header.append(contentsOf: withUnsafeBytes(
            of: UInt32(width).bigEndian
        ) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(
            of: UInt32(height).bigEndian
        ) { Data($0) })
        header.append(contentsOf: [8, 2, 0, 0, 0])  // 8-bit RGB

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(chunk("IHDR", header))
        png.append(chunk("IDAT", zlibStored(raw)))
        png.append(chunk("IEND", Data()))
        return png
    }()
}
