import Foundation

/// The findings of a report that is still being written, read out of it one
/// at a time as each is finished.
///
/// The findings are the last part of a critique to arrive. Measured on a
/// 467-word draft, the first was complete 37.6s into a 52s run and another
/// followed every second and a half; holding all of them back until the reply
/// had ended made the longest stretch of the wait the emptiest one.
///
/// Only what the decoder would read is read here: complete objects inside the
/// report's top-level `"findings"` array, each handed to the same
/// `CritiqueReportDecoder.finding(from:)` the finished report goes through, so
/// a note shown early is the note the report will hold. Strings are respected
/// the way `extractJSONObject` respects them — a quote with a brace or a
/// bracket in it must not end a finding early — and the scan resumes where it
/// stopped, so a reply that arrives in four hundred pieces is read once.
public struct CritiqueFindingStream: Sendable {
    /// Every finding completed so far, in the order the critic wrote them.
    public private(set) var findings: [CritiqueFinding] = []

    private enum Phase: Sendable {
        case beforeReport
        case inReport
        case inFindings
        case finished
    }

    // Bytes rather than characters: every structural character in JSON is
    // ASCII, and no byte of a multi-byte UTF-8 sequence is, so a byte scan
    // cannot mistake part of a letter for a brace.
    private var bytes: [UInt8] = []
    private var position = 0
    private var phase = Phase.beforeReport
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var stringStart = 0
    /// The last string closed at the report's top level, which is the key of
    /// whatever opens there next.
    private var lastKey: [UInt8] = []
    private var findingStart = 0

    private static let findingsKey = Array("findings".utf8)

    public init() {}

    /// Reads the next piece of the reply. True when it finished a finding.
    @discardableResult
    public mutating func append(_ text: String) -> Bool {
        guard phase != .finished else { return false }
        let before = findings.count
        bytes.append(contentsOf: text.utf8)
        while position < bytes.count, phase != .finished {
            step(bytes[position])
            position += 1
        }
        return findings.count > before
    }

    private mutating func step(_ byte: UInt8) {
        if inString {
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                inString = false
                if phase == .inReport, depth == 1 {
                    // Copied out: a slice would keep the whole buffer shared,
                    // and the next piece of the reply would copy all of it.
                    lastKey = Array(bytes[(stringStart + 1)..<position])
                }
            }
            return
        }
        switch byte {
        case UInt8(ascii: "\""):
            inString = true
            stringStart = position
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            if phase == .beforeReport {
                // A fence or a sentence of preamble comes before the object;
                // the report is the first brace outside a string.
                guard byte == UInt8(ascii: "{") else { return }
                phase = .inReport
                depth = 1
                return
            }
            if phase == .inReport, depth == 1, byte == UInt8(ascii: "["),
               lastKey == Self.findingsKey {
                phase = .inFindings
            } else if phase == .inFindings, depth == 2, byte == UInt8(ascii: "{") {
                findingStart = position
            }
            depth += 1
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            guard phase != .beforeReport else { return }
            depth -= 1
            if phase == .inFindings, depth == 2, byte == UInt8(ascii: "}") {
                read(findingStart...position)
            } else if depth <= 1, phase == .inFindings {
                phase = .finished
            } else if depth <= 0 {
                phase = .finished
            }
        default:
            break
        }
    }

    private mutating func read(_ range: ClosedRange<Int>) {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(bytes[range])),
              let object = parsed as? [String: Any],
              let finding = CritiqueReportDecoder.finding(from: object)
        else { return }
        findings.append(finding)
    }
}
