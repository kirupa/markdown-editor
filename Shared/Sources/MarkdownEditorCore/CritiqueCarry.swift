import Foundation

/// Carrying a critique's notes into the next one.
///
/// A re-run used to be a second critique that happened to be about the same
/// draft. Its notes had new identities, so the only way to tell "this is the
/// note you already answered" was the passage-and-category fingerprint — and
/// a model that re-quotes a sentence or files it under another heading breaks
/// that. Measured on a 467-word post: one fixed typo, a changes-only re-run,
/// and the paragraph's other notes came back reworded, a new nit landed on the
/// sentence just fixed, the Answered section was gone, and the score was back
/// where it started. The author did the work and the rail forgot it.
///
/// So the notes go *with* the request. The critic is shown each one and asked
/// what became of it — fixed, or still there — and only writes findings for
/// what none of them already says. A note keeps its identity, its wording and
/// the author's answer to it, and the only thing that can move it is the
/// critic saying something about it.
///
/// Pure, like the rest of the core: deciding what a verdict does to a note is
/// a rule, and a rule wants a test, not a window.
public enum CritiqueCarry {
    /// A note being carried into a re-run.
    public struct Note: Equatable, Sendable {
        public let finding: CritiqueFinding
        /// The author's answer to it, if any.
        public let resolution: CritiqueResolution?
        /// Whether the author has changed its passage since it was written.
        public let isEdited: Bool
        /// The passage the note is about, as it reads now — followed through
        /// the author's edits rather than searched for. Nil when the passage
        /// was deleted, or never found.
        public let passage: String?

        public init(
            finding: CritiqueFinding,
            resolution: CritiqueResolution?,
            isEdited: Bool = false,
            passage: String? = nil
        ) {
            self.finding = finding
            self.resolution = resolution
            self.isEdited = isEdited
            self.passage = passage
        }
    }

    /// What became of a note.
    public enum Change: Equatable, Sendable {
        /// The critic found the problem gone.
        case fixed
        /// The author had cleared it — marked it Done, or rewritten its
        /// passage — and the critic says it is still there.
        case reopened
        /// It was open, and still is.
        case stillOpen
        /// Nothing new was said about it, or the author's answer stands
        /// whatever the critic thinks: a dismissed note stays dismissed.
        case unchanged
    }

    public struct Outcome: Equatable, Sendable {
        /// The same note — same identity, same wording — with its quote and
        /// location brought up to date when the critic gave new ones.
        public let finding: CritiqueFinding
        /// The author's answer after this run.
        public let resolution: CritiqueResolution?
        public let change: Change

        public var isFixed: Bool { change == .fixed }
    }

    /// The name a note goes by in the request: "n1", "n2"…
    ///
    /// Short and positional rather than the note's UUID, because the critic
    /// has to copy it back exactly and a model copies "n3" far more reliably
    /// than thirty-six characters of hex.
    public static func key(at index: Int) -> String { "n\(index + 1)" }

    /// The notes as the request carries them.
    public static func previousNotes(
        _ findings: [CritiqueFinding]
    ) -> [CritiquePreviousNote] {
        findings.enumerated().map { index, finding in
            CritiquePreviousNote(
                key: key(at: index),
                category: finding.category,
                location: finding.location,
                quote: finding.quote,
                why: finding.why
            )
        }
    }

    /// What one verdict does to one note.
    ///
    /// - Fixed is fixed, whoever cleared it — including a note marked Done,
    ///   which is the critic agreeing with the author.
    /// - Still there leaves a dismissed note dismissed: dismissing is the
    ///   author deciding to leave the passage as it is, and the critic saying
    ///   the passage is as it was is not news. A note the author had cleared
    ///   comes back open, and says so. An open one stays open.
    /// - Silence leaves an open or dismissed note as it was. A note the
    ///   author had cleared — marked Done, or rewritten — shown to the critic
    ///   and not raised again is taken as fixed. If the critic was wrong to
    ///   stay quiet it is free to raise the problem as a new finding, which is
    ///   the same conversation; the alternative is a cleared note that waits
    ///   for ever on an answer the model keeps leaving out, and holds "Ready"
    ///   back with it.
    public static func resolve(
        _ note: Note,
        verdict: CritiqueNoteVerdict?,
        in text: String
    ) -> Outcome {
        let wasCleared = note.resolution == .completed || note.isEdited
        switch verdict {
        case .fixed:
            return Outcome(finding: note.finding, resolution: note.resolution, change: .fixed)
        case .stillApplies(let quote, let location):
            let finding = updated(note, quote: quote, location: location, in: text)
            if note.resolution == .dismissed {
                return Outcome(finding: finding, resolution: .dismissed, change: .unchanged)
            }
            return Outcome(
                finding: finding,
                resolution: nil,
                change: wasCleared ? .reopened : .stillOpen
            )
        case nil:
            if wasCleared {
                return Outcome(finding: note.finding, resolution: note.resolution, change: .fixed)
            }
            return Outcome(finding: note.finding, resolution: note.resolution, change: .unchanged)
        }
    }

    /// The same note pointing at the passage as it reads now.
    ///
    /// The critic's quote is taken only if it can be found: a quote that is not
    /// in the draft highlights nothing, and replacing one that works with one
    /// that does not would turn a working note into "Not found". Failing that,
    /// a rewritten passage is quoted as the author left it — the editor
    /// followed it through every keystroke, so it is the most exact answer
    /// there is to "where is this note now". The original quote is the last
    /// resort.
    static func updated(
        _ note: Note,
        quote: String?,
        location: String?,
        in text: String
    ) -> CritiqueFinding {
        let original = note.finding
        var chosen = original.quote
        if let quote, anchors(quote, like: original, in: text) {
            chosen = quote
        } else if note.isEdited, let passage = note.passage,
                  !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chosen = passage
        }
        let place = location.flatMap { $0.isEmpty ? nil : $0 } ?? original.location
        guard chosen != original.quote || place != original.location else {
            return original
        }
        return CritiqueFinding(
            id: original.id,
            severity: original.severity,
            category: original.category,
            needsVerification: original.needsVerification,
            location: place,
            quote: chosen,
            why: original.why,
            fix: original.fix,
            direction: original.direction
        )
    }

    private static func anchors(
        _ quote: String,
        like finding: CritiqueFinding,
        in text: String
    ) -> Bool {
        let probe = CritiqueFinding(
            severity: finding.severity,
            category: finding.category,
            location: finding.location,
            quote: quote,
            why: finding.why
        )
        return CritiqueAnchoring.range(for: probe, in: text) != nil
    }

    /// Whether a new finding only says again what a carried note says.
    ///
    /// The prompt asks the critic not to repeat the notes it was shown, and a
    /// model asked not to do something mostly does not. This catches the rest:
    /// the same passage under the same heading — the fingerprint — or one
    /// quote inside the other under the same heading, which is how a model
    /// re-quotes a sentence it has already complained about with a few words
    /// more or less around it.
    ///
    /// Containment needs a few words to go on. "the" is inside most quotes.
    public static func isRepeat(
        _ finding: CritiqueFinding,
        of carried: [CritiqueFinding]
    ) -> Bool {
        let fingerprint = CritiqueFingerprint.of(finding)
        let category = CritiqueFingerprint.normalise(finding.category)
        let quote = CritiqueFingerprint.normalise(finding.quote)
        return carried.contains { other in
            if CritiqueFingerprint.of(other) == fingerprint { return true }
            guard CritiqueFingerprint.normalise(other.category) == category else {
                return false
            }
            let otherQuote = CritiqueFingerprint.normalise(other.quote)
            let shorter = min(quote.count, otherQuote.count)
            guard shorter >= minimumContainedLength else { return false }
            return quote.contains(otherQuote) || otherQuote.contains(quote)
        }
    }

    static let minimumContainedLength = 12

    /// What a re-run changed, in the terms the author cares about.
    public struct Delta: Equatable, Sendable {
        public let fixed: Int
        public let reopened: Int
        public let new: Int

        public init(fixed: Int, reopened: Int, new: Int) {
            self.fixed = fixed
            self.reopened = reopened
            self.new = new
        }

        /// "2 fixed · 1 new since the last critique."
        ///
        /// The sentence that was missing. The score moving from 45 to 52 says
        /// something happened; this says what, which is the part that tells
        /// the author whether the last ten minutes worked.
        public var summary: String {
            var parts: [String] = []
            if fixed > 0 { parts.append("\(fixed) fixed") }
            if reopened > 0 { parts.append("\(reopened) reopened") }
            if new > 0 { parts.append("\(new) new") }
            guard !parts.isEmpty else {
                return "Nothing fixed and nothing new since the last critique."
            }
            return parts.joined(separator: " · ") + " since the last critique."
        }
    }
}

/// A note from an earlier critique, as the request carries it.
public struct CritiquePreviousNote: Equatable, Sendable {
    /// "n1", "n2"… — see `CritiqueCarry.key(at:)`.
    public let key: String
    public let category: String
    public let location: String
    public let quote: String
    public let why: String

    public init(key: String, category: String, location: String, quote: String, why: String) {
        self.key = key
        self.category = category
        self.location = location
        self.quote = quote
        self.why = why
    }
}

/// What the critic said about one earlier note.
public enum CritiqueNoteVerdict: Equatable, Sendable {
    case fixed
    /// Still there. The quote and location are where it is now, when the
    /// critic said.
    case stillApplies(quote: String?, location: String?)
}

/// A critique, together with what it said about the notes it was shown.
///
/// Not fields on `CritiqueReport`, which is saved in every document's history:
/// the verdicts are about one request, and a report that grew a field for them
/// would have to carry it in every file it was ever written to.
public struct CritiqueAnswer: Equatable, Sendable {
    public let report: CritiqueReport
    /// Keyed by the note's name in the request — "n1", "n2"…
    public let verdicts: [String: CritiqueNoteVerdict]

    public init(report: CritiqueReport, verdicts: [String: CritiqueNoteVerdict] = [:]) {
        self.report = report
        self.verdicts = verdicts
    }
}
