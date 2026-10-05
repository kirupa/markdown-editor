import Foundation

/// How closely a critique reads.
///
/// A full critique is the whole KONVO critique pass at the model's usual
/// deliberation, and it is what the score and "Ready" are for. A quick pass is
/// the same critic asked for less: only what a reader would trip over — a
/// problem of high severity, or a mechanical error of any severity — and given
/// less time to think about it.
///
/// A quick pass has no score. It does not look for structure, pacing or voice
/// below high severity, so a clean one says the draft has no typos and nothing
/// seriously wrong with it, not that it is good. A hundred out of a hundred
/// from it would be an answer to a question nobody asked.
public enum CritiqueDepth: String, Equatable, Sendable, Codable, CaseIterable {
    case full
    case quick

    /// Read leniently. A history written by a later build that knows a depth
    /// this one does not is still a history; decoding it strictly would throw
    /// away every critique in the file over one word, so a depth this build
    /// cannot place is read as the critique it has always understood.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CritiqueDepth(rawValue: raw) ?? .full
    }
}
