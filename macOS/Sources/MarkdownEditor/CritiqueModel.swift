import Foundation
import MarkdownEditorCore
import SwiftUI

/// The state behind AI Assisted critique: what was asked, what came back, and
/// which finding the author is looking at.
///
/// One object holds it because the two halves of the feature — the highlights
/// in the text and the cards in the rail — are two views of the same
/// selection. Keeping the selected finding in one place is what makes clicking
/// either one move the other, which is the whole interaction.
@MainActor
final class CritiqueModel: ObservableObject {
    /// A finding together with where it points in the document.
    struct Item: Identifiable, Equatable {
        let finding: CritiqueFinding
        /// Nil when the quoted passage could not be found in the draft.
        let range: NSRange?

        var id: UUID { finding.id }
        var isAnchored: Bool { range != nil }
    }

    @Published private(set) var report: CritiqueReport?
    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var failure: CritiqueService.Failure?
    /// Which card is raised, and which highlight is drawn strongly.
    @Published var selectedFindingID: UUID?
    /// The document the report was written about.
    ///
    /// Kept so the rail can say when it has gone stale. A critique describes a
    /// draft at a moment; once the words move, a highlight is pointing at an
    /// offset that no longer means what it meant.
    @Published private(set) var criticisedText: String?

    private let service = CritiqueService()

    var isPresented: Bool { report != nil || isRunning || failure != nil }

    /// Whether the document has been edited since the critique was written.
    func isStale(against text: String) -> Bool {
        guard let criticisedText else { return false }
        return criticisedText != text
    }

    var anchoredCount: Int { items.filter(\.isAnchored).count }

    /// How many findings there are at each severity, worst first.
    ///
    /// The rail is in reading order, so this is where the shape of the
    /// critique is legible at a glance — "three high" is the thing an author
    /// wants to know before reading anything.
    var severityCounts: [(severity: CritiqueSeverity, count: Int)] {
        CritiqueSeverity.allCases.compactMap { severity in
            let count = items.filter { $0.finding.severity == severity }.count
            return count > 0 ? (severity, count) : nil
        }
    }

    func item(withID id: UUID?) -> Item? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    /// The highlight ranges, worst last so a high finding is drawn over a low
    /// one where two passages overlap.
    var highlights: [(id: UUID, range: NSRange, severity: CritiqueSeverity)] {
        items
            .compactMap { item in
                item.range.map { (item.id, $0, item.finding.severity) }
            }
            .sorted { $0.severity.rank > $1.severity.rank }
    }

    func run(on text: String) {
        guard !isRunning else { return }
        isRunning = true
        failure = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await service.critique(document: text)
                self.apply(report, for: text)
            } catch let error as CritiqueService.Failure {
                self.fail(with: error)
            } catch {
                self.fail(
                    with: .cliFailed(status: -1, message: error.localizedDescription)
                )
            }
        }
    }

    func cancel() {
        service.cancel()
        isRunning = false
    }

    func dismiss() {
        cancel()
        report = nil
        items = []
        failure = nil
        selectedFindingID = nil
        criticisedText = nil
    }

    /// Applies a report without going through the CLI. For checks only.
    func applyForChecking(_ report: CritiqueReport, for text: String) {
        apply(report, for: text)
    }

    private func apply(_ report: CritiqueReport, for text: String) {
        let anchors = CritiqueAnchoring.anchor(report.findings, in: text)
        let byID = Dictionary(
            anchors.map { ($0.findingID, $0.range) },
            uniquingKeysWith: { first, _ in first }
        )
        self.report = report
        // Ordered by where they are in the document, not by severity.
        //
        // The rail sits beside the text, and a rail beside the text that is
        // ordered by something other than the text reads as a list that
        // happens to be on the right. Reading down the comments should mean
        // reading down the draft. Severity is not lost — it is the colour and
        // the label on every card, and counted at the top — but it decides how
        // a finding *looks*, not where it sits.
        //
        // A finding whose quote was not found has no position, so it goes last
        // rather than to the top, which is where an unset offset would put it.
        items = report.findings
            .map { Item(finding: $0, range: byID[$0.id] ?? nil) }
            .enumerated()
            .sorted { left, right in
                let leftAt = left.element.range?.location ?? Int.max
                let rightAt = right.element.range?.location ?? Int.max
                if leftAt != rightAt { return leftAt < rightAt }
                // Two findings on the same passage keep the order the critique
                // reported them in, which is worst first.
                return left.offset < right.offset
            }
            .map(\.element)
        criticisedText = text
        isRunning = false
        failure = nil
        selectedFindingID = nil
    }

    private func fail(with failure: CritiqueService.Failure) {
        self.failure = failure
        isRunning = false
        report = nil
        items = []
    }
}

// MARK: - How a severity looks

extension CritiqueSeverity {
    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    /// The accent for a card and its dot.
    var tint: Color {
        switch self {
        case .high: return Color(red: 0.85, green: 0.24, blue: 0.24)
        case .medium: return Color(red: 0.90, green: 0.60, blue: 0.10)
        case .low: return Color(red: 0.36, green: 0.55, blue: 0.80)
        }
    }

    /// The wash behind the passage in the text.
    ///
    /// Faint, because it sits under the words the author is trying to read.
    /// Google Docs' comment highlight is the reference: enough to notice, not
    /// enough to fight the text.
    var highlight: NSColor {
        switch self {
        case .high:
            return NSColor(srgbRed: 0.85, green: 0.24, blue: 0.24, alpha: 0.16)
        case .medium:
            return NSColor(srgbRed: 0.95, green: 0.66, blue: 0.13, alpha: 0.20)
        case .low:
            return NSColor(srgbRed: 0.36, green: 0.55, blue: 0.80, alpha: 0.15)
        }
    }

    /// The wash for the passage whose card is open.
    var selectedHighlight: NSColor {
        switch self {
        case .high:
            return NSColor(srgbRed: 0.85, green: 0.24, blue: 0.24, alpha: 0.34)
        case .medium:
            return NSColor(srgbRed: 0.95, green: 0.62, blue: 0.10, alpha: 0.42)
        case .low:
            return NSColor(srgbRed: 0.36, green: 0.55, blue: 0.80, alpha: 0.32)
        }
    }
}
