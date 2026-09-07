import Foundation
import Testing

@testable import MarkdownEditorCore

@Suite("Talking to a model provider")
struct CritiqueProviderTests {
    @Test("Each provider that needs a key says where to get one")
    func keysHaveAnOrigin() {
        for provider in CritiqueProvider.allCases {
            #expect(provider.needsAPIKey == (provider.keyOrigin != nil))
        }
    }

    @Test("The cheap model is the default everywhere")
    func defaultsToTheCheapModel() {
        #expect(CritiqueProvider.openAI.defaultModel == "gpt-4o-mini")
        #expect(CritiqueProvider.anthropic.defaultModel == "claude-3-5-haiku-latest")
        #expect(CritiqueProvider.gemini.defaultModel == "gemini-1.5-flash")
    }

    /// Each provider wants the key in a different place, and getting it wrong
    /// reads as "your key is bad" rather than "the request was malformed".
    @Test("The key goes where each provider expects it")
    func headers() {
        #expect(
            CritiqueProvider.openAI.headers(apiKey: "k")["Authorization"]
                == "Bearer k"
        )
        #expect(CritiqueProvider.anthropic.headers(apiKey: "k")["x-api-key"] == "k")
        #expect(
            CritiqueProvider.anthropic.headers(apiKey: "k")["anthropic-version"]
                == "2023-06-01"
        )
        #expect(CritiqueProvider.gemini.headers(apiKey: "k")["x-goog-api-key"] == "k")
        // The key must not leak into a header the wrong provider reads.
        #expect(CritiqueProvider.openAI.headers(apiKey: "k")["x-api-key"] == nil)
    }

    @Test("Gemini names the model in the URL, the others in the body")
    func endpoints() {
        #expect(
            CritiqueProvider.gemini.endpoint(model: "gemini-1.5-flash")
                .absoluteString
                .hasSuffix("models/gemini-1.5-flash:generateContent")
        )
        #expect(
            CritiqueProvider.openAI.endpoint(model: "anything").absoluteString
                == "https://api.openai.com/v1/chat/completions"
        )
        #expect(
            CritiqueProvider.openAI.body(prompt: "p", model: "m")["model"] as? String
                == "m"
        )
    }

    /// Anthropic rejects a request without it, so its absence is a silent
    /// failure for that provider alone.
    @Test("Anthropic asks for a token ceiling")
    func anthropicNeedsMaxTokens() {
        let body = CritiqueProvider.anthropic.body(prompt: "p", model: "m")
        #expect(body["max_tokens"] as? Int == 4096)
    }

    @Test("The prompt reaches the body in each provider's shape")
    func promptIsCarried() {
        func encoded(_ provider: CritiqueProvider) -> String {
            let body = provider.body(prompt: "CRITIQUE THIS", model: "m")
            let data = try! JSONSerialization.data(withJSONObject: body)
            return String(decoding: data, as: UTF8.self)
        }
        for provider in [CritiqueProvider.openAI, .anthropic, .gemini] {
            #expect(encoded(provider).contains("CRITIQUE THIS"))
        }
    }

    // MARK: - Reading the reply

    @Test("OpenAI's reply")
    func readsOpenAI() throws {
        let json = """
            {"choices":[{"message":{"role":"assistant","content":"the report"}}]}
            """
        #expect(
            try CritiqueProvider.openAI.text(fromReply: Data(json.utf8))
                == "the report"
        )
    }

    @Test("Anthropic's reply, whose text arrives in blocks")
    func readsAnthropic() throws {
        let json = """
            {"content":[{"type":"text","text":"the "},{"type":"text","text":"report"}]}
            """
        #expect(
            try CritiqueProvider.anthropic.text(fromReply: Data(json.utf8))
                == "the report"
        )
    }

    @Test("Gemini's reply, nested two deep")
    func readsGemini() throws {
        let json = """
            {"candidates":[{"content":{"parts":[{"text":"the report"}]}}]}
            """
        #expect(
            try CritiqueProvider.gemini.text(fromReply: Data(json.utf8))
                == "the report"
        )
    }

    /// The three things most likely to happen to somebody setting this up —
    /// a bad key, a model that does not exist, a rate limit — all arrive as a
    /// perfectly well-formed reply with no text in it. Reporting them as "no
    /// content" would hide the one sentence that says what to do.
    @Test("A refusal is reported in the provider's own words")
    func readsAnError() {
        let json = """
            {"error":{"message":"Incorrect API key provided.","type":"invalid_request_error"}}
            """
        for provider in [CritiqueProvider.openAI, .anthropic, .gemini] {
            #expect(throws: CritiqueProvider.ReplyProblem.refused(
                "Incorrect API key provided."
            )) {
                try provider.text(fromReply: Data(json.utf8))
            }
        }
    }

    @Test("A reply that is not JSON says so")
    func rejectsNonJSON() {
        #expect(throws: CritiqueProvider.ReplyProblem.notJSON) {
            try CritiqueProvider.openAI.text(fromReply: Data("<html>".utf8))
        }
    }

    @Test("A well-formed reply with nothing in it is not silently empty")
    func rejectsEmpty() {
        #expect(throws: (any Error).self) {
            try CritiqueProvider.openAI.text(fromReply: Data("{\"choices\":[]}".utf8))
        }
    }

    @Test("Each provider remembers its own model choice")
    func modelKeysAreDistinct() {
        let keys = Set(CritiqueProvider.allCases.map(\.modelStorageKey))
        #expect(keys.count == CritiqueProvider.allCases.count)
    }
}
