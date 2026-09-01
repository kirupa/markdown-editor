import Foundation
import MarkdownEditorCore
import MarkdownEditorUI
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
        /// What the author has already decided about it, if anything.
        var resolution: CritiqueResolution?

        var id: UUID { finding.id }
        var isAnchored: Bool { range != nil }
        var isOutstanding: Bool { resolution == nil }
    }

    @Published private(set) var report: CritiqueReport?
    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    /// What the critique is doing, while it is doing it.
    @Published private(set) var progress: CritiqueProgress?
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
    private var resolutions = CritiqueResolutions()
    @Published private(set) var history = CritiqueHistory()
    /// Which revision is on screen. Nil means the newest.
    @Published private(set) var shownRevisionID: UUID?
    /// The draft as it is now, so an old critique can be re-anchored to it.
    private var currentText = ""
    /// Where the decisions for the document being critiqued are kept.
    private var documentURL: URL?

    /// Closed by hand, and stays closed until asked for again.
    ///
    /// Needed once a document can have a saved critique: without it, closing
    /// the rail leaves it open and empty, because there is still a history to
    /// present. The close button then does nothing anybody can see.
    @Published private(set) var isDismissed = false

    var isPresented: Bool {
        guard !isDismissed else { return false }
        return report != nil || isRunning || failure != nil || !history.isEmpty
    }

    /// The revision being shown, when it is not the newest.
    var shownRevision: CritiqueRevision? { history.revision(withID: shownRevisionID) }

    /// How many of the shown critique's notes still point at something in the
    /// draft **as it is now**.
    ///
    /// The honest measure of an old critique's worth: not how long ago it was,
    /// but how much of the draft it described is still there.
    ///
    /// Re-anchored rather than read off `items`, whose ranges were worked out
    /// against the text as it stood when the critique was applied. Those are
    /// exactly the numbers that stop being true the moment the draft moves,
    /// which is the situation this is here to describe.
    var stillApplyingCount: Int {
        guard let report else { return 0 }
        return CritiqueAnchoring.anchor(report.findings, in: currentText)
            .filter(\.isAnchored)
            .count
    }

    /// Opens the history for a document without running anything.
    ///
    /// Called when a document is opened, so past critiques are there to read
    /// rather than only after somebody runs a new one.
    func attach(to documentURL: URL?, text: String) {
        currentText = text
        guard self.documentURL != documentURL else { return }
        self.documentURL = documentURL
        resolutions = CritiqueResolutionStore.load(for: documentURL)
        history = CritiqueHistoryStore.load(for: documentURL)
        report = nil
        items = []
        shownRevisionID = nil
        failure = nil
        isDismissed = false
        // Opening a document with a saved critique shows it, rather than an
        // empty panel beside a history badge saying two exist. It is anchored
        // against the draft as it is now, so it is immediately honest about
        // how much of itself still applies.
        if let latest = history.latest {
            apply(latest.report, for: text, record: false)
            criticisedText = latest.documentText
        }
    }

    /// Puts an earlier critique on screen, anchored against the draft as it is
    /// **now** rather than as it was.
    ///
    /// That is the whole point of being able to look back. Re-anchoring is what
    /// makes an old critique honest about itself: the notes whose sentences
    /// survive still highlight, and the ones whose sentences have been
    /// rewritten say so instead of pointing at whatever now sits at that
    /// offset.
    /// Brings the rail back after it was closed, without running anything.
    func reveal() {
        isDismissed = false
    }

    func show(revision id: UUID?) {
        guard let id, let revision = history.revision(withID: id) else {
            shownRevisionID = nil
            if let latest = history.latest {
                apply(latest.report, for: currentText, record: false)
            }
            return
        }
        shownRevisionID = id
        apply(revision.report, for: currentText, record: false)
    }

    /// Whether the document has been edited since the critique was written.
    /// Told the draft as it stands, so anything measured against "now" is.
    func noteCurrentText(_ text: String) {
        currentText = text
    }

    func isStale(against text: String) -> Bool {
        if let shown = shownRevision { return shown.isStale(against: text) }
        guard let criticisedText else { return false }
        return criticisedText != text
    }

    var anchoredCount: Int { items.filter(\.isAnchored).count }
    var outstanding: [Item] { items.filter(\.isOutstanding) }
    var resolvedCount: Int { items.count - outstanding.count }

    /// How good the draft looks, counting only what is still outstanding.
    ///
    /// Answering everything returns it to 100 — the point of the two actions
    /// is that the author has said what they meant to say, and the score
    /// should agree with them rather than keep score against them.
    var score: Int {
        CritiqueScore.score(for: outstanding.map(\.finding))
    }

    var verdict: String { CritiqueScore.verdict(score) }

    func setResolution(_ resolution: CritiqueResolution?, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].resolution = resolution
        resolutions.set(resolution, for: items[index].finding)
        CritiqueResolutionStore.save(resolutions, for: documentURL)
        // A resolved finding stops shading its passage: the whole point of
        // answering one is that it is no longer something to look at.
        if resolution != nil, selectedFindingID == id {
            selectedFindingID = nil
        }
        reorder()
    }

    /// How many findings there are at each severity, worst first.
    ///
    /// The rail is in reading order, so this is where the shape of the
    /// critique is legible at a glance — "three high" is the thing an author
    /// wants to know before reading anything.
    var severityCounts: [(severity: CritiqueSeverity, count: Int)] {
        CritiqueSeverity.allCases.compactMap { severity in
            let count = outstanding.filter { $0.finding.severity == severity }.count
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
            .filter(\.isOutstanding)
            .compactMap { item in
                item.range.map { (item.id, $0, item.finding.severity) }
            }
            .sorted { $0.severity.rank > $1.severity.rank }
    }

    func run(on text: String, documentURL: URL?) {
        guard !isRunning else { return }
        attach(to: documentURL, text: text)
        currentText = text
        isRunning = true
        isDismissed = false
        failure = nil
        progress = CritiqueProgress(stage: .starting)
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await service.critique(document: text) { update in
                    Task { @MainActor [weak self] in self?.progress = update }
                }
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
        progress = nil
    }

    func dismiss() {
        cancel()
        isDismissed = true
        failure = nil
        selectedFindingID = nil
    }

    /// Applies a report without going through the CLI. For checks only.
    func applyForChecking(_ report: CritiqueReport, for text: String) {
        apply(report, for: text)
    }

    private func apply(
        _ report: CritiqueReport,
        for text: String,
        record: Bool = true
    ) {
        let anchors = CritiqueAnchoring.anchor(report.findings, in: text)
        let byID = Dictionary(
            anchors.map { ($0.findingID, $0.range) },
            uniquingKeysWith: { first, _ in first }
        )
        // A finding the author has already answered arrives answered. Without
        // this every re-run resurrects every dismissal, and the feature nags
        // at somebody who told it not to.
        if record {
            resolutions.prune(keeping: report.findings)
            CritiqueResolutionStore.save(resolutions, for: documentURL)
            history.add(CritiqueRevision(report: report, documentText: text))
            CritiqueHistoryStore.save(history, for: documentURL)
            shownRevisionID = nil
        }
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
        items = report.findings.map {
            Item(
                finding: $0,
                range: byID[$0.id] ?? nil,
                resolution: resolutions.resolution(for: $0)
            )
        }
        reorder()
        criticisedText = record
            ? text
            : (shownRevision?.documentText ?? criticisedText ?? text)
        isRunning = false
        progress = nil
        failure = nil
        selectedFindingID = nil
    }

    /// Outstanding first in reading order, answered ones after them.
    ///
    /// Answered findings stay in the list rather than disappearing, because a
    /// decision the author cannot see is a decision they cannot take back —
    /// and because "I already dealt with that" is worth being able to check.
    private func reorder() {
        items = items
            .enumerated()
            .sorted { left, right in
                let leftDone = !left.element.isOutstanding
                let rightDone = !right.element.isOutstanding
                if leftDone != rightDone { return rightDone }
                let leftAt = left.element.range?.location ?? Int.max
                let rightAt = right.element.range?.location ?? Int.max
                if leftAt != rightAt { return leftAt < rightAt }
                // Two findings on the same passage keep the order the critique
                // reported them in, which is worst first.
                return left.offset < right.offset
            }
            .map(\.element)
    }

    private func fail(with failure: CritiqueService.Failure) {
        self.failure = failure
        isRunning = false
        progress = nil
        report = nil
        items = []
    }
}

// MARK: - How a severity looks

extension CritiqueSeverity {
    /// The same colour, dark or light enough to *read* on a wash of itself.
    ///
    /// `tint` is a fill: it is chosen to look right as a solid block — a bar,
    /// a border, a severity tag. Set as text on a 12% wash of itself it is
    /// barely there. Measured against the score banner, the amber came out at
    /// 2.0:1 and the red at 3.6:1, where readable body text wants 4.5:1.
    ///
    /// So the fills keep the bright colour and the words get this one, which
    /// is the same hue carried to a legible lightness — down on a light
    /// background, up on a dark one. Every pair below measures at or above
    /// 5:1 on the wash it is used on, and `check-critique` asserts that from
    /// the rendered pixels rather than trusting the numbers here.
    func ink(on mode: EditorAppearanceMode) -> Color {
        switch (self, mode) {
        case (.high, .light): return Color(red: 0.62, green: 0.10, blue: 0.10)
        case (.medium, .light): return Color(red: 0.52, green: 0.27, blue: 0.02)
        case (.low, .light): return Color(red: 0.13, green: 0.32, blue: 0.60)
        case (.high, .dark): return Color(red: 1.00, green: 0.60, blue: 0.58)
        case (.medium, .dark): return Color(red: 1.00, green: 0.76, blue: 0.30)
        case (.low, .dark): return Color(red: 0.62, green: 0.82, blue: 1.00)
        }
    }

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

    /// The paper a note is written on.
    ///
    /// Three colours because a pad of notes is three colours, and because it
    /// makes severity legible from across the room, before a word is read.
    /// Kept pale: the handwriting has to stay the darkest thing on it.
    var notePaper: Color {
        switch self {
        case .high: return Color(red: 1.00, green: 0.85, blue: 0.84)
        case .medium: return Color(red: 1.00, green: 0.96, blue: 0.76)
        case .low: return Color(red: 0.85, green: 0.93, blue: 1.00)
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
