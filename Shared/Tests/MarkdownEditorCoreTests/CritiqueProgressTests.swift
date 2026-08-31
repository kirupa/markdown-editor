import Foundation
import Testing

@testable import MarkdownEditorCore

/// Turning the CLI's event stream into something worth watching.
///
/// The point of all this is that half a minute of spinner reads as a hang. The
/// fixtures below are shaped exactly like the real stream, which was captured
/// from a live run and measured: four stages, the long one being the report
/// being written.
@Suite("Critique progress")
struct CritiqueProgressTests {
    private func event(_ type: String, _ data: [String: Any]) -> String {
        let object: [String: Any] = ["type": type, "data": data]
        return String(
            decoding: try! JSONSerialization.data(withJSONObject: object),
            as: UTF8.self
        )
    }

    @Test("Loading the skill is announced as its own stage")
    func theSkillStageIsRecognised() {
        var reader = CritiqueProgressReader()
        let update = reader.read(
            line: event(
                "tool.execution_start",
                ["toolName": "skill", "arguments": ["skill": "konvo"]]
            )
        )
        #expect(update?.stage == .loadingSkill)
        #expect(update?.detail == "konvo")
    }

    @Test("Another tool is not mistaken for the skill")
    func onlyTheSkillToolMovesToThatStage() {
        var reader = CritiqueProgressReader()
        #expect(reader.read(line: event("tool.execution_start", ["toolName": "view"])) == nil)
        #expect(reader.stage == .starting)
    }

    @Test("Reasoning moves to reading, and carries the model's own commentary")
    func reasoningBecomesTheDetail() {
        var reader = CritiqueProgressReader()
        // Reasoning arrives a few characters at a time, so the last thing said
        // has to be assembled rather than read off one delta.
        for piece in ["The opening", " paragraph leans on stock", " phrasing.", " Paragraph two is vaguer stil"] {
            _ = reader.read(line: event("assistant.reasoning_delta", ["deltaContent": piece]))
        }
        #expect(reader.stage == .reading)
        let detail = try? #require(reader.detail)
        #expect(detail?.contains("Paragraph two is vaguer stil") == true)
    }

    @Test("A half-written word is not shown as a finished thought")
    func onlyCompletedSentencesAreShown() {
        // Showing the raw tail flickers a character at a time. The last thing
        // the model actually finished saying reads as a commentary.
        var reader = CritiqueProgressReader()
        _ = reader.read(
            line: event("assistant.reasoning_delta", ["deltaContent": "The draft never grounds its claims. Par"])
        )
        #expect(reader.detail?.hasPrefix("The draft never grounds its claims") == true)
        #expect(reader.detail?.contains("Par…") == false)
    }

    @Test("The report is assembled from the stream, and counted as it arrives")
    func findingsAreCountedWhileTheyStream() {
        // There is no point at which half a JSON object is valid JSON, so the
        // count comes from the keys rather than from parsing.
        var reader = CritiqueProgressReader()
        _ = reader.read(line: event("assistant.message_start", [:]))
        #expect(reader.stage == .writing)
        #expect(reader.findingCount == 0)

        _ = reader.read(
            line: event("assistant.message_delta", ["deltaContent": #"{"findings":[{"severity":"high""#])
        )
        #expect(reader.findingCount == 1)

        _ = reader.read(
            line: event("assistant.message_delta", ["deltaContent": #","quote":"a"},{"severity":"low""#])
        )
        #expect(reader.findingCount == 2)
        #expect(reader.reply.hasPrefix(#"{"findings""#))
    }

    @Test("An update is only reported when something changed")
    func repeatedDeltasDoNotChurnTheView() {
        var reader = CritiqueProgressReader()
        _ = reader.read(line: event("assistant.message_start", [:]))
        // Report text with no new finding in it changes nothing worth showing.
        let first = reader.read(line: event("assistant.message_delta", ["deltaContent": "\"jobRead\":\"a"]))
        let second = reader.read(line: event("assistant.message_delta", ["deltaContent": " reader\""]))
        #expect(first == nil)
        #expect(second == nil)
    }

    @Test("An unknown event, or a line that is not JSON, is skipped")
    func theStreamIsNotAContractThisAppControls() {
        var reader = CritiqueProgressReader()
        #expect(reader.read(line: "not json at all") == nil)
        #expect(reader.read(line: "") == nil)
        #expect(reader.read(line: event("session.something_new", ["a": 1])) == nil)
        #expect(reader.stage == .starting)
    }

    @Test("Every stage says what it is and why it takes the time it does")
    func everyStageIsExplained() {
        for stage in CritiqueProgress.Stage.allCases {
            #expect(!stage.headline.isEmpty)
            #expect(!stage.explanation.isEmpty)
        }
        // Ordered, because the view fills a bar by comparing them.
        #expect(
            CritiqueProgress.Stage.allCases.map(\.rawValue) == [0, 1, 2, 3]
        )
    }

    @Test("A whole run reaches the end with the report intact")
    func aFullRunAssemblesADecodableReport() throws {
        var reader = CritiqueProgressReader()
        let lines = [
            event("session.skills_loaded", [:]),
            event("tool.execution_start", ["toolName": "skill", "arguments": ["skill": "konvo"]]),
            event("assistant.reasoning_delta", ["deltaContent": "Reading the whole thing first."]),
            event("assistant.message_start", [:]),
            event("assistant.message_delta", ["deltaContent": "```json\n{\"jobRead\":\"A note.\","]),
            event("assistant.message_delta", ["deltaContent": "\"overall\":\"Fine.\",\"findings\":[{"]),
            event("assistant.message_delta", ["deltaContent": "\"severity\":\"high\",\"category\":\"Logic and credibility\","]),
            event("assistant.message_delta", ["deltaContent": "\"quote\":\"a claim\",\"why\":\"No source.\"}]}\n```"]),
            event("result", [:]),
        ]
        for line in lines { _ = reader.read(line: line) }

        #expect(reader.stage == .writing)
        #expect(reader.findingCount == 1)
        let report = try CritiqueReportDecoder.decode(reader.reply)
        #expect(report.findings.count == 1)
        #expect(report.jobRead == "A note.")
    }
}
