import Foundation

/// Which copy of the konvo skill the critique is actually running against.
///
/// The critique's whole shape — the severities, the categories, the "quote it
/// character for character" rule that every highlight depends on — comes from
/// the skill rather than from this app. So when a critique starts returning
/// something the rail cannot draw, the first useful question is which version
/// of the skill answered, and until now there was nowhere to look.
///
/// The skill is a git checkout, so the version *is* its commit. There is no
/// `version:` field in its front matter to read, and inventing one here would
/// mean maintaining a number in two places that could disagree.
public enum KonvoSkill {
    /// Where the Copilot CLI keeps user skills, relative to home.
    public static let relativePath = ".copilot/skills/konvo"

    /// What is known about the installed copy.
    public struct Installed: Equatable, Sendable {
        /// The short commit the checkout is on.
        public let commit: String
        /// The subject line of that commit, which is the closest thing to a
        /// human-readable name for a version here.
        public let subject: String
        /// When that commit was made.
        public let date: Date?
        /// Whether the checkout has been edited since.
        public let isModified: Bool

        public init(
            commit: String,
            subject: String,
            date: Date?,
            isModified: Bool
        ) {
            self.commit = commit
            self.subject = subject
            self.date = date
            self.isModified = isModified
        }
    }

    /// Why the version could not be read.
    public enum Absence: Equatable, Sendable {
        /// No skill directory at all.
        case notInstalled
        /// A directory, but not a git checkout — somebody copied the files in
        /// by hand, which works perfectly well and simply cannot be versioned
        /// or updated from here.
        case notAGitCheckout
        /// Git ran and failed.
        case unreadable(String)

        public var summary: String {
            switch self {
            case .notInstalled:
                return "The konvo skill is not installed."
            case .notAGitCheckout:
                return "The konvo skill is installed but is not a git "
                    + "checkout, so it cannot report a version or be updated "
                    + "from here."
            case .unreadable(let detail):
                return detail
            }
        }
    }

    /// The heading that opens the part of the skill this app uses.
    public static let critiqueHeading = "## Critique"

    /// The skill's critique pass, pulled out of `SKILL.md`.
    ///
    /// The app sends this with every request, so the critique is the skill's
    /// rather than the model's own idea of what a critique is. Sending the
    /// whole file would be wasteful and mostly irrelevant — it is 110KB, and
    /// all but this section is about *writing* rather than about reading
    /// somebody else's draft.
    ///
    /// Taken as "from `## Critique` up to the next heading at the same level",
    /// which is how the file is organised. A `##` inside a fenced code block
    /// would end the section early; the skill has none in this section today,
    /// and the check that measures the extracted length would catch it if one
    /// arrived.
    public static func critiquePass(fromSkill markdown: String) -> String? {
        guard let start = markdown.range(of: critiqueHeading) else { return nil }
        let rest = markdown[start.lowerBound...]
        // The next top-level section, found by looking for a line that begins
        // "## " after the first one.
        var end = rest.endIndex
        var searchFrom = rest.index(rest.startIndex, offsetBy: critiqueHeading.count)
        while let next = rest.range(of: "\n## ", range: searchFrom..<rest.endIndex) {
            end = next.lowerBound
            break
        }
        let section = String(rest[rest.startIndex..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
    }

    /// Parses `git log -1 --format=%h%n%cI%n%s` plus a porcelain status.
    ///
    /// Separated from running git so the parsing can be checked without a
    /// repository: the failure that matters is a subject line containing a
    /// newline or a percent sign, which is ordinary in a commit message and
    /// would otherwise be read as another field.
    public static func parse(
        log: String,
        status: String
    ) -> Installed? {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return nil }
        let commit = String(lines[0]).trimmingCharacters(in: .whitespaces)
        guard !commit.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        let date = formatter.date(
            from: String(lines[1]).trimmingCharacters(in: .whitespaces)
        )
        // Everything after the date is the subject, rejoined: a commit subject
        // is one line, but taking only `lines[2]` would silently truncate one
        // that somehow is not.
        let subject = lines.dropFirst(2)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Installed(
            commit: commit,
            subject: subject,
            date: date,
            isModified: !status.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    /// How to describe the installed copy in a sentence.
    public static func summary(for installed: Installed) -> String {
        var parts = [installed.commit]
        if let date = installed.date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            parts.append(formatter.string(from: date))
        }
        if installed.isModified {
            parts.append("edited locally")
        }
        return parts.joined(separator: " · ")
    }

    /// What an update did.
    public enum UpdateResult: Equatable, Sendable {
        case alreadyCurrent
        case updated(to: String)
        case failed(String)

        public var summary: String {
            switch self {
            case .alreadyCurrent:
                return "Already the latest version."
            case .updated(let commit):
                return "Updated to \(commit)."
            case .failed(let detail):
                return detail
            }
        }
    }

    /// Reads `git pull`'s own words and says what happened.
    ///
    /// "Already up to date" is git's phrasing and is worth translating, because
    /// a button that says nothing after being pressed reads as a button that
    /// did not work.
    public static func interpretPull(
        output: String,
        exitCode: Int32,
        commitAfter: String
    ) -> UpdateResult {
        guard exitCode == 0 else {
            let firstUseful = output
                .split(separator: "\n")
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(String.init) ?? "The update failed."
            return .failed(firstUseful)
        }
        if output.localizedCaseInsensitiveContains("already up to date")
            || output.localizedCaseInsensitiveContains("already up-to-date") {
            return .alreadyCurrent
        }
        return .updated(to: commitAfter)
    }
}
