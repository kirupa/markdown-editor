import Foundation
import Testing

@testable import MarkdownEditorCore

/// Reading a critique out of a language model's reply.
///
/// Everything here is about being suspicious of the input. The reply is text
/// produced by a model that was *asked* for clean JSON, which is not the same
/// as being given it, and a report that is mostly right is worth far more to
/// the author than an error message.
@Suite("Critique report decoding")
struct CritiqueReportDecoderTests {
    private let minimal = """
        {"jobRead":"A short explainer.","overall":"Clear but generic.",
         "findings":[{"severity":"high","category":"Logic and credibility",
         "needsVerification":true,"location":"paragraph 3",
         "quote":"improves performance by 90%","why":"No citation.",
         "fix":"","direction":"Cite the study."}],
         "repeatedPatterns":[{"pattern":"Stock phrasing","locations":["paragraph 1","paragraph 4"]}],
         "keep":["The definition is correct."]}
        """

    @Test("A clean reply decodes whole")
    func decodesEveryPart() throws {
        let report = try CritiqueReportDecoder.decode(minimal)
        #expect(report.jobRead == "A short explainer.")
        #expect(report.overall == "Clear but generic.")
        #expect(report.findings.count == 1)
        #expect(report.repeatedPatterns.count == 1)
        #expect(report.keep == ["The definition is correct."])

        let finding = try #require(report.findings.first)
        #expect(finding.severity == .high)
        #expect(finding.category == "Logic and credibility")
        #expect(finding.needsVerification)
        #expect(finding.quote == "improves performance by 90%")
        #expect(finding.advice == "Cite the study.")
        // An empty `fix` means the advice is a direction, not a correction.
        #expect(finding.adviceLabel == "Direction")
    }

    @Test("A fenced reply decodes, because models fence JSON")
    func decodesThroughACodeFence() throws {
        let fenced = "Here is the critique:\n\n```json\n\(minimal)\n```\n\nLet me know."
        let report = try CritiqueReportDecoder.decode(fenced)
        #expect(report.findings.count == 1)
    }

    @Test("A brace inside a quote does not truncate the report")
    func bracesInsideStringsAreNotStructure() throws {
        // A draft about code will quote braces. Counting them without minding
        // string literals ends the object early and silently drops every
        // finding after this one, which is the worst kind of wrong: a shorter
        // report that still looks like a report.
        let awkward = """
            {"jobRead":"","overall":"","findings":[
              {"severity":"low","category":"Clarity and precision","location":"paragraph 1",
               "quote":"if (x) { return; }","why":"Unexplained."},
              {"severity":"high","category":"Grammar and mechanics","location":"paragraph 2",
               "quote":"it own tradeoffs","why":"Possessive."}],
             "repeatedPatterns":[],"keep":[]}
            """
        let report = try CritiqueReportDecoder.decode(awkward)
        #expect(report.findings.count == 2)
        #expect(report.findings.last?.quote == "it own tradeoffs")
    }

    @Test("An escaped quote mark inside a string is not the end of it")
    func escapedQuotesAreNotStructure() throws {
        let escaped = #"""
            {"jobRead":"","overall":"","findings":[
              {"severity":"medium","category":"Voice and tone","location":"paragraph 1",
               "quote":"she said \"hello\" twice","why":"Repetitive."}],
             "repeatedPatterns":[],"keep":[]}
            """#
        let report = try CritiqueReportDecoder.decode(escaped)
        #expect(report.findings.first?.quote == #"she said "hello" twice"#)
    }

    @Test("An unfamiliar severity is not a reason to lose the finding")
    func severityIsReadForgivingly() {
        #expect(CritiqueSeverity.parse("High") == .high)
        #expect(CritiqueSeverity.parse("CRITICAL") == .high)
        #expect(CritiqueSeverity.parse("nit") == .low)
        #expect(CritiqueSeverity.parse("moderate") == .medium)
        #expect(CritiqueSeverity.parse(nil) == .medium)
    }

    @Test("Missing fields degrade rather than fail")
    func missingFieldsAreTolerated() throws {
        let sparse = """
            {"findings":[{"quote":"a passage","why":"a reason"}]}
            """
        let report = try CritiqueReportDecoder.decode(sparse)
        #expect(report.findings.count == 1)
        #expect(report.findings.first?.severity == .medium)
        #expect(report.findings.first?.category == "Note")
        #expect(report.jobRead.isEmpty)
    }

    @Test("A finding with nothing to say is dropped")
    func emptyFindingsAreNotShown() throws {
        let padded = """
            {"findings":[{"quote":"","why":""},{"quote":"real","why":"reason"}]}
            """
        let report = try CritiqueReportDecoder.decode(padded)
        #expect(report.findings.count == 1)
    }

    @Test("A reply with no JSON in it says so")
    func aReplyWithoutJSONFails() {
        #expect(throws: CritiqueReportDecoder.Failure.noJSONFound) {
            try CritiqueReportDecoder.decode("I could not read the draft.")
        }
    }

    @Test("A reply with broken JSON says that instead")
    func brokenJSONIsDistinguishable() {
        #expect(throws: (any Error).self) {
            try CritiqueReportDecoder.decode("{\"findings\": [,,] }")
        }
    }

    @Test("The real reply from the skill decodes")
    func decodesAnActualReply() throws {
        // Captured verbatim from `copilot -p` running the konvo critique pass,
        // trimmed to two findings. A fixture from the real thing is worth more
        // than one written to match the parser.
        let actual = """
            ● skill(konvo)

            ```json
            {"jobRead":"Reads as a short generic explainer aimed at a broad developer audience.","overall":"The definition is accurate, but the piece leans on stock phrasing.","findings":[{"severity":"high","category":"Logic and credibility","needsVerification":true,"location":"paragraph 3","quote":"Studies show that caching improves performance by 90%.","why":"A specific, quantified claim with no citation reads as fabricated.","fix":"","direction":"Cite the actual study, or drop the number."},{"severity":"medium","category":"Grammar and mechanics","needsVerification":false,"location":"paragraph 3","quote":"each one has it own tradeoffs","why":"Possessive pronoun error.","fix":"Change to \\"each one has its own tradeoffs.\\"","direction":""}],"repeatedPatterns":[{"pattern":"Vague claims stated as fact","locations":["paragraph 1","paragraph 3"]}],"keep":["The core definition is technically correct."]}
            ```

            Changes    +0 -0
            AI Credits 18.47 (32s)
            """
        let report = try CritiqueReportDecoder.decode(actual)
        #expect(report.findings.count == 2)
        #expect(report.findings.first?.severity == .high)
        #expect(report.findings.first?.needsVerification == true)
        #expect(report.findings.last?.adviceLabel == "Fix")
        #expect(report.keep.count == 1)
    }
}
