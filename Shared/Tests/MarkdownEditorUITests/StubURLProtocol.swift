import Foundation

/// A canned HTTP server for `URLSession`, so the download path can be tested
/// without a network.
///
/// It exists because the interesting rules — the status code, the size ceiling
/// enforced while streaming, and bytes that are not an image — all live inside
/// the transfer. Testing only the pure helpers around it would leave the loop
/// that actually bounds the download unexercised, which a mutation run proved:
/// deleting the ceiling check kept every test green.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var statusCode = 200
        var body = Data()
        /// What to put in `Content-Length`. `nil` sends none, which is the
        /// case a real server produces with chunked encoding.
        var declaredLength: Int?

        init(statusCode: Int = 200, body: Data, declaredLength: Int?? = nil) {
            self.statusCode = statusCode
            self.body = body
            // Default: declare the truth. Pass `.some(nil)` for no header, or
            // `.some(n)` to declare a length that differs from the body.
            self.declaredLength = declaredLength ?? body.count
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Response] = [:]

    /// Registers a canned response for one exact URL.
    ///
    /// There is deliberately no `reset`. Swift Testing runs the tests in a
    /// suite in parallel, so clearing a shared table wipes stubs another test
    /// has just registered — which is precisely how the first version of this
    /// file failed. Every test uses a URL of its own instead.
    static func stub(_ url: String, with response: Response) {
        lock.lock()
        defer { lock.unlock() }
        responses[url] = response
    }

    private static func response(for url: URL?) -> Response? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = url?.absoluteString else { return nil }
        return responses[key]
    }

    /// A session wired to this protocol. `ephemeral` so nothing is cached
    /// between tests.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let stub = Self.response(for: url) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL)
            )
            return
        }

        var headers: [String: String] = [:]
        if let length = stub.declaredLength {
            headers["Content-Length"] = String(length)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
