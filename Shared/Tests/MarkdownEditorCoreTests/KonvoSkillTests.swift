import Foundation
import Testing

@testable import MarkdownEditorCore

@Suite("Which konvo skill is loaded")
struct KonvoSkillTests {
    @Test("A normal git log is read into a version")
    func readsAVersion() {
        let installed = try! #require(
            KonvoSkill.parse(
                log: "0e2be86\n2026-08-31T12:02:00-07:00\nMerge pull request #3",
                status: ""
            )
        )
        #expect(installed.commit == "0e2be86")
        #expect(installed.subject == "Merge pull request #3")
        #expect(installed.isModified == false)
        #expect(installed.date != nil)
    }

    @Test("A dirty checkout is reported as edited")
    func noticesLocalEdits() {
        let installed = try! #require(
            KonvoSkill.parse(
                log: "0e2be86\n2026-08-31T12:02:00-07:00\nSomething",
                status: " M SKILL.md\n"
            )
        )
        #expect(installed.isModified)
        // And it is said in the summary, because an update will refuse rather
        // than discard the edits and "the button did nothing" is a worse
        // answer than knowing why.
        #expect(KonvoSkill.summary(for: installed).contains("edited locally"))
    }

    @Test("A subject with its own newline is not truncated")
    func rejoinsAMultilineSubject() {
        // `%s` is one line in practice, but a commit message is arbitrary text
        // and taking only the third line would silently drop the rest.
        let installed = try! #require(
            KonvoSkill.parse(
                log: "abc1234\n2026-08-31T12:02:00-07:00\nFirst part\nsecond part",
                status: ""
            )
        )
        #expect(installed.subject == "First part second part")
    }

    @Test("Empty or truncated git output is not a version")
    func refusesRubbish() {
        #expect(KonvoSkill.parse(log: "", status: "") == nil)
        #expect(KonvoSkill.parse(log: "abc1234", status: "") == nil)
        #expect(KonvoSkill.parse(log: "\n\n", status: "") == nil)
    }

    @Test("A commit with no parseable date still gives a version")
    func survivesAnUnreadableDate() {
        // The commit is the version; the date is decoration. Losing the date
        // must not lose the identity.
        let installed = try! #require(
            KonvoSkill.parse(log: "abc1234\nnot-a-date\nSubject", status: "")
        )
        #expect(installed.commit == "abc1234")
        #expect(installed.date == nil)
        #expect(KonvoSkill.summary(for: installed) == "abc1234")
    }

    // MARK: - Updating

    @Test("Git's own phrasing is translated")
    func alreadyCurrent() {
        // A button that says nothing after being pressed reads as a button
        // that did not work.
        #expect(
            KonvoSkill.interpretPull(
                output: "Already up to date.\n", exitCode: 0, commitAfter: "0e2be86"
            ) == .alreadyCurrent
        )
        #expect(
            KonvoSkill.interpretPull(
                output: "Already up-to-date.\n", exitCode: 0, commitAfter: "0e2be86"
            ) == .alreadyCurrent
        )
    }

    @Test("A real pull reports the new commit")
    func reportsTheNewCommit() {
        #expect(
            KonvoSkill.interpretPull(
                output: "Updating 0e2be86..ff11aa2\nFast-forward\n",
                exitCode: 0,
                commitAfter: "ff11aa2"
            ) == .updated(to: "ff11aa2")
        )
    }

    @Test("A refused pull says why, in git's words")
    func reportsFailure() {
        let result = KonvoSkill.interpretPull(
            output: "error: Your local changes would be overwritten by merge.\n",
            exitCode: 1,
            commitAfter: "0e2be86"
        )
        #expect(
            result == .failed("error: Your local changes would be overwritten by merge.")
        )
    }

    @Test("A failure with nothing to say still says something")
    func failureIsNeverSilent() {
        let result = KonvoSkill.interpretPull(
            output: "   \n\n", exitCode: 128, commitAfter: ""
        )
        #expect(result != .alreadyCurrent)
        if case .failed(let detail) = result {
            #expect(!detail.isEmpty)
        } else {
            Issue.record("a non-zero exit must be a failure")
        }
    }

    @Test("A successful pull is never read as a failure")
    func successIsNotAFailure() {
        // The exit code decides, not the text: "error" appears in plenty of
        // successful pull output, in a file name among others.
        let result = KonvoSkill.interpretPull(
            output: "Fast-forward\n src/error_handling.md | 2 +-\n",
            exitCode: 0,
            commitAfter: "ff11aa2"
        )
        #expect(result == .updated(to: "ff11aa2"))
    }
}
