import Foundation

/// What the critique is doing right now.
///
/// A critique takes about half a minute, and a spinner for half a minute reads
/// as a hang. Measured on a real run, that time is not one long wait but four
/// distinct stages, and the CLI announces every one of them:
///
/// | | |
/// | --- | --- |
/// | 0.0–0.7s | starting the session |
/// | 0.7–2.1s | a round trip to decide to load the konvo skill, then loading it |
/// | 2.1–14.3s | reading the draft — the skill reads it twice before saying anything |
/// | 14.3–27.0s | writing the report |
///
/// The last stage is the long one because the report is the product: some four
/// hundred tokens of findings, at roughly 27ms a token. Nothing is stuck; it is
/// being written. Saying so is the difference between waiting and worrying.
public struct CritiqueProgress: Equatable, Sendable {
    public enum Stage: Int, Equatable, Sendable, CaseIterable {
        case starting
        case loadingSkill
        case reading
        case writing

        public var headline: String {
            switch self {
            case .starting: return "Starting up"
            case .loadingSkill: return "Loading the konvo skill"
            case .reading: return "Reading the whole draft"
            case .writing: return "Writing the notes"
            }
        }

        /// What the reader should expect, so the wait is legible.
        public var explanation: String {
            switch self {
            case .starting:
                return "Opening a session with the Copilot CLI."
            case .loadingSkill:
                return "The editorial rules the critique follows."
            case .reading:
                return "It reads the piece end to end before saying anything, "
                    + "so a passage is judged in context."
            case .writing:
                return "Each note is written out in full. This is the long part."
            }
        }
    }

    public let stage: Stage
    /// The model's own account of what it is looking at, when it has offered
    /// one. Shown as-is: it is a better progress message than anything this
    /// code could invent, because it is actually true.
    public let detail: String?
    /// How many findings have arrived so far, counted from the report as it
    /// streams. Zero until the report starts.
    public let findingsSoFar: Int

    public init(stage: Stage, detail: String? = nil, findingsSoFar: Int = 0) {
        self.stage = stage
        self.detail = detail
        self.findingsSoFar = findingsSoFar
    }
}

/// Turns the CLI's event stream into something worth showing.
///
/// The CLI emits JSONL on stdout with `--output-format json`: one object per
/// line, each with a `type`. This reads those lines and keeps just enough state
/// to answer "what is happening, and how far along is it".
///
/// Deliberately tolerant. An unknown event type is not an error — the CLI is
/// free to add them — and a line that is not JSON at all is skipped, because
/// the stream is not a contract this app controls.
public struct CritiqueProgressReader {
    private(set) public var stage: CritiqueProgress.Stage = .starting
    private(set) public var detail: String?
    /// The report as it arrives, so the finished reply needs no second source.
    private(set) public var reply = ""
    private var reasoning = ""

    public init() {}

    /// Reads one line. Returns an update when something worth showing changed.
    public mutating func read(line: String) -> CritiqueProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data),
              let object = event as? [String: Any],
              let type = object["type"] as? String
        else {
            return nil
        }
        let payload = object["data"] as? [String: Any] ?? [:]
        let before = CritiqueProgress(
            stage: stage, detail: detail, findingsSoFar: findingCount
        )

        switch type {
        case "tool.execution_start":
            if payload["toolName"] as? String == "skill" {
                stage = .loadingSkill
                detail = (payload["arguments"] as? [String: Any])?["skill"] as? String
            }

        case "assistant.reasoning_delta":
            stage = .reading
            reasoning += (payload["deltaContent"] as? String) ?? ""
            detail = Self.latestSentence(in: reasoning)

        case "assistant.message_start":
            stage = .writing
            detail = nil

        case "assistant.message_delta":
            stage = .writing
            reply += (payload["deltaContent"] as? String) ?? ""

        default:
            return nil
        }

        let now = CritiqueProgress(
            stage: stage, detail: detail, findingsSoFar: findingCount
        )
        return now == before ? nil : now
    }

    /// How many findings the part-written report already contains.
    ///
    /// Counted from the `"severity"` keys rather than by parsing, because the
    /// report is incomplete by definition while it is arriving — there is no
    /// point at which half a JSON object is valid JSON.
    public var findingCount: Int {
        guard !reply.isEmpty else { return 0 }
        return reply.components(separatedBy: "\"severity\"").count - 1
    }

    /// The last complete sentence of the model's reasoning.
    ///
    /// Reasoning arrives a few characters at a time, so the tail is usually a
    /// half-written word. Showing that flickers; showing the last thing it
    /// actually finished saying reads as a commentary.
    static func latestSentence(in text: String) -> String? {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        let sentences = cleaned
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 12 }
        guard let last = sentences.last else { return nil }
        return last + "…"
    }
}
