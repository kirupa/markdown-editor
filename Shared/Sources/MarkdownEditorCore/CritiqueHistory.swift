import Foundation

/// One critique, kept so it can be read again later.
///
/// The draft text is kept alongside the report, and that is the load-bearing
/// part rather than an indulgence. A critique's findings are anchored by
/// quoting the draft, so an old critique read against a *rewritten* draft has
/// to be able to say which of its notes still point at something. Keeping the
/// text it was written about is what makes that answerable instead of guessed.
public struct CritiqueRevision: Equatable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let date: Date
    public let report: CritiqueReport
    /// The draft exactly as it was when this critique was written.
    public let documentText: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        report: CritiqueReport,
        documentText: String
    ) {
        self.id = id
        // Truncated to the second, which is the precision it is stored and
        // displayed at. Keeping fractions means a revision never equals itself
        // after a save and reload, which is a difference that exists only in
        // memory and would quietly break anything comparing the two.
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        self.report = report
        self.documentText = documentText
    }

    /// The score this critique arrived with, before anything was answered.
    public var score: Int { CritiqueScore.score(for: report.findings) }

    /// Whether the draft has moved on since this was written.
    public func isStale(against text: String) -> Bool { documentText != text }

    /// How many of this critique's notes still point at something in `text`.
    ///
    /// This is the honest measure of how much an old critique is still worth:
    /// not how long ago it was, but how much of the draft it described is
    /// still there. A note whose sentence has been rewritten has nothing left
    /// to say, and saying *how many* are in that state is more use than a
    /// warning triangle.
    public func stillApplying(to text: String) -> Int {
        CritiqueAnchoring.anchor(report.findings, in: text)
            .filter(\.isAnchored)
            .count
    }
}

/// Every critique kept for one document, newest first.
public struct CritiqueHistory: Equatable, Sendable, Codable {
    /// How many are kept.
    ///
    /// Enough to look back over a working session, few enough that the file
    /// stays small — each entry carries a copy of the draft, so this is not
    /// free. Older ones fall off the end.
    public static let limit = 12

    public private(set) var revisions: [CritiqueRevision]

    public init(revisions: [CritiqueRevision] = []) {
        self.revisions = revisions
    }

    public var isEmpty: Bool { revisions.isEmpty }
    public var latest: CritiqueRevision? { revisions.first }

    public func revision(withID id: UUID?) -> CritiqueRevision? {
        guard let id else { return nil }
        return revisions.first { $0.id == id }
    }

    /// Files a new critique at the front.
    ///
    /// A re-run over an unchanged draft replaces the previous entry rather than
    /// stacking beside it. Two critiques of the same text are two opinions
    /// about one thing, and a history that fills up with them buries the
    /// revisions that actually differ.
    public mutating func add(_ revision: CritiqueRevision) {
        if let first = revisions.first, first.documentText == revision.documentText {
            revisions.removeFirst()
        }
        revisions.insert(revision, at: 0)
        if revisions.count > Self.limit {
            revisions.removeSubrange(Self.limit...)
        }
    }
}

/// How a revision is named in the list.
public enum CritiqueRevisionLabel {
    /// "Just now", "12 minutes ago", "Yesterday" — the same shorthand the
    /// recents list uses, because a timestamp is not what anyone is looking
    /// for. They are looking for "the one before I rewrote the opening".
    public static func relative(
        _ date: Date,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
