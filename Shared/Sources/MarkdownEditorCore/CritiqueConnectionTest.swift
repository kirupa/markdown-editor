import Foundation

/// Checking that a critique could actually be run, before asking for one.
///
/// A critique takes the better part of a minute and spends real money, and
/// until it fails there is no way to tell a mistyped key from a model name the
/// account cannot reach from a network that is simply down. All three arrive as
/// the same shrug at the end of a long wait.
///
/// So the test is a real request, on the real path, with the real key — the
/// smallest one that still proves every link: the endpoint resolves, the key is
/// accepted, the named model exists and will answer. Anything less checks
/// something other than the thing that was in doubt. A key that merely *looks*
/// like a key, for instance, is not evidence of anything; that is string
/// length, not a connection.
public enum CritiqueConnectionTest {
    /// The smallest prompt that proves a model answered.
    ///
    /// Asking for one word keeps the reply — and the bill — as close to nothing
    /// as a real request can be, while still being a completion rather than a
    /// handshake.
    public static let prompt = """
        Reply with the single word: OK
        """

    public enum Outcome: Equatable, Sendable {
        case passed(detail: String)
        case failed(detail: String)

        public var didPass: Bool {
            if case .passed = self { return true }
            return false
        }

        public var detail: String {
            switch self {
            case .passed(let detail), .failed(let detail): return detail
            }
        }
    }

    /// What a reply means.
    ///
    /// Deliberately not "does it say OK". A model that answers "Ok." or "OK!"
    /// or "Sure — OK" has proved everything the test set out to prove, and
    /// failing it for punctuation would report a broken connection to somebody
    /// whose connection is fine. The question is whether anything came back at
    /// all.
    public static func interpret(
        reply: String,
        provider: String,
        model: String
    ) -> Outcome {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failed(
                detail: "\(provider) accepted the request but sent nothing back."
            )
        }
        let named = model.isEmpty ? provider : "\(provider) · \(model)"
        return .passed(detail: "\(named) answered.")
    }

    /// How to describe a request that never got a reply.
    ///
    /// The provider's own words, unchanged. A bad key, a model the account
    /// cannot reach and a rate limit are the three things most likely to be
    /// wrong here, and all three arrive as a sentence from the provider that
    /// says which — so putting our own wording in front of it would replace the
    /// useful part with a guess.
    public static func failure(_ description: String) -> Outcome {
        .failed(detail: description)
    }
}
