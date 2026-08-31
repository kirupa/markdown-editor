import Foundation

/// What the author has already decided about a finding.
public enum CritiqueResolution: String, Equatable, Sendable, CaseIterable {
    /// Fixed. The author acted on it.
    case completed
    /// Not doing it. The author read it and disagreed, or it does not apply.
    case dismissed

    public var label: String {
        switch self {
        case .completed: return "Done"
        case .dismissed: return "Dismissed"
        }
    }
}

/// A stable name for a finding, so a decision about it survives a fresh
/// critique.
///
/// The problem this solves: a second run produces new findings with new
/// identifiers, and nothing in them says "this is the one you already
/// dismissed". Without a fingerprint, every re-run resurrects every dismissal
/// and the feature nags.
///
/// The name is the passage plus the category, folded the same way anchoring
/// folds a quote — so a model that retypes the sentence with straight quotes,
/// or wraps it differently, still produces the same name. The category is in
/// there because two different objections to one sentence are two findings,
/// and dismissing one should not silence the other.
///
/// Deliberately *not* the severity or the wording of the explanation. Both
/// vary between runs for the same underlying problem, and a fingerprint that
/// changes when the model rephrases itself would not survive the thing it
/// exists to survive.
public enum CritiqueFingerprint {
    public static func of(_ finding: CritiqueFinding) -> String {
        of(quote: finding.quote, category: finding.category)
    }

    public static func of(quote: String, category: String) -> String {
        "\(normalise(quote))\u{1F}\(normalise(category))"
    }

    static func normalise(_ text: String) -> String {
        CritiqueAnchoring.fold(text).value
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The decisions an author has made about one document's findings.
///
/// Pure, so the rules can be checked without a disk or a screen. Persisting it
/// is somebody else's job.
public struct CritiqueResolutions: Equatable, Sendable {
    private var byFingerprint: [String: CritiqueResolution]

    public init(_ byFingerprint: [String: CritiqueResolution] = [:]) {
        self.byFingerprint = byFingerprint
    }

    public var isEmpty: Bool { byFingerprint.isEmpty }
    public var count: Int { byFingerprint.count }

    public func resolution(for finding: CritiqueFinding) -> CritiqueResolution? {
        byFingerprint[CritiqueFingerprint.of(finding)]
    }

    public mutating func set(
        _ resolution: CritiqueResolution?,
        for finding: CritiqueFinding
    ) {
        let key = CritiqueFingerprint.of(finding)
        if let resolution {
            byFingerprint[key] = resolution
        } else {
            byFingerprint.removeValue(forKey: key)
        }
    }

    /// For persisting. Keys are fingerprints; values are the raw strings.
    public var storage: [String: String] {
        byFingerprint.mapValues(\.rawValue)
    }

    public init(storage: [String: String]) {
        byFingerprint = storage.compactMapValues(CritiqueResolution.init(rawValue:))
    }

    /// Drops decisions about findings that are no longer being made.
    ///
    /// A dismissal is about a passage. Once the author has rewritten that
    /// sentence, nothing will ever fingerprint to it again, and keeping the
    /// entry means the store grows forever with decisions about text that no
    /// longer exists. Pruning against the newest report is the only moment
    /// when what is still live is actually known.
    ///
    /// `completed` entries are kept for a report they are absent from, because
    /// absence is the expected outcome of fixing something and re-running:
    /// dropping them then would mean a later run that raises the issue again
    /// arrives as though it were new.
    public mutating func prune(keeping findings: [CritiqueFinding]) {
        let live = Set(findings.map(CritiqueFingerprint.of))
        byFingerprint = byFingerprint.filter { key, resolution in
            resolution == .completed || live.contains(key)
        }
    }
}
