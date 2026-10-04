import Foundation

/// How good the draft looks right now, out of a hundred.
///
/// Deliberately a *decaying* score rather than a subtraction. Subtracting a
/// fixed cost per finding has two failure modes that both make the number
/// useless: a long, thorough critique of a decent draft drives it to zero, and
/// once it is at zero the number stops moving however much the author fixes.
/// Decay keeps every fix worth something and keeps the worst draft above the
/// floor, which is also just true — no draft anyone bothered to write is worth
/// nothing.
///
/// It scores what still stands against the draft. A note marked Done stops
/// counting, because the author has fixed it. A dismissed note keeps its full
/// weight, because dismissing is a decision to leave the passage as it is —
/// the problem the critic named is still on the page. Scoring dismissals as
/// fixes is what let a draft reach "100, Ready" by dismissing all eight of its
/// notes while the summary above them still listed three problems.
///
/// Those summary problems count too, as a low note each: the critic's view of
/// what holds the piece back is part of its verdict, and a perfect score next
/// to a list of reasons the piece is not perfect reads as a broken number.
public enum CritiqueScore {
    /// What one finding costs, before decay.
    ///
    /// Severity is about reader impact, and the gaps between the three are
    /// wide because the consequences are: a false claim breaks the piece, a
    /// clumsy sentence slows it down, a typo is a typo.
    public static func weight(_ severity: CritiqueSeverity) -> Double {
        switch severity {
        case .high: return 12
        case .medium: return 5
        case .low: return 2
        }
    }

    /// How fast the score falls. Larger is gentler.
    ///
    /// Chosen so that one high lands in the low eighties, a typical messy
    /// draft — three high and four medium — lands near forty, and a draft with
    /// a dozen serious problems is still in single figures rather than
    /// negative.
    static let softness: Double = 60

    /// What one problem from the summary costs: the same as a low note.
    ///
    /// Less than a passage-level finding because it is a judgement about the
    /// piece in the round, often a restatement of findings already counted,
    /// and the author cannot answer it directly. Enough that three of them
    /// hold a draft with no notes left at ninety.
    public static let listedProblemWeight: Double = 2

    /// The score for the findings still standing against the draft, plus the
    /// problems the summary lists.
    public static func score(
        for findings: [CritiqueFinding],
        listedProblems: Int = 0
    ) -> Int {
        let penalty = findings.map { weight($0.severity) }.reduce(0, +)
            + Double(max(0, listedProblems)) * listedProblemWeight
        return score(penalty: penalty)
    }

    /// Whether a finding answered this way still costs the draft.
    ///
    /// Only Done clears a note. Dismissed means "leaving it", not "fixed it".
    public static func counts(_ resolution: CritiqueResolution?) -> Bool {
        resolution != .completed
    }

    static func score(penalty: Double) -> Int {
        guard penalty > 0 else { return 100 }
        let decayed = 100 * exp(-penalty / softness)
        // Never zero: the floor is 1, because a draft with something in it is
        // never worth nothing, and a zero reads as a verdict rather than a
        // measurement.
        return max(1, min(100, Int(decayed.rounded())))
    }

    /// A word for the number, so the rail says something rather than only
    /// scoring something.
    ///
    /// "Ready" is a claim about the draft, so it is only made when a critique
    /// of the text as it stands found nothing: `isConfirmed` is false when the
    /// draft has changed since, or when the hundred was reached by marking
    /// notes Done by hand. Either way the author's word is taken for the
    /// number, and the verdict asks a fresh critique to agree.
    public static func verdict(_ score: Int, isConfirmed: Bool = true) -> String {
        switch score {
        case 100: return isConfirmed ? "Ready" : "Looks ready"
        case 85...: return "Nearly there"
        case 60...: return "Solid, with work to do"
        case 35...: return "Needs a pass"
        default: return "Needs a rewrite"
        }
    }
}
