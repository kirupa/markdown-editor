import Foundation
import Testing

@testable import MarkdownEditorCore

@Suite("Testing the connection")
struct CritiqueConnectionTestTests {
    @Test("Any real reply passes, whatever its punctuation")
    func anyReplyPasses() {
        // Not "does it say OK". A model that answers "Ok." or "Sure — OK" has
        // proved everything the test set out to prove, and failing it for
        // punctuation reports a broken connection to somebody whose connection
        // is fine.
        for reply in ["OK", "Ok.", "OK!", "Sure — OK", "okay"] {
            #expect(
                CritiqueConnectionTest.interpret(
                    reply: reply, provider: "OpenAI", model: "gpt-4o-mini"
                ).didPass,
                "\(reply) should pass"
            )
        }
    }

    @Test("An empty reply fails, and says which link held")
    func emptyReplyFails() {
        let outcome = CritiqueConnectionTest.interpret(
            reply: "   \n ", provider: "OpenAI", model: "gpt-4o-mini"
        )
        #expect(!outcome.didPass)
        // The distinction matters: the key was accepted and the request
        // completed, so the thing to look at is the model, not the key.
        #expect(outcome.detail.contains("accepted the request"))
    }

    @Test("A passing result names the provider and model")
    func passNamesWhatAnswered() {
        let outcome = CritiqueConnectionTest.interpret(
            reply: "OK", provider: "OpenAI", model: "gpt-4o-mini"
        )
        #expect(outcome.detail.contains("OpenAI"))
        #expect(outcome.detail.contains("gpt-4o-mini"))
    }

    @Test("With no model to name, the provider alone is named")
    func passWithoutAModel() {
        let outcome = CritiqueConnectionTest.interpret(
            reply: "OK", provider: "Built in · no API key", model: ""
        )
        #expect(outcome.didPass)
        #expect(!outcome.detail.contains("·  "))
    }

    @Test("A failure is reported in the provider's own words")
    func failureIsVerbatim() {
        // A bad key, an unreachable model and a rate limit all arrive as a
        // sentence saying which. Putting our wording in front replaces the
        // useful part with a guess.
        let outcome = CritiqueConnectionTest.failure(
            "Incorrect API key provided: sk-abc***."
        )
        #expect(!outcome.didPass)
        #expect(outcome.detail == "Incorrect API key provided: sk-abc***.")
    }

    @Test("The probe asks for one word")
    func probeIsSmall() {
        // It is a real request on the real path, so it should cost as close to
        // nothing as a real request can.
        #expect(CritiqueConnectionTest.prompt.count < 60)
        #expect(CritiqueConnectionTest.prompt.contains("OK"))
    }
}
