import Foundation
import Testing
@testable import MarkdownEditorContract

/// Keeps the committed fixtures honest.
///
/// The fixtures are only worth anything if they say what the code currently
/// does. Nothing stops someone changing a formatting command and not
/// regenerating them — except this, which regenerates and compares, so the
/// suite fails instead of the fixtures quietly describing an older editor.
@Suite("Cross-platform contract")
struct ContractFixturesTests {
    /// The repository root, found from this file rather than the working
    /// directory, which differs between `swift test` and Xcode.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MarkdownEditorContractTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Shared
            .deletingLastPathComponent() // repository root
    }

    @Test("The committed fixtures match what the code produces now")
    func committedFixturesAreCurrent() throws {
        let directory = Self.repositoryRoot.appendingPathComponent("Contract")

        for (name, expected) in try ContractFixtures.files() {
            let url = directory.appendingPathComponent(name)
            let committed = try #require(
                try? Data(contentsOf: url),
                "Contract/\(name) is missing. Run: swift run --package-path Shared markdown-contract Contract"
            )
            #expect(
                committed == expected,
                "Contract/\(name) is out of date. Run: swift run --package-path Shared markdown-contract Contract"
            )
        }
    }

    @Test("Every formatting case reproduces its document when applied")
    func formattingCasesApplyCleanly() throws {
        let fixture = ContractFixtures.formatting()
        let documents = Dictionary(
            uniqueKeysWithValues: fixture.header.documents.map { ($0.id, $0.text) }
        )

        for testCase in fixture.cases {
            let source = try #require(documents[testCase.document]) as NSString
            let range = NSRange(location: testCase.replace[0], length: testCase.replace[1])
            // The edit has to be applicable: a range past the end, or one that
            // splits a surrogate pair, would make the fixture unusable by the
            // very ports it exists for.
            #expect(range.location >= 0)
            #expect(NSMaxRange(range) <= source.length)

            let produced = source.replacingCharacters(in: range, with: testCase.with)
            let expected = ContractFixtures.Command.all
                .first { $0.name == testCase.command && $0.argument == testCase.argument }
                .map { $0.apply(source as String, NSRange(location: testCase.selection[0], length: testCase.selection[1])) }
            #expect(produced == expected?.text)
        }
    }

    @Test("The minimal edit round-trips, including across a surrogate pair")
    func minimalEditRoundTrips() {
        let pairs = [
            ("", ""),
            ("abc", "abc"),
            ("abc", "aXc"),
            ("abc", ""),
            ("", "abc"),
            ("a😀b", "a😀Xb"),
            // Removing the emoji: the common prefix ends mid-pair unless the
            // edit backs off, and a fixture that split it could not be encoded.
            ("a😀b", "ab"),
            ("😀😀", "😀"),
            ("line\r\nline", "line\nline"),
        ]

        for (before, after) in pairs {
            let edit = ContractFixtures.minimalEdit(from: before, to: after)
            let applied = (before as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            #expect(applied == after, "\(before) -> \(after)")
        }
    }

    @Test("The corpus covers the constructs a port gets wrong")
    func corpusCoversTheHardParts() {
        let all = ContractCorpus.documents.map(\.text).joined(separator: "\n")
        // Not thoroughness for its own sake: each of these is a rule a
        // reimplementation has actually been seen to get wrong.
        #expect(all.contains("snake_case_stays_plain"))
        #expect(all.contains("``a `tick` inside``"))
        #expect(all.contains("- [x]"))
        #expect(all.contains("7. seven"))
        #expect(all.contains("\r\n"))
        #expect(all.contains("😀"))
        #expect(all.contains("\\*not italic\\*"))
        // Every document reachable by id, so a fixture case can always resolve.
        #expect(Set(ContractCorpus.documents.map(\.id)).count == ContractCorpus.documents.count)
    }

    @Test("Every command in the editor appears in the fixture")
    func fixtureCoversEveryCommand() {
        let names = Set(ContractFixtures.Command.all.map { "\($0.name)/\($0.argument ?? "")" })
        // 5 inline styles, 7 heading levels including "none", 3 list styles,
        // and 5 standalone commands.
        #expect(names.count == 20)
    }
}
