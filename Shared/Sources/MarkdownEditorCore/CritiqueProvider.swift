import Foundation

/// Where a critique comes from.
///
/// The Copilot CLI was the only source, and it is a good one — it already holds
/// a sign-in, already knows where the skills live, and needs no key. What it
/// cannot do is run on a machine that has not installed it, which made the
/// feature unavailable to anyone unwilling to take an npm dependency for it.
///
/// The three model APIs need a key and nothing else.
public enum CritiqueProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI
    case anthropic
    case gemini
    case copilotCLI

    public static let storageKey = "critiqueProvider"

    public var id: Self { self }

    public var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .copilotCLI: return "GitHub Copilot CLI"
        }
    }

    /// Whether this one needs an API key from the reader.
    public var needsAPIKey: Bool { self != .copilotCLI }

    /// Where to get a key, said plainly, because "enter your API key" is not
    /// help if you do not already know where they live.
    public var keyOrigin: String? {
        switch self {
        case .openAI: return "platform.openai.com/api-keys"
        case .anthropic: return "console.anthropic.com/settings/keys"
        case .gemini: return "aistudio.google.com/apikey"
        case .copilotCLI: return nil
        }
    }

    /// The models offered, cheapest first.
    ///
    /// A critique is one request returning a page of JSON. It wants a model
    /// that follows a schema and reads carefully; it does not want the
    /// reasoning tier, which costs many times more for work that is not much
    /// better at this. So the small model is the default in each family and
    /// the larger one is there for anyone who disagrees.
    public var models: [String] {
        switch self {
        case .openAI: return ["gpt-4o-mini", "gpt-4o"]
        case .anthropic:
            return ["claude-3-5-haiku-latest", "claude-3-5-sonnet-latest"]
        case .gemini: return ["gemini-1.5-flash", "gemini-1.5-pro"]
        case .copilotCLI: return []
        }
    }

    public var defaultModel: String { models.first ?? "" }

    /// The key defaults are remembered under, one per provider, so switching
    /// back and forth does not lose the other's choice.
    public var modelStorageKey: String { "critiqueModel.\(rawValue)" }

    // MARK: - The request

    public func endpoint(model: String) -> URL {
        switch self {
        case .openAI:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .anthropic:
            return URL(string: "https://api.anthropic.com/v1/messages")!
        case .gemini:
            return URL(
                string: "https://generativelanguage.googleapis.com/v1beta/models/"
                    + "\(model):generateContent"
            )!
        case .copilotCLI:
            return URL(string: "about:blank")!
        }
    }

    /// Headers, with the key where each provider expects it.
    ///
    /// They disagree: OpenAI wants a bearer token, Anthropic a bare header plus
    /// a dated version, Google a header of its own. Getting one wrong reads as
    /// an authentication failure rather than a mistake in the request, so each
    /// is stated here once and checked.
    public func headers(apiKey: String) -> [String: String] {
        switch self {
        case .openAI:
            return [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(apiKey)",
            ]
        case .anthropic:
            return [
                "Content-Type": "application/json",
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ]
        case .gemini:
            return [
                "Content-Type": "application/json",
                "x-goog-api-key": apiKey,
            ]
        case .copilotCLI:
            return [:]
        }
    }

    /// The body, as each provider's shape of the same request.
    public func body(prompt: String, model: String) -> [String: Any] {
        switch self {
        case .openAI:
            return [
                "model": model,
                "messages": [["role": "user", "content": prompt]],
                // Low, not zero: the critique is a judgement, and a model
                // pinned to zero repeats the same three observations about
                // every draft.
                "temperature": 0.2,
            ]
        case .anthropic:
            return [
                "model": model,
                // Required by this API, unlike the other two. A critique of a
                // long draft runs to a few thousand tokens of JSON.
                "max_tokens": 4096,
                "temperature": 0.2,
                "messages": [["role": "user", "content": prompt]],
            ]
        case .gemini:
            return [
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": ["temperature": 0.2],
            ]
        case .copilotCLI:
            return [:]
        }
    }

    // MARK: - The reply

    public enum ReplyProblem: LocalizedError, Equatable {
        case notJSON
        case noContent(String)
        case refused(String)

        public var errorDescription: String? {
            switch self {
            case .notJSON:
                return "The provider's reply was not JSON."
            case .noContent:
                return "The provider's reply contained no text."
            case .refused(let message):
                return message
            }
        }
    }

    /// The model's text, dug out of whichever envelope it arrived in.
    ///
    /// An error in the envelope is reported as itself rather than as "no
    /// content": a bad key, a model name that does not exist and a rate limit
    /// all come back as a perfectly well-formed reply with no text in it, and
    /// those are the three things most likely to happen to somebody setting
    /// this up.
    public func text(fromReply data: Data) throws -> String {
        guard let top = try? JSONSerialization.jsonObject(with: data),
              let object = top as? [String: Any]
        else { throw ReplyProblem.notJSON }

        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String)
                ?? "The provider rejected the request."
            throw ReplyProblem.refused(message)
        }

        switch self {
        case .openAI:
            let choices = object["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            guard let content = message?["content"] as? String, !content.isEmpty
            else { throw ReplyProblem.noContent(brief(data)) }
            return content
        case .anthropic:
            let blocks = object["content"] as? [[String: Any]]
            let text = blocks?
                .compactMap { $0["text"] as? String }
                .joined()
            guard let text, !text.isEmpty
            else { throw ReplyProblem.noContent(brief(data)) }
            return text
        case .gemini:
            let candidates = object["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]]
            let text = parts?
                .compactMap { $0["text"] as? String }
                .joined()
            guard let text, !text.isEmpty
            else { throw ReplyProblem.noContent(brief(data)) }
            return text
        case .copilotCLI:
            throw ReplyProblem.notJSON
        }
    }

    private func brief(_ data: Data) -> String {
        String(decoding: data.prefix(400), as: UTF8.self)
    }
}
