import Foundation
import Testing

@testable import MarkdownEditorCore

/// Reading findings out of a report that has not finished arriving.
@Suite("Critique finding stream")
struct CritiqueFindingStreamTests {
    private static let report = #"""
        Here is the critique.

        ```json
        {
          "jobRead": "A post for {curious} beginners",
          "overall": "Clear, with a slow start. The \"findings\" below say where.",
          "whatWorks": ["The example", "The [closing] line"],
          "whatDoesNotWork": ["The opening"],
          "findings": [
            {"severity": "high", "category": "Opening", "location": "Paragraph 1",
             "quote": "In today's world", "why": "A stock opener.",
             "fix": "Start with the example.", "replacement": "Pages feel slow"},
            {"severity": "medium", "category": "Code", "location": "Paragraph 3",
             "quote": "if (x) { return [y]; }", "why": "Braces } and ] in a \"quote\"."},
            {"severity": "low", "category": "Mechanics", "location": "Paragraph 5",
             "quote": "its", "why": "Should be it's.", "nested": {"a": [1, {"b": 2}]}}
          ],
          "repeatedPatterns": [{"pattern": "Hedging", "locations": ["P2"]}],
          "keep": ["The last line"],
          "previous": [{"id": "n1", "status": "fixed", "quote": "x", "why": "y"}]
        }
        ```
        """#

    @Test("Findings arrive one at a time, however the reply is cut up")
    func findingsArriveAsTheyAreFinished() throws {
        for size in [1, 2, 3, 7, 64, 4096] {
            var stream = CritiqueFindingStream()
            var counts: [Int] = []
            var chunk = ""
            for character in Self.report {
                chunk.append(character)
                if chunk.count == size {
                    stream.append(chunk)
                    counts.append(stream.findings.count)
                    chunk = ""
                }
            }
            stream.append(chunk)
            #expect(stream.findings.map(\.category) == ["Opening", "Code", "Mechanics"], "size \(size)")
            // A piece shorter than a finding cannot finish two of them.
            if size < 50 {
                let steps = zip(counts, counts.dropFirst()).map { $1 - $0 }
                #expect(steps.allSatisfy { $0 <= 1 }, "size \(size)")
            }
        }
    }

    @Test("A note shown early is the note the report holds")
    func streamedFindingsMatchTheDecodedReport() throws {
        var stream = CritiqueFindingStream()
        stream.append(Self.report)
        let decoded = try CritiqueReportDecoder.decode(Self.report).findings
        #expect(decoded.count == stream.findings.count)
        for (early, late) in zip(stream.findings, decoded) {
            #expect(late.identified(as: early.id) == early)
        }
        #expect(stream.findings[1].quote == "if (x) { return [y]; }")
        #expect(stream.findings[1].why == #"Braces } and ] in a "quote"."#)
    }

    @Test("Half a finding is not a finding")
    func anUnfinishedFindingIsHeldBack() {
        var stream = CritiqueFindingStream()
        let cut = Self.report.range(of: "Start with the example")!.lowerBound
        #expect(stream.append(String(Self.report[..<cut])) == false)
        #expect(stream.findings.isEmpty)
        #expect(stream.append(String(Self.report[cut...])) == true)
        #expect(stream.findings.count == 3)
    }

    @Test("Only the report's own findings are read")
    func objectsElsewhereAreNotFindings() {
        // Patterns and verdicts on earlier notes are objects in arrays too,
        // and a verdict has a quote and a why. Neither is a new note.
        var stream = CritiqueFindingStream()
        stream.append(#"{"whatWorks": [{"quote": "a", "why": "b"}], "findings": [], "previous": [{"quote": "c", "why": "d"}]}"#)
        #expect(stream.findings.isEmpty)
    }

    @Test("A key that only says findings inside a string opens nothing")
    func theWordInAStringIsNotTheKey() {
        var stream = CritiqueFindingStream()
        stream.append(#"{"overall": "findings", "whatWorks": [{"quote": "a", "why": "b"}]}"#)
        #expect(stream.findings.isEmpty)
    }

    @Test("The CLI's result event carries its exit code")
    func theResultEventIsRead() {
        var reader = CritiqueProgressReader()
        #expect(reader.exitCode == nil)
        #expect(reader.read(line: #"{"type":"result","exitCode":0,"usage":{"premiumRequests":1}}"#) == nil)
        #expect(reader.exitCode == 0)
        var failed = CritiqueProgressReader()
        _ = failed.read(line: #"{"type":"result","exitCode":2}"#)
        #expect(failed.exitCode == 2)
    }

    @Test("Progress carries each finding as it is finished")
    func progressCarriesFindings() throws {
        var reader = CritiqueProgressReader()
        var seen: [Int] = []
        for character in Self.report {
            let line = String(
                decoding: try JSONSerialization.data(withJSONObject: [
                    "type": "assistant.message_delta",
                    "data": ["deltaContent": String(character)],
                ]),
                as: UTF8.self
            )
            if let update = reader.read(line: line), seen.last != update.findings.count {
                seen.append(update.findings.count)
            }
        }
        #expect(seen == [0, 1, 2, 3])
        #expect(reader.reply == Self.report)
    }
}
