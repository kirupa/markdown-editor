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
/// It scores what is *outstanding*, so completing or dismissing everything
/// returns exactly 100. That is the point of the two actions: the author has
/// said what they meant to say, and the score should agree with them rather
/// than keep score against them.
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

    /// The score for a set of outstanding findings.
    public static func score(for findings: [CritiqueFinding]) -> Int {
        let penalty = findings.map { weight($0.severity) }.reduce(0, +)
        return score(penalty: penalty)
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
    public static func verdict(_ score: Int) -> String {
        switch score {
        case 100: return "Ready"
        case 85...: return "Nearly there"
        case 60...: return "Solid, with work to do"
        case 35...: return "Needs a pass"
        default: return "Needs a rewrite"
        }
    }
}
