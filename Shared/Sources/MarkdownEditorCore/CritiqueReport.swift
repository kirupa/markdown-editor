import Foundation

/// What an editorial pass over a draft has to say about it.
///
/// The shape follows the konvo skill's critique pass, which is where the
/// findings come from: a job read, an overall judgement, findings anchored to
/// the smallest passage that proves them, patterns that repeat, and the
/// choices worth keeping.
///
/// This lives in the core rather than in the app because none of it needs a
/// screen. What arrives from a language model is text, and text is exactly the
/// kind of input that is worth being suspicious of: the decoding below is
/// deliberately forgiving, because a report that is 90% right should still be
/// shown rather than thrown away over one unexpected field.
public struct CritiqueReport: Equatable, Sendable {
    /// One sentence naming the apparent reader, purpose, and container.
    public let jobRead: String
    /// The strongest working choice and the largest quality risk.
    public let overall: String
    public let findings: [CritiqueFinding]
    public let repeatedPatterns: [CritiquePattern]
    /// Choices that should survive revision.
    public let keep: [String]

    public init(
        jobRead: String,
        overall: String,
        findings: [CritiqueFinding],
        repeatedPatterns: [CritiquePattern] = [],
        keep: [String] = []
    ) {
        self.jobRead = jobRead
        self.overall = overall
        self.findings = findings
        self.repeatedPatterns = repeatedPatterns
        self.keep = keep
    }

    public var isEmpty: Bool {
        findings.isEmpty && repeatedPatterns.isEmpty && keep.isEmpty
            && jobRead.isEmpty && overall.isEmpty
    }
}

/// How much a finding costs the reader.
///
/// Severity is about reader impact, not how hard the edit is: a missing "not"
/// in a safety instruction is high, and a whole bland paragraph may be medium.
public enum CritiqueSeverity: String, CaseIterable, Equatable, Sendable {
    case high
    case medium
    case low

    /// Sort order for a rail that shows the worst first.
    public var rank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    /// Reads a severity from whatever the model actually wrote.
    ///
    /// Forgiving on purpose. The label is decoration around the finding, and
    /// throwing away a real editorial point because it arrived as "High" or
    /// "critical" would be a poor trade.
    public static func parse(_ raw: String?) -> CritiqueSeverity {
        let cleaned = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch cleaned {
        case "high", "critical", "major", "blocker": return .high
        case "low", "minor", "nit", "polish": return .low
        default: return .medium
        }
    }
}

/// One thing worth changing, anchored to the passage that proves it.
public struct CritiqueFinding: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let severity: CritiqueSeverity
    /// The narrowest useful label, as the skill names them — "Grammar and
    /// mechanics", "AI-shaped habit", and so on. Kept as text rather than an
    /// enum so a category the skill grows later still arrives intact.
    public let category: String
    /// A load-bearing claim that lacks support. Marks the claim's editorial
    /// status; it does not declare it false.
    public let needsVerification: Bool
    /// Where the finding is, in the skill's own terms: "Opening, paragraph 2".
    public let location: String
    /// The smallest quote that proves the point, copied from the draft. This
    /// is what gets highlighted, so it has to be verbatim.
    public let quote: String
    /// The reader consequence.
    public let why: String
    /// A local correction, when the answer is unambiguous.
    public let fix: String?
    /// What needs to change, when the revision needs judgement only the author
    /// has.
    public let direction: String?

    public init(
        id: UUID = UUID(),
        severity: CritiqueSeverity,
        category: String,
        needsVerification: Bool = false,
        location: String,
        quote: String,
        why: String,
        fix: String? = nil,
        direction: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.category = category
        self.needsVerification = needsVerification
        self.location = location
        self.quote = quote
        self.why = why
        self.fix = fix
        self.direction = direction
    }

    /// What to show under "Why" — the advice, whichever form it came in.
    public var advice: String? {
        let candidates = [fix, direction]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return candidates.first
    }

    /// Whether the advice is a correction to apply or a direction to consider.
    public var adviceLabel: String {
        let trimmedFix = (fix ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFix.isEmpty ? "Direction" : "Fix"
    }
}

/// Something the draft does more than once.
public struct CritiquePattern: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let pattern: String
    public let locations: [String]

    public init(id: UUID = UUID(), pattern: String, locations: [String]) {
        self.id = id
        self.pattern = pattern
        self.locations = locations
    }
}

// MARK: - Reading a report out of a model's reply

public enum CritiqueReportDecoder {
    public enum Failure: Error, Equatable {
        /// Nothing in the reply looked like a JSON object.
        case noJSONFound
        /// Something did, and it was not readable as one.
        case malformedJSON(String)
    }

    /// Reads a report out of whatever the CLI printed.
    ///
    /// The reply is not guaranteed to be only JSON even when the prompt asks
    /// for only JSON: a fence, a sentence of preamble, or a trailing summary
    /// line are all things a model does. So the object is *found* in the text
    /// rather than assumed to be all of it.
    public static func decode(_ reply: String) throws -> CritiqueReport {
        guard let json = extractJSONObject(from: reply) else {
            throw Failure.noJSONFound
        }
        guard let data = json.data(using: .utf8) else {
            throw Failure.malformedJSON("the reply is not valid UTF-8")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Failure.malformedJSON(error.localizedDescription)
        }
        guard let object = parsed as? [String: Any] else {
            throw Failure.malformedJSON("the reply is not a JSON object")
        }
        return report(from: object)
    }

    /// The first balanced `{…}` run in `text`, ignoring braces inside strings.
    ///
    /// Counting braces without minding string literals is the obvious version
    /// and it is wrong: a finding whose quote contains a brace — entirely
    /// possible in a draft about code — would end the object early and lose
    /// every finding after it.
    static func extractJSONObject(from text: String) -> String? {
        let characters = Array(text)
        var depth = 0
        var start: Int?
        var inString = false
        var escaped = false

        for (index, character) in characters.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { break }
                depth -= 1
                if depth == 0, let start {
                    return String(characters[start...index])
                }
            default:
                break
            }
        }
        return nil
    }

    private static func report(from object: [String: Any]) -> CritiqueReport {
        CritiqueReport(
            jobRead: string(object["jobRead"]) ?? "",
            overall: string(object["overall"]) ?? "",
            findings: (object["findings"] as? [Any] ?? [])
                .compactMap { $0 as? [String: Any] }
                .compactMap(finding(from:)),
            repeatedPatterns: (object["repeatedPatterns"] as? [Any] ?? [])
                .compactMap { $0 as? [String: Any] }
                .compactMap(pattern(from:)),
            keep: (object["keep"] as? [Any] ?? []).compactMap(string)
        )
    }

    private static func finding(from object: [String: Any]) -> CritiqueFinding? {
        let quote = string(object["quote"]) ?? ""
        let why = string(object["why"]) ?? ""
        // A finding with neither a passage nor a reason has nothing to say and
        // nowhere to say it, so it is dropped rather than shown as an empty
        // card.
        guard !quote.isEmpty || !why.isEmpty else { return nil }
        return CritiqueFinding(
            severity: CritiqueSeverity.parse(string(object["severity"])),
            category: string(object["category"]) ?? "Note",
            needsVerification: boolean(object["needsVerification"]),
            location: string(object["location"]) ?? "",
            quote: quote,
            why: why,
            fix: string(object["fix"]),
            direction: string(object["direction"])
        )
    }

    private static func pattern(from object: [String: Any]) -> CritiquePattern? {
        guard let pattern = string(object["pattern"]), !pattern.isEmpty else {
            return nil
        }
        return CritiquePattern(
            pattern: pattern,
            locations: (object["locations"] as? [Any] ?? []).compactMap(string)
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Accepts the several ways a model writes a boolean.
    private static func boolean(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            return ["true", "yes", "1"].contains(text.lowercased())
        }
        return false
    }
}
