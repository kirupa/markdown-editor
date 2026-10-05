import Foundation

/// What the critique is doing right now.
///
/// A critique takes half a minute or more, and a spinner for that long reads
/// as a hang. The CLI announces each stage as it reaches it. Measured on a
/// 467-word draft with the default reasoning effort:
///
/// | | |
/// | --- | --- |
/// | 0.0–0.7s | starting the session |
/// | 0.7–4.1s | the request out and the model's first thought back |
/// | 4.1–33.9s | reading the draft — reasoning about it before saying anything |
/// | 33.9–52.0s | writing the report, findings from 37.6s, one every ~1.5s |
///
/// The skill used to be loaded by a tool call of its own, a round trip of
/// about 1.4s before anything was read. It travels in the prompt now and the
/// critique has no tools at all, so `loadingSkill` is only seen if a provider
/// still announces one.
public struct CritiqueProgress: Equatable, Sendable {
    public enum Stage: Int, Equatable, Sendable, CaseIterable {
        case starting
        case loadingSkill
        case reading
        case writing

        public var headline: String {
            switch self {
            case .starting: return "Starting up"
            case .loadingSkill: return "Loading the KONVO critique pass"
            case .reading: return "Reading the whole draft"
            case .writing: return "Writing the notes"
            }
        }

        /// What the reader should expect, so the wait is legible.
        public var explanation: String {
            switch self {
            case .starting:
                return "Getting ready."
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
    /// The findings already written out in full, so they can be read before
    /// the rest of the report has been. Empty for a provider that answers in
    /// one piece.
    public let findings: [CritiqueFinding]

    public init(
        stage: Stage,
        detail: String? = nil,
        findingsSoFar: Int = 0,
        findings: [CritiqueFinding] = []
    ) {
        self.stage = stage
        self.detail = detail
        self.findingsSoFar = findingsSoFar
        self.findings = findings
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
    /// The CLI's own exit code, from the `result` event that closes a run.
    ///
    /// That event arrives 0.6–1s before the process has finished exiting.
    /// Waiting for the exit as well spent that time on every critique saying
    /// nothing the event had not already said.
    private(set) public var exitCode: Int?
    private var reasoning = ""
    private var stream = CritiqueFindingStream()

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
        let before = progress

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
            let delta = (payload["deltaContent"] as? String) ?? ""
            reply += delta
            stream.append(delta)

        case "result":
            // At the top level, not under `data`. Read as an Int whichever
            // way the number arrived.
            exitCode = (object["exitCode"] as? NSNumber)?.intValue ?? 0
            return nil

        default:
            return nil
        }

        let now = progress
        return now == before ? nil : now
    }

    private var progress: CritiqueProgress {
        CritiqueProgress(
            stage: stage,
            detail: detail,
            findingsSoFar: findingCount,
            findings: stream.findings
        )
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
