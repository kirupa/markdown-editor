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
        /// Where the passage is *now*. Nil when the quote could not be found
        /// in the draft, or when an edit has since removed it.
        var range: NSRange?
        /// What the author has already decided about it, if anything.
        var resolution: CritiqueResolution?
        /// The words the note was written about, exactly as the draft had
        /// them. Nil when its quote was never found.
        ///
        /// What tells an edit from a slide. Typing above a passage moves its
        /// range and leaves these words alone; typing *in* it changes them,
        /// and only that is the author acting on the note.
        var anchoredText: String? = nil
        /// The author has rewritten the passage since the note was written.
        ///
        /// Deliberately not "fixed". That is a claim about the writing, and
        /// only a critique can make it: a rewrite can as easily keep the
        /// problem or make a new one. An edited note stops counting and waits
        /// for the next critique to say which.
        var isEdited = false
        /// The rewrite is the critic's own: the passage reads exactly as its
        /// suggestion does, applied from the note or typed to match it.
        ///
        /// Still an edit, and still waiting on a critique. The critic wrote
        /// the suggestion against the paragraph as it was, and has not read
        /// it in place; only the next critique can say it worked.
        var isApplied = false
        /// A later critique was shown this note and found the problem gone.
        var isFixed = false
        /// Where the passage sits in the draft, worked out from `range` rather
        /// than copied from the critic (see `CritiquePlace`), and kept up as
        /// the draft changes. Nil while the note has no passage, when the
        /// critic's own words for where it is are the only clue left.
        var place: CritiquePlace? = nil

        var id: UUID { finding.id }
        var isAnchored: Bool { range != nil }
        /// The critic's rewrite, when it can be put in place of the passage
        /// as the draft now reads.
        ///
        /// Only while the passage is still the very words the critic quoted.
        /// A quote found by allowing for retyping — straight quotes for curly
        /// ones, a space for a line break — would put the critic's typing in
        /// place of the author's along with the fix, and an Apply that changes
        /// more than it showed is one nobody trusts twice.
        var suggestion: String? {
            guard isOutstanding, isAnchored, anchoredText == finding.quote
            else { return nil }
            return finding.replacement
        }
        /// Still asking the author for something.
        var isOutstanding: Bool { resolution == nil && !isEdited && !isFixed }
        /// Whether it still counts against the score. See `CritiqueScore`.
        var counts: Bool { !isEdited && !isFixed && CritiqueScore.counts(resolution) }
        /// Cleared by the author — marked Done, or rewritten — and not yet
        /// looked at by a critique. While any note is, a hundred is the
        /// author's word rather than the critic's.
        var awaitsCheck: Bool { !isFixed && (resolution == .completed || isEdited) }

        /// What has become of it, strongest claim first: the critic's word
        /// over the author's, and the author's decision over their edit.
        var standing: Standing? {
            if isFixed { return .fixed }
            if resolution == .completed { return .done }
            if isEdited { return isApplied ? .applied : .edited }
            if resolution == .dismissed { return .dismissed }
            return nil
        }
    }

    /// What the tag on a note that is no longer outstanding says.
    enum Standing: Equatable {
        case fixed, done, edited, applied, dismissed

        var label: String {
            switch self {
            case .fixed: return "Fixed"
            case .done: return "Done"
            case .edited: return "Edited"
            case .applied: return "Applied"
            case .dismissed: return "Dismissed"
            }
        }
    }

    /// A change the rail makes to the draft on a note's behalf: the critic's
    /// suggestion put in place of its passage, or the passage's own words put
    /// back in place of the suggestion.
    struct Swap: Equatable {
        /// Where, in the draft as the model last saw it.
        let range: NSRange
        /// What has to be there for the swap to be made. Checked again by
        /// whatever makes it, against the text it is about to change: words
        /// that have moved on since are not replaced on the strength of a
        /// range measured before they did.
        let expected: String
        let replacement: String
        /// What Undo calls it.
        let name: String
    }

    /// Which notes a run is shown, and which it leaves alone.
    struct CarryPlan {
        /// Shown to the critic, which says what became of each.
        var asked: [Item] = []
        /// Outside what a narrowed run was asked to read, kept as they are.
        var kept: [Item] = []
        /// Whether there was a critique to carry at all. A first run has
        /// nothing to compare with, so nothing it finds is "new".
        var isCarried = false
    }

    @Published private(set) var report: CritiqueReport?
    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    /// How closely the run in progress is reading, so the rail can say it is
    /// a quick pass before the notes do.
    @Published private(set) var runningDepth: CritiqueDepth = .full
    /// What the critique is doing, while it is doing it.
    @Published private(set) var progress: CritiqueProgress?
    /// The notes the run in progress has finished writing, on the rail before
    /// the rest of the report is.
    ///
    /// Kept apart from `items` until the run lands: Stop and a failure both
    /// leave the rail as it was before the run, and that is only simple to
    /// promise if nothing of the run has been mixed into it.
    @Published private(set) var arriving: [Item] = []
    /// Every finding the run has streamed, repeats included, so the report
    /// can give each one back its identity when it lands.
    private var arrived: [CritiqueFinding] = []
    @Published private(set) var failure: CritiqueService.Failure?
    /// Which card is raised, and which highlight is drawn strongly.
    @Published var selectedFindingID: UUID?
    /// The one severity the rail and the draft are showing, or nil for all.
    ///
    /// A way of looking, not a decision: nothing is answered by it and the
    /// score still counts every note. The shading in the draft follows it as
    /// well as the rail, because a passage left shaded with its card filtered
    /// away is a highlight that opens nothing anybody can see.
    ///
    /// Back to all whenever a different critique comes on screen or a run
    /// starts. The running rail has no strip to clear it from, and a filter
    /// nobody can see the switch for reads as notes gone missing.
    @Published var severityFilter: CritiqueSeverity? {
        didSet {
            guard let severityFilter, severityFilter != oldValue else { return }
            // Hidden, the open note would be a raised card nobody can see —
            // and the keyboard's Done would answer it unseen.
            if let selected = item(withID: selectedFindingID),
               selected.finding.severity != severityFilter {
                selectedFindingID = nil
            }
            if let hovered = item(withID: hoveredFindingID),
               hovered.finding.severity != severityFilter {
                hoveredFindingID = nil
            }
        }
    }
    /// Which card the pointer is over, so its passage can answer.
    ///
    /// Kept here rather than in each card's own `@State` because the thing
    /// that has to react is not the card — it is the text, on the other side
    /// of the window. A hover nobody publishes cannot reach it.
    ///
    /// Deliberately not saved, not undoable, and not a document change: it is
    /// where the pointer is, which stops being true the moment it moves.
    @Published private(set) var hoveredFindingID: UUID?
    /// Bumped whenever the author asks to be taken to a passage.
    ///
    /// The editor scrolls once per *request*, not once per selection. Asking
    /// again for the passage that is already selected has to be a new request
    /// or clicking a card you have already opened does nothing — see
    /// `reveal(_:)`.
    @Published private(set) var revealRequests = 0
    /// The document the report was written about.
    ///
    /// Kept so the rail can say when it has gone stale. A critique describes a
    /// draft at a moment; once the words move, a highlight is pointing at an
    /// offset that no longer means what it meant.
    @Published private(set) var criticisedText: String?
    /// What the run that just landed changed: how many notes it found fixed,
    /// how many it reopened, and how many it raised for the first time.
    ///
    /// The sentence the score could not say. 45 becoming 52 says something
    /// happened; "2 fixed · 1 new" says what. Only for the run that just
    /// landed — an older critique brought back from the history is not
    /// "since the last critique" of anything.
    @Published private(set) var lastChange: CritiqueCarry.Delta?
    /// Re-run was asked for a draft the critique on screen already describes,
    /// with nothing waiting to be checked.
    ///
    /// Said rather than spent. The same draft read again costs half a minute
    /// and a request, and comes back with the same notes in other words —
    /// which reads as the critic changing its mind for no reason.
    @Published private(set) var showsUnchangedNotice = false
    /// Who the author said the draft is for: nil when they have said nothing,
    /// and empty when they cleared it to have the critic guess again.
    ///
    /// Only the author's words. The critic's guess is read off the newest
    /// critique instead — see `brief` — so that a guess is never filed away
    /// as something the author said.
    @Published private(set) var authorBrief: String?

    private let service: any CritiqueAsking
    /// Which run is the live one. A run whose number is not this one when it
    /// finishes was stopped, and lands nowhere.
    ///
    /// Stop used to kill the process and leave the task waiting on it, which
    /// then reported the kill as a failure — so stopping a re-run replaced the
    /// critique on screen with "The critique was stopped." An API request was
    /// worse: nothing cancelled it, and its report arrived after Stop as
    /// though nothing had been pressed.
    private var runNumber = 0
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

    /// The rail is always there.
    ///
    /// It used to appear only once there was something in it, which meant the
    /// feature was invisible until you already knew it existed and had found
    /// the menu item. A panel that is always present can say what it is and
    /// what it needs — which for a first run is an API key.
    var isPresented: Bool { !isDismissed }

    /// The revision being shown, when it is not the newest.
    var shownRevision: CritiqueRevision? { history.revision(withID: shownRevisionID) }

    /// The critique on screen is a quick pass: mechanics and serious problems
    /// only, so it has no score and no word on anything else.
    var isQuick: Bool {
        report != nil && (shownRevision ?? history.latest)?.isQuick == true
    }

    /// How many of the shown critique's notes still point at the words they
    /// were written about, in the draft **as it is now**.
    ///
    /// The honest measure of an old critique's worth: not how long ago it was,
    /// but how much of the draft it described is still there.
    ///
    /// Read off the notes rather than worked out again. This used to
    /// re-anchor every finding on every redraw of the rail — a search per note
    /// per keystroke — because the ranges could not be trusted to mean the
    /// same words. The notes now follow their passages through every edit and
    /// know when the words under them change, which is the same answer.
    var stillApplyingCount: Int {
        items.filter { !$0.isFixed && $0.isAnchored && !$0.isEdited }.count
    }

    /// Every note still standing: all of them but the ones found fixed.
    var standingCount: Int { items.filter { !$0.isFixed }.count }

    /// Who the next critique will hold the draft to.
    ///
    /// The author's words when they have given some. Otherwise the reader the
    /// newest critique took the draft to be for, sent back as a guess: the
    /// critic used to guess again on every run, and word it differently every
    /// time, so two critiques of the same draft could be advice for two
    /// different people. Empty before the first critique, and once the author
    /// has cleared it to be guessed afresh.
    var brief: CritiqueBrief {
        if let authorBrief { return CritiqueBrief(authorBrief) }
        return CritiqueBrief(history.latest?.reader ?? "", isGuess: true)
    }

    /// The critique on screen was written for a reader other than the one
    /// named now, so its notes are advice for somebody else.
    var isForAnotherReader: Bool {
        report != nil && shownRevisionID == nil && readerChanged(since: history.latest)
    }

    /// The author says who the draft is for.
    ///
    /// Kept per document and sent with every critique after it. Words that
    /// name the reader already in force — the guess accepted as it stands, or
    /// the same brief retyped — change nothing, so pressing Return on the line
    /// is never on its own a reason for the next critique to start over.
    func setBrief(_ text: String) {
        let text = CritiqueBrief.normalized(text)
        guard text != brief.text else { return }
        authorBrief = text
        CritiqueBriefStore.save(text, for: documentURL)
        if showsUnchangedNotice { showsUnchangedNotice = false }
    }

    /// Whether the reader named now is not the one `revision` was written for.
    private func readerChanged(since revision: CritiqueRevision?) -> Bool {
        guard let revision else { return false }
        return brief.text != revision.reader
    }

    /// The brief a run sends: nothing when there is nothing to say, so the
    /// critic guesses rather than being told the reader is nobody.
    private var briefToSend: CritiqueBrief? {
        let brief = brief
        return brief.isEmpty ? nil : brief
    }

    /// What a run of `scope` reads and carries, now that the reader is known.
    ///
    /// A different reader is a different critique rather than a revision of
    /// this one, so it reads the whole draft and carries nothing. Notes
    /// written for a beginner, re-judged for an expert, come back "still
    /// standing" or "fixed" when the truth is that they were never for this
    /// reader — and a narrowed run would leave most of them on the rail
    /// untouched. The critique for the old reader stays in the history.
    ///
    /// A quick pass reads the whole draft, and is shown only the notes the
    /// author has cleared — see `quickPlan`.
    private func reading(
        _ scope: CritiqueScope,
        depth: CritiqueDepth = .full
    ) -> (scope: CritiqueScope, plan: CarryPlan) {
        if readerChanged(since: history.latest) { return (.whole, CarryPlan()) }
        if depth == .quick { return (.whole, quickPlan()) }
        return (scope, carryPlan(for: scope))
    }

    /// Which notes a quick pass is shown: the ones marked Done or rewritten,
    /// which are waiting on a critique to say whether that worked, and which a
    /// quick pass can answer as well as a full one. The rest are kept as they
    /// stand rather than judged again by a pass that is not looking for most
    /// of what they name — and every carried note is a "previous" entry the
    /// critic has to write before it is finished, which is time a quick pass
    /// is meant not to spend.
    func quickPlan() -> CarryPlan {
        guard report != nil else { return CarryPlan() }
        var plan = CarryPlan(isCarried: true)
        for item in items where !item.isFixed {
            if item.awaitsCheck {
                plan.asked.append(item)
            } else {
                plan.kept.append(item)
            }
        }
        return plan
    }

    /// Notes nothing in the draft matches, and never did since they were
    /// written. A passage the author deleted is an edit, not a failure to
    /// match, and is not counted here.
    var unmatchedCount: Int {
        items.filter { !$0.isFixed && !$0.isEdited && !$0.isAnchored }.count
    }

    /// Nil is the real service. Not a default argument of `CritiqueService()`:
    /// the check harness compiles these sources in the Swift 5 language mode,
    /// which will not call a main-actor initializer from a default argument.
    init(service: (any CritiqueAsking)? = nil) {
        self.service = service ?? CritiqueService()
    }

    /// Opens the history for a document without running anything.
    ///
    /// Called when a document is opened, so past critiques are there to read
    /// rather than only after somebody runs a new one. For the document that
    /// is already open it is only the draft as it stands, and goes the way
    /// every other edit does.
    func attach(to documentURL: URL?, text: String) {
        guard self.documentURL != documentURL else {
            // Through `noteCurrentText` rather than by assigning it. This used
            // to set the text before the guard, so a run that attached first
            // left `noteCurrentText` nothing to move.
            noteCurrentText(text)
            return
        }
        self.documentURL = documentURL
        currentText = text
        resolutions = CritiqueResolutionStore.load(for: documentURL)
        history = CritiqueHistoryStore.load(for: documentURL)
        authorBrief = CritiqueBriefStore.load(for: documentURL)
        report = nil
        items = []
        shownRevisionID = nil
        criticisedText = nil
        failure = nil
        isDismissed = false
        lastChange = nil
        showsUnchangedNotice = false
        selectedFindingID = nil
        hoveredFindingID = nil
        severityFilter = nil
        // Opening a document with a saved critique shows it, rather than an
        // empty panel beside a history badge saying two exist. It is anchored
        // against the draft as it is now, so it is immediately honest about
        // how much of itself still applies.
        if let latest = history.latest { present(latest) }
    }

    /// The open document was saved somewhere new: its first save, a Save As,
    /// or a rename while it was open.
    ///
    /// It is the same document under a new name, so its critique goes with
    /// it. This used to go through `attach`, which takes a new address for a
    /// new document: the first ⌘S of an untitled draft emptied the rail and
    /// threw away the critique that had just been run on it, and a Save As
    /// did the same to a document with a history.
    func move(to newURL: URL?, text: String) {
        guard documentURL != newURL else {
            noteCurrentText(text)
            return
        }
        // Nothing to take along, so whatever is kept under the new address is
        // this window's to show. Saving an empty critique over it would erase
        // a history for no gain.
        guard !history.isEmpty || authorBrief != nil || !resolutions.isEmpty else {
            attach(to: newURL, text: text)
            return
        }
        documentURL = newURL
        noteCurrentText(text)
        CritiqueHistoryStore.save(history, for: newURL)
        CritiqueResolutionStore.save(resolutions, for: newURL)
        CritiqueBriefStore.save(authorBrief, for: newURL)
    }

    /// Brings the rail back after it was closed, without running anything.
    func reveal() {
        isDismissed = false
    }

    /// Puts an earlier critique on screen, anchored against the draft as it is
    /// **now** rather than as it was.
    ///
    /// That is the whole point of being able to look back. Re-anchoring is what
    /// makes an old critique honest about itself: the notes whose sentences
    /// survive still highlight, and the ones whose sentences have been
    /// rewritten say so instead of pointing at whatever now sits at that
    /// offset.
    func show(revision id: UUID?) {
        guard let id, let revision = history.revision(withID: id) else {
            shownRevisionID = nil
            if let latest = history.latest { present(latest) }
            return
        }
        shownRevisionID = id
        present(revision)
    }

    /// The draft changed. Move the marks with the words they are about.
    ///
    /// Without this a critique is only correct at the instant it is anchored:
    /// one character typed above a passage and every mark below it is off by
    /// one, and by a paragraph after a paragraph. They drift quietly, which is
    /// worse than being obviously wrong — the shading still looks deliberate
    /// while pointing at the wrong sentence.
    ///
    /// The edit is derived from the two texts rather than observed from the
    /// text view, so a change from anywhere moves them: a revert from disk and
    /// another app's rewrite land here the same way typing does.
    ///
    /// It also notices when the words *under* a note change, which is the
    /// author acting on it. That note stops counting at once — the rail used
    /// to keep scoring a sentence that had already been rewritten until the
    /// author found its card and pressed Done — and it is not moved, so the
    /// advice stays where it was being read while the rewrite happens.
    func noteCurrentText(_ text: String) {
        let previous = currentText
        guard previous != text else { return }
        currentText = text
        if showsUnchangedNotice { showsUnchangedNotice = false }
        guard !items.isEmpty || !arriving.isEmpty,
              let edit = CritiqueAnchorTracking.edit(from: previous, to: text)
        else { return }
        if !arriving.isEmpty {
            var early = arriving.map { Self.follow($0, through: edit, in: text) }
            early = placing(early, after: arriving, through: edit, from: previous, to: text)
            if early != arriving { arriving = early }
        }
        var moved = items.map { Self.follow($0, through: edit, in: text) }
        // A second pass, so a note looking for its words again steers clear of
        // where every other note has already settled.
        //
        // Not for a passage that now reads as the critic suggested. Its old
        // words are often still inside the new ones — "good" in "good
        // enough" — and finding them there would put the note straight back
        // on the words it had just been applied to.
        for index in moved.indices where moved[index].isEdited && !moved[index].isApplied {
            let others = moved.indices.filter { $0 != index }.compactMap { moved[$0].range }
            if let found = Self.refind(moved[index], after: edit, in: text, avoiding: others) {
                moved[index].range = found
                moved[index].isEdited = false
            }
        }
        moved = placing(moved, after: items, through: edit, from: previous, to: text)
        // Assigned once, and only when something moved: every assignment is a
        // redraw of the rail, and this runs on every keystroke.
        if moved != items { items = moved }
    }

    /// The outline of the draft the places were last worked out in.
    private var outlineCache: (text: String, outline: CritiqueOutline)?

    private func outline(of text: String) -> CritiqueOutline {
        if let cache = outlineCache, cache.text == text { return cache.outline }
        let outline = CritiqueOutline(text)
        outlineCache = (text, outline)
        return outline
    }

    private static func placed(_ items: [Item], in outline: CritiqueOutline) -> [Item] {
        items.map { item in
            var item = item
            item.place = item.range.flatMap(outline.place(of:))
            return item
        }
    }

    /// Notes carried through an edit, named for where they now are.
    ///
    /// Typing inside a paragraph — nearly every keystroke — slides every
    /// block after it by the same amount as every note, so no note's place
    /// changes and the draft is not read again. Only an edit that changes the
    /// draft's shape re-reads it; otherwise only a note the edit took
    /// somewhere new, found again or matched to its suggestion, is placed
    /// afresh.
    private func placing(
        _ moved: [Item],
        after before: [Item],
        through edit: CritiqueAnchorTracking.Edit,
        from previous: String,
        to text: String
    ) -> [Item] {
        if CritiqueOutline.mayMovePlaces(from: previous, to: text, through: edit) {
            return Self.placed(moved, in: outline(of: text))
        }
        var moved = moved
        for index in moved.indices {
            guard let range = moved[index].range else {
                moved[index].place = nil
                continue
            }
            let slid = before[index].range.flatMap { CritiqueAnchorTracking.adjust($0, for: edit) }
            if range == slid, moved[index].place != nil { continue }
            moved[index].place = outline(of: text).place(of: range)
        }
        return moved
    }

    /// One note carried through one edit.
    private static func follow(
        _ item: Item,
        through edit: CritiqueAnchorTracking.Edit,
        in text: String
    ) -> Item {
        guard !item.isFixed, let range = item.range else { return item }
        var item = item
        let moved = CritiqueAnchorTracking.adjust(range, for: edit)
        item.range = moved
        // Inside, by the same boundaries `adjust` uses: an insertion at either
        // end of a passage is beside it, not in it, and typing a new sentence
        // after a criticised one is not rewriting it.
        let touched = edit.location < range.location + range.length
            && edit.removedEnd > range.location
        // Beside the passage, not in it — unless what arrived beside it makes
        // the passage read as the critic suggested. A suggestion that keeps
        // the quoted words and adds to them, "good" to "good enough", is
        // exactly that: a Redo of an Apply that was undone, or the suggestion
        // typed in by hand a letter at a time, lands entirely outside the
        // passage. Left alone, the note would go on offering to apply itself
        // to a draft that already has, and Apply would make "good enough
        // enough".
        guard touched else {
            guard !item.isEdited, let moved,
                  let suggested = item.finding.replacement
            else { return item }
            let reach = (suggested as NSString).length
            let isNear = edit.location + edit.inserted >= moved.location - reach
                && edit.location <= moved.location + moved.length + reach
            if isNear, let applied = appliedSuggestion(of: item.finding, quotedAt: moved, in: text) {
                item.range = applied
                item.isEdited = true
                item.isApplied = true
            }
            return item
        }
        if let words = item.anchoredText, let moved {
            // An applied suggestion taken back — Undo, or its new words
            // deleted by hand — leaves the passage's own words at its start
            // again, shorter or longer by exactly the swap. Checked before
            // the passage is read, because the edit that does it is often
            // worked out as starting a character late: "good enough for" back
            // to "good for" is found as "enough " removed rather than
            // " enough", so the passage keeps its space and reads "good ",
            // and nothing near the edit is "good" to find again.
            let back = NSRange(location: range.location, length: (words as NSString).length)
            if item.isApplied,
               edit.location >= range.location,
               edit.delta == back.length - range.length,
               passage(back, in: text) == words {
                item.range = back
                item.isEdited = false
                item.isApplied = false
                return item
            }
            let reads = passage(moved, in: text)
            item.isEdited = reads != words
            item.isApplied = item.isEdited && reads == item.finding.replacement
        } else {
            item.isEdited = true
            item.isApplied = false
        }
        return item
    }

    /// Where a rewritten note's own words are again, when this edit is what
    /// put them back.
    ///
    /// Undo is the case that matters. Deleting the end of a sentence shortens
    /// its passage, and undoing it inserts the words *at the end* — beside the
    /// passage, by the rule above, so they never rejoin it, and a note the
    /// author has taken straight back would stay Edited. Looking for the
    /// words around the edit finds them; requiring the match to include the
    /// edit keeps an unrelated copy of the sentence nearby from claiming it.
    private static func refind(
        _ item: Item,
        after edit: CritiqueAnchorTracking.Edit,
        in text: String,
        avoiding claimed: [NSRange]
    ) -> NSRange? {
        guard let words = item.anchoredText, !words.isEmpty else { return nil }
        let length = (words as NSString).length
        let editStart = edit.location
        let editEnd = edit.location + edit.inserted
        let lower: Int
        let upper: Int
        if let range = item.range {
            guard editStart <= range.location + range.length, editEnd >= range.location
            else { return nil }
            lower = min(range.location, editStart) - length
            upper = max(range.location + range.length, editEnd) + length
        } else {
            // A passage deleted outright can only come back whole.
            guard edit.inserted >= length else { return nil }
            lower = editStart - length
            upper = editEnd + length
        }
        let source = text as NSString
        let windowStart = max(0, lower)
        let windowEnd = min(source.length, upper)
        var from = windowStart
        var fallback: NSRange?
        while windowEnd - from >= length {
            let found = source.range(
                of: words,
                options: .literal,
                range: NSRange(location: from, length: windowEnd - from)
            )
            guard found.location != NSNotFound else { break }
            let includesEdit = found.location <= editEnd && NSMaxRange(found) >= editStart
            let isFree = !claimed.contains { NSIntersectionRange($0, found).length > 0 }
            if includesEdit, isFree {
                if let range = item.range, NSIntersectionRange(range, found).length > 0 {
                    return found
                }
                if fallback == nil { fallback = found }
            }
            from = found.location + 1
        }
        return fallback
    }

    /// The words at `range`, without copying the whole draft to find them.
    ///
    /// Not `CritiqueChangeScope.passage`, which builds an array of every UTF-16
    /// unit in the document first. That is fine once per run and not once per
    /// keystroke.
    private static func passage(_ range: NSRange, in text: String) -> String? {
        if let bounds = Range(range, in: text) { return String(text[bounds]) }
        let source = text as NSString
        guard NSMaxRange(range) <= source.length else { return nil }
        return source.substring(with: range)
    }

    /// Whether the document has been edited since the critique was written.
    func isStale(against text: String) -> Bool {
        if let shown = shownRevision { return shown.isStale(against: text) }
        guard let criticisedText else { return false }
        return criticisedText != text
    }

    var anchoredCount: Int { items.filter(\.isAnchored).count }
    var outstanding: [Item] { items.filter(\.isOutstanding) }
    /// Notes the author has dealt with — Done, dismissed or rewritten. A note
    /// found fixed is the critic's doing rather than the author's, and is not
    /// one of them.
    var resolvedCount: Int { items.filter { !$0.isOutstanding && !$0.isFixed }.count }
    var dismissedCount: Int {
        items.filter { $0.resolution == .dismissed && $0.counts }.count
    }
    /// The problems the summary names, which count against the score.
    var listedProblems: Int { report?.whatDoesNotWork.count ?? 0 }

    /// How good the draft looks: what is outstanding, what was dismissed, and
    /// what the summary still lists. See `CritiqueScore` for why Done clears a
    /// note and Dismiss does not; a rewritten note and a fixed one are cleared
    /// too, because the passage the note was about is not there any more.
    var score: Int {
        CritiqueScore.score(
            for: items.filter(\.counts).map(\.finding),
            listedProblems: listedProblems
        )
    }

    /// Whether the score is the critic's own rather than the author's: a
    /// critique of the text exactly as it stands, with nothing marked Done or
    /// rewritten since. Only then is a hundred "Ready".
    ///
    /// Never after a quick pass, which did not read for most of what the
    /// score counts. A clean one means no typos and nothing seriously wrong.
    var isConfirmed: Bool {
        !isQuick && !isStale(against: currentText) && !items.contains(where: \.awaitsCheck)
    }

    var verdict: String { CritiqueScore.verdict(score, isConfirmed: isConfirmed) }

    func setResolution(_ resolution: CritiqueResolution?, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !items[index].isFixed
        else { return }
        var item = items[index]
        item.resolution = resolution
        // Putting a rewritten note back says the rewrite did not deal with
        // it. From here on it is about the passage as it now reads.
        if resolution == nil, item.isEdited, let range = item.range,
           let words = Self.passage(range, in: currentText) {
            item.anchoredText = words
            item.isEdited = false
            item.isApplied = false
        }
        items[index] = item
        resolutions.set(resolution, for: item.finding)
        CritiqueResolutionStore.save(resolutions, for: documentURL)
        // A resolved finding stops shading its passage: the whole point of
        // answering one is that it is no longer something to look at.
        if resolution != nil, selectedFindingID == id {
            selectedFindingID = nil
        }
        // And it stops answering the pointer, for the same reason: a note
        // being dealt with moves down the rail under the pointer, and a
        // highlight left lit by a card that is no longer there points at
        // nothing the reader can see.
        if resolution != nil, hoveredFindingID == id {
            hoveredFindingID = nil
        }
        // Something now waits on a critique, so "nothing has changed" no
        // longer holds.
        if showsUnchangedNotice { showsUnchangedNotice = false }
        reorder()
    }

    /// Puts the critic's suggestion in place of a note's passage.
    ///
    /// `replace` makes the change — the draft belongs to the editor, not to
    /// the critique — and returns the draft as it then reads, or nil when it
    /// found other words at the range and changed nothing. Returns whether
    /// the note now stands applied.
    ///
    /// The note is not moved down the rail. It stays where the author pressed
    /// it, tagged Applied, with the way back on it: a suggestion is read once
    /// it is in its paragraph, and that is the moment somebody wants to take
    /// it back.
    @discardableResult
    func applySuggestion(for id: UUID, using replace: (Swap) -> String?) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let suggested = items[index].suggestion,
              let range = items[index].range
        else { return false }
        let finding = items[index].finding
        // The draft already reads as the suggestion: typed in by hand where
        // nothing noticed, or a critique that suggested what was there. Said
        // rather than done again — applying it would repeat its words.
        if let inPlace = Self.appliedSuggestion(of: finding, quotedAt: range, in: currentText) {
            items[index].range = inPlace
            items[index].place = outline(of: currentText).place(of: inPlace)
            items[index].isEdited = true
            items[index].isApplied = true
            if showsUnchangedNotice { showsUnchangedNotice = false }
            return true
        }
        guard Self.passage(range, in: currentText) == finding.quote,
              let text = replace(Swap(
                range: range,
                expected: finding.quote,
                replacement: suggested,
                name: "Apply Suggestion"
              ))
        else { return false }
        noteSwapped(at: range, to: suggested, for: id, giving: text)
        return true
    }

    /// Puts a note's own words back in place of the suggestion applied to it.
    ///
    /// The same as ⌘Z when the Apply was the last thing done, and still there
    /// when it was not: undo walks back through everything typed since, and
    /// this takes back only the one passage.
    @discardableResult
    func revertSuggestion(for id: UUID, using replace: (Swap) -> String?) -> Bool {
        guard let item = item(withID: id),
              item.isApplied,
              item.resolution == nil,
              let range = item.range,
              let words = item.anchoredText,
              let suggested = item.finding.replacement,
              Self.passage(range, in: currentText) == suggested,
              let text = replace(Swap(
                range: range,
                expected: suggested,
                replacement: words,
                name: "Revert Suggestion"
              ))
        else { return false }
        noteSwapped(at: range, to: words, for: id, giving: text)
        return true
    }

    /// The draft changed because the rail changed it, at a range it knows.
    ///
    /// Told rather than left to `noteCurrentText` to work out. That derives
    /// the edit from the two texts by their common prefix and suffix, which
    /// is a guess about *where* the words changed — and a suggestion that
    /// starts or ends with the words already beside the passage moves the
    /// guess outside it, where an edit is typing beside a note rather than
    /// rewriting it.
    private func noteSwapped(
        at range: NSRange,
        to words: String,
        for id: UUID,
        giving text: String
    ) {
        noteCurrentText(text)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        item.range = NSRange(location: range.location, length: (words as NSString).length)
        item.place = item.range.flatMap(outline(of: text).place(of:))
        item.isEdited = words != item.anchoredText
        item.isApplied = item.isEdited && words == item.finding.replacement
        if item != items[index] { items[index] = item }
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
        return items.first { $0.id == id } ?? arriving.first { $0.id == id }
    }

    /// What pressing a note in the rail does.
    ///
    /// Here rather than in the view because it is a decision, and a decision
    /// in a view builder is a decision nothing can check. The one it used to
    /// make was a toggle — see `reveal(_:)` for why that was wrong.
    ///
    /// A rewritten note can still be pressed: it is the one the author is in
    /// the middle of, and being taken back to its passage is the point.
    func press(_ item: Item) {
        guard item.resolution == nil, !item.isFixed else { return }
        reveal(item.id)
    }

    /// Open a finding's note and take the reader to its passage.
    ///
    /// The one thing this deliberately does not do is toggle. Pressing a card
    /// that is already open used to turn the selection *off*, which is the
    /// opposite of what somebody pressing it a second time is asking for —
    /// they are asking to be taken there again, usually because the first
    /// press did not appear to do anything. Turning the mark off at that
    /// moment reads as the app going further backwards.
    ///
    /// Asking again is a new request rather than a no-op, which is what the
    /// counter is for: the editor reveals once per request, so the same
    /// finding can be revealed twice while an unrelated redraw still cannot
    /// steal the reader's scroll position.
    func reveal(_ id: UUID) {
        selectedFindingID = id
        revealRequests += 1
    }

    /// Whether the severity filter lets a note through.
    func matchesFilter(_ item: Item) -> Bool {
        severityFilter.map { item.finding.severity == $0 } ?? true
    }

    /// The notes Next and Previous walk through: the ones still asking for
    /// something that the filter shows, in the order their passages come in
    /// the draft.
    ///
    /// The draft's order rather than the rail's. The two only part while a run
    /// is out, when its new notes sit above the old ones; somebody stepping
    /// through is reading the draft, and a Next that jumped back up the page
    /// to reach a new note would lose their place in it. A note with no
    /// passage comes last, as it does on the rail.
    var steppableNotes: [Item] {
        (items + arriving)
            .enumerated()
            .filter { $0.element.isOutstanding && matchesFilter($0.element) }
            .sorted {
                let left = $0.element.range?.location ?? Int.max
                let right = $1.element.range?.location ?? Int.max
                return left == right ? $0.offset < $1.offset : left < right
            }
            .map(\.element)
    }

    var canStepNotes: Bool { !steppableNotes.isEmpty }

    /// The open note can be marked Done or dismissed: it is still asking for
    /// something, and it is part of a critique that has landed. The same
    /// notes the stamps are drawn on, so the keys never answer a note the
    /// pointer could not.
    var canAnswerSelected: Bool {
        guard let id = selectedFindingID,
              let item = items.first(where: { $0.id == id })
        else { return false }
        return item.isOutstanding
    }

    /// The open note has a suggestion that can be put in place.
    var canApplySelected: Bool {
        guard canAnswerSelected, let id = selectedFindingID else { return false }
        return items.first { $0.id == id }?.suggestion != nil
    }

    /// Opens the next note still to be answered and takes the reader to its
    /// passage. See `selectPrevious` for the way back.
    ///
    /// From the open note when it is one of them; from where its passage is
    /// when it is not, because a note being rewritten has stopped asking and
    /// Next from it should carry on down the draft rather than start at the
    /// top. With nothing open, Next starts at the top and Previous at the
    /// bottom. Both wrap, so the notes skipped on the way down come round
    /// again.
    ///
    /// Brings a closed rail back: the key asks to see a note, and selecting
    /// one behind a closed rail would show nothing at all.
    func selectNext() { step(by: 1) }

    func selectPrevious() { step(by: -1) }

    private func step(by offset: Int) {
        guard let target = neighbour(of: selectedFindingID, by: offset, in: steppableNotes)
        else { return }
        if isDismissed { isDismissed = false }
        reveal(target.id)
    }

    /// Marks the open note Done or dismisses it from the keyboard, and opens
    /// the next one.
    ///
    /// Moving on is what the stamp does not do. A click answers the note under
    /// the pointer and the next is right there below it; from the keyboard
    /// nothing is under anything, and a Done that left nothing open would ask
    /// for a Next after every answer.
    func answerSelected(_ resolution: CritiqueResolution) {
        guard canAnswerSelected, let id = selectedFindingID else { return }
        // Worked out first, while the note still has its place in the order.
        var next = neighbour(of: id, by: 1, in: steppableNotes)
        if next?.id == id { next = nil }
        setResolution(resolution, for: id)
        if let next { reveal(next.id) }
    }

    private func neighbour(of id: UUID?, by offset: Int, in notes: [Item]) -> Item? {
        guard !notes.isEmpty else { return nil }
        if let id, let index = notes.firstIndex(where: { $0.id == id }) {
            return notes[(index + offset % notes.count + notes.count) % notes.count]
        }
        if let id, let location = item(withID: id)?.range?.location {
            if offset > 0 {
                return notes.first { ($0.range?.location ?? Int.max) >= location }
                    ?? notes.first
            }
            return notes.last { ($0.range?.location ?? Int.max) < location }
                ?? notes.last
        }
        return offset > 0 ? notes.first : notes.last
    }

    /// Note that the pointer has arrived over a finding's card.
    func hover(_ id: UUID) {
        hoveredFindingID = id
    }

    /// Note that the pointer has left a finding's card.
    ///
    /// Takes the card's own identifier and ignores the call when some other
    /// card has since claimed the pointer. Moving between two adjacent cards
    /// delivers the new card's arrival *before* the old card's departure often
    /// enough to matter, and clearing unconditionally turns the new highlight
    /// straight back off — which on screen is a flicker rather than a move.
    func endHover(_ id: UUID) {
        guard hoveredFindingID == id else { return }
        hoveredFindingID = nil
    }

    /// The highlight ranges, worst last so a high finding is drawn over a low
    /// one where two passages overlap.
    ///
    /// A rewritten note stops shading its passage like any answered one —
    /// except while it is the note selected. That is the author mid-rewrite,
    /// and the shading is what shows them how far the passage still runs.
    var highlights: [(id: UUID, range: NSRange, severity: CritiqueSeverity)] {
        (items + arriving)
            .filter {
                ($0.isOutstanding
                    || ($0.isEdited && $0.resolution == nil && $0.id == selectedFindingID))
                    && matchesFilter($0)
            }
            .compactMap { item in
                item.range.map { (item.id, $0, item.finding.severity) }
            }
            .sorted { $0.severity.rank > $1.severity.rank }
    }

    /// What a re-run would read if the author does not say otherwise.
    ///
    /// The changed paragraphs when there is a previous critique to keep, the
    /// text has moved, and the change is small enough to be worth narrowing.
    /// Otherwise everything — including, deliberately, the case where the edit
    /// has grown to cover most of the draft, where a partial run would keep
    /// almost nothing and cost the same, and the case where the reader has
    /// changed, which no passage of the old critique was written for.
    ///
    /// And everything after a quick pass. It read the whole draft for typos
    /// and serious problems only, so the paragraphs that did not change have
    /// never been read for anything else; a full critique of the changes
    /// alone would score a draft most of which nobody had looked at.
    var defaultScope: CritiqueScope {
        guard report != nil, let criticisedText, criticisedText != currentText,
              !readerChanged(since: history.latest), history.latest?.isQuick != true
        else { return .whole }
        guard
            let changed = CritiqueChangeScope.changedParagraphs(
                from: criticisedText, to: currentText
            ),
            CritiqueChangeScope.isWorthScoping(changed, in: currentText)
        else { return .whole }
        return .changes(changed)
    }

    /// Whether a narrowed re-run is on the table at all, for the UI to ask.
    var canCritiqueChangesOnly: Bool {
        if case .changes = defaultScope { return true }
        return false
    }

    /// Which notes a run of `scope` is shown.
    ///
    /// All of them for the whole draft. For the changed paragraphs, the notes
    /// in them — and every note the author has cleared, wherever it is: a
    /// note marked Done is waiting on exactly this, and a narrowed run that
    /// left it out would leave it waiting. The rest are kept as they are.
    func carryPlan(for scope: CritiqueScope) -> CarryPlan {
        guard report != nil else { return CarryPlan() }
        // Fixed notes were the last run's news. They are not carried again.
        let standing = items.filter { !$0.isFixed }
        guard case .changes(let changed) = scope else {
            return CarryPlan(asked: standing, isCarried: true)
        }
        var plan = CarryPlan(isCarried: true)
        let survives = CritiqueChangeScope.surviving(standing.map(\.range), changed: changed)
        for (item, isOutside) in zip(standing, survives) {
            if isOutside, !item.awaitsCheck {
                plan.kept.append(item)
            } else {
                plan.asked.append(item)
            }
        }
        return plan
    }

    /// What re-run, Critique ▸ Critique Document and ⌃⌘C do.
    ///
    /// Reads what changed, and declines to read again what did not. A
    /// critique of the draft exactly as it stands, with nothing marked Done
    /// or rewritten since, already says everything a second one would — and a
    /// second one says it in other words, which reads as the critic changing
    /// its mind. The rail says so instead and offers the run anyway.
    ///
    /// Unless the reader has changed: the same draft held to somebody else is
    /// a question the critique on screen has not answered. Nor is a full
    /// critique declined after a quick pass of the same draft, which did not
    /// ask most of what a full one does. A quick pass is declined after either:
    /// a full critique has already said everything a quick pass could.
    func request(on text: String, documentURL: URL?, depth: CritiqueDepth = .full) {
        guard !isRunning else { return }
        attach(to: documentURL, text: text)
        if shownRevisionID != nil { show(revision: nil) }
        if report != nil, failure == nil, !isStale(against: text),
           !items.contains(where: \.awaitsCheck), !readerChanged(since: history.latest),
           depth == .quick || !isQuick {
            isDismissed = false
            showsUnchangedNotice = true
            return
        }
        run(on: text, documentURL: documentURL, scope: defaultScope, depth: depth)
    }

    /// `depth` is a full critique or a quick pass. A quick pass always reads
    /// the whole draft, whatever `scope` says: it is fast because of what it
    /// is asked to report, not because of how much it reads.
    func run(
        on text: String,
        documentURL: URL?,
        scope: CritiqueScope = .whole,
        depth: CritiqueDepth = .full
    ) {
        guard !isRunning else { return }
        // The notes are moved onto the new text *before* the scope is used, so
        // that the ranges being compared against the changed passage address
        // the same string the passage was measured in.
        attach(to: documentURL, text: text)
        isDismissed = false
        lastChange = nil
        if showsUnchangedNotice { showsUnchangedNotice = false }
        // Answered here, before anything spins: the service would refuse it
        // too, but only after the rail had flashed "Starting" for a request
        // that was never going to be made.
        if let words = CritiqueRequest.shortfall(in: text) {
            fail(with: .draftTooShort(words: words))
            return
        }
        // A run carries on from the newest critique, whichever is on screen.
        // Carrying an older one forward would drop every note the newest one
        // added since.
        if shownRevisionID != nil { show(revision: nil) }
        isRunning = true
        runningDepth = depth
        severityFilter = nil
        failure = nil
        progress = CritiqueProgress(stage: .starting)
        arriving = []
        arrived = []
        runNumber += 1
        let thisRun = runNumber

        let (scope, plan) = reading(scope, depth: depth)
        let focus: String?
        if case .changes(let range) = scope {
            focus = CritiqueChangeScope.passage(range, in: text)
        } else {
            focus = nil
        }
        let previous = CritiqueCarry.previousNotes(plan.asked.map(\.finding))
        // What a new note must not repeat, for the same reason `land` drops
        // repeats: a carried note said again in other words is not news.
        let standing = plan.isCarried ? (plan.kept + plan.asked).map(\.finding) : []
        // Taken now: the author may correct the reader while this run is
        // out, and the critique has to be filed under the reader it was
        // actually written for.
        let sent = briefToSend

        Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await service.critique(
                    document: text,
                    focus: focus,
                    previous: previous,
                    brief: sent,
                    depth: depth
                ) { [weak self] update in
                    Task { @MainActor [weak self] in
                        // `isRunning` as well as the run number: the last
                        // update can be queued behind the answer itself, and
                        // taken after the landing it would put the early
                        // notes back on the rail beside their landed copies.
                        guard let self, self.runNumber == thisRun, self.isRunning else { return }
                        self.progress = update
                        self.receive(update.findings, standing: standing)
                    }
                }
                guard self.runNumber == thisRun else { return }
                self.land(answer, for: text, plan: plan, brief: sent, depth: depth)
            } catch let error as CritiqueService.Failure {
                guard self.runNumber == thisRun else { return }
                self.fail(with: error)
            } catch {
                guard self.runNumber == thisRun else { return }
                self.fail(
                    with: .cliFailed(status: -1, message: error.localizedDescription)
                )
            }
        }
    }

    /// Stops the run in progress and keeps whatever was on screen before it.
    func cancel() {
        guard isRunning else { return }
        runNumber += 1
        service.cancel()
        isRunning = false
        progress = nil
        letGoOfArrivals()
    }

    /// Puts a run's early notes away when it does not land.
    ///
    /// Stop means the rail goes back to what it showed before the run, and
    /// half a report is not a critique: no score, no summary and nothing in
    /// the history to come back to.
    private func letGoOfArrivals() {
        if let selected = selectedFindingID, arriving.contains(where: { $0.id == selected }) {
            selectedFindingID = nil
        }
        if let hovered = hoveredFindingID, arriving.contains(where: { $0.id == hovered }) {
            hoveredFindingID = nil
        }
        arriving = []
        arrived = []
    }

    /// Shows the notes the run has finished writing so far.
    ///
    /// Anchored against the draft as it is now — the author may be typing
    /// while the critic writes — and ordered as the rail orders everything,
    /// by where they are in the draft, so the order they arrive in is the
    /// order they stay in when the run lands. A note the author has already
    /// answered is not news and waits for the landing to be shown, answered.
    private func receive(_ findings: [CritiqueFinding], standing: [CritiqueFinding]) {
        guard findings.count > arrived.count else { return }
        let new = findings[arrived.count...]
        arrived.append(contentsOf: new)
        var shown = arriving
        var claimed = (items + arriving).compactMap(\.range)
        for finding in new {
            if !standing.isEmpty, CritiqueCarry.isRepeat(finding, of: standing) { continue }
            guard resolutions.resolution(for: finding) == nil else { continue }
            let range = CritiqueAnchoring.range(for: finding, in: currentText, avoiding: claimed)
            if let range { claimed.append(range) }
            shown.append(Item(
                finding: finding,
                range: range,
                resolution: nil,
                anchoredText: range.flatMap { Self.passage($0, in: currentText) }
            ))
        }
        let ordered = Self.ordered(Self.placed(shown, in: outline(of: currentText)))
        if ordered != arriving { arriving = ordered }
    }

    /// The report's findings under the identities they arrived with.
    ///
    /// The finished reply is decoded again, which gives every finding a new
    /// identity. Matched back by what they say, the cards on the rail stay
    /// the same cards: no flash as they are replaced, and a note pressed
    /// while the run was out is still the note that is open.
    static func keepingArrivalIDs(
        _ findings: [CritiqueFinding],
        arrived: [CritiqueFinding]
    ) -> [CritiqueFinding] {
        var unclaimed = arrived
        return findings.map { finding in
            guard let index = unclaimed.firstIndex(where: {
                finding.identified(as: $0.id) == $0
            }) else { return finding }
            return unclaimed.remove(at: index)
        }
    }

    func dismiss() {
        cancel()
        isDismissed = true
        failure = nil
        selectedFindingID = nil
        hoveredFindingID = nil
        if showsUnchangedNotice { showsUnchangedNotice = false }
    }

    /// Applies a report without going through the CLI. For checks only.
    ///
    /// The text becomes the draft as it stands, as it does when `run` is
    /// given it: a report is only ever applied to the text it was asked about,
    /// and a check that left "now" empty saw every critique as out of date.
    /// Nothing is carried — this is a first critique, or a fresh one.
    func applyForChecking(_ report: CritiqueReport, for text: String) {
        noteCurrentText(text)
        land(
            CritiqueAnswer(report: report), for: text, plan: CarryPlan(),
            brief: briefToSend, depth: .full
        )
    }

    /// Lands a re-run the way a real one would, so carrying notes through it
    /// can be checked without spending a request.
    ///
    /// Deliberately goes through the same `reading` and `land` as `run`
    /// rather than reimplementing them — a check against a parallel copy of
    /// the merge would pass while the real one lost notes.
    func applyRerunForChecking(
        _ report: CritiqueReport,
        for text: String,
        scope: CritiqueScope = .whole,
        verdicts: [String: CritiqueNoteVerdict] = [:],
        depth: CritiqueDepth = .full
    ) {
        noteCurrentText(text)
        land(
            CritiqueAnswer(report: report, verdicts: verdicts),
            for: text,
            plan: reading(scope, depth: depth).plan,
            brief: briefToSend,
            depth: depth
        )
    }

    /// A narrowed re-run, for the checks written before notes were carried.
    func applyChangesForChecking(
        _ report: CritiqueReport,
        for text: String,
        changed: NSRange,
        verdicts: [String: CritiqueNoteVerdict] = [:]
    ) {
        applyRerunForChecking(report, for: text, scope: .changes(changed), verdicts: verdicts)
    }

    /// Puts a saved critique on screen against the draft as it is now.
    ///
    /// Each note is found twice — in the text it was written about and in the
    /// text as it stands — and the two compared, so a note whose sentence was
    /// rewritten while the document was closed opens as Edited rather than
    /// as a complaint about words that are no longer there.
    ///
    /// Leaves a run in progress alone. This used to go through the same path
    /// as a finished run, which set `isRunning` back to false: anything that
    /// put a saved critique up mid-run made the rail look stopped while the
    /// request carried on.
    private func present(_ revision: CritiqueRevision) {
        var shown = anchoredItems(
            revision.report.findings,
            then: revision.documentText,
            now: currentText
        )
        shown += (revision.fixed ?? []).map {
            Item(finding: $0, range: nil, resolution: nil, isFixed: true)
        }
        report = revision.report
        items = Self.ordered(Self.placed(shown, in: outline(of: currentText)))
        criticisedText = revision.documentText
        selectedFindingID = nil
        hoveredFindingID = nil
        severityFilter = nil
        lastChange = nil
        if showsUnchangedNotice { showsUnchangedNotice = false }
    }

    private func anchoredItems(
        _ findings: [CritiqueFinding],
        then: String,
        now: String
    ) -> [Item] {
        let nowAnchors = CritiqueAnchoring.anchor(findings, in: now)
        let thenAnchors = then == now
            ? nowAnchors
            : CritiqueAnchoring.anchor(findings, in: then)
        return findings.indices.map { index in
            let finding = findings[index]
            let written = thenAnchors[index].range.flatMap { Self.passage($0, in: then) }
            var range = nowAnchors[index].range
            var isApplied = false
            if then != now, written != nil,
               let applied = Self.appliedSuggestion(of: finding, quotedAt: range, in: now) {
                range = applied
                isApplied = true
            }
            let reads = range.flatMap { Self.passage($0, in: now) }
            let isEdited = written != nil && reads != written
            return Item(
                finding: finding,
                range: range,
                resolution: resolutions.resolution(for: finding),
                anchoredText: written ?? reads,
                isEdited: isEdited,
                isApplied: isApplied && isEdited
            )
        }
    }

    /// Where a note's suggestion stands in the draft, when the draft has
    /// taken it.
    ///
    /// Two ways it shows. A suggestion that keeps the quoted words — "good" to
    /// "good enough" — still contains them, so the quote is found, inside the
    /// suggestion; without this check a note brought back from the history
    /// would offer to apply itself a second time and make "good enough
    /// enough". A suggestion that replaced the words has taken the quote away,
    /// and is looked for itself, the way any quote is.
    private static func appliedSuggestion(
        of finding: CritiqueFinding,
        quotedAt quoted: NSRange?,
        in text: String
    ) -> NSRange? {
        guard let suggested = finding.replacement else { return nil }
        let suggestion = suggested as NSString
        guard let quoted else {
            let asApplied = finding.requoted(suggested, location: finding.location)
            guard let found = CritiqueAnchoring.range(for: asApplied, in: text),
                  passage(found, in: text) == suggested
            else { return nil }
            return found
        }
        var from = 0
        while from < suggestion.length {
            let inside = suggestion.range(
                of: finding.quote,
                options: .literal,
                range: NSRange(location: from, length: suggestion.length - from)
            )
            guard inside.location != NSNotFound else { return nil }
            let start = quoted.location - inside.location
            if start >= 0 {
                let whole = NSRange(location: start, length: suggestion.length)
                if passage(whole, in: text) == suggested { return whole }
            }
            from = inside.location + 1
        }
        return nil
    }

    /// Puts a finished run on screen and into the document's history.
    ///
    /// The notes the run was shown come back as themselves — same identity,
    /// same wording, the author's answer intact — or, when the critic found
    /// them fixed, move to the end marked Fixed. Its findings are added only
    /// where they say something no carried note already says: a model asked
    /// not to repeat a note mostly still does, and a note that comes back
    /// reworded beside itself is the re-run starting over by another route.
    private func land(
        _ answer: CritiqueAnswer,
        for text: String,
        plan: CarryPlan,
        brief sent: CritiqueBrief?,
        depth: CritiqueDepth
    ) {
        // The run was about `text`. The author may have kept typing, and the
        // notes are worked out against what the critic read before they are
        // moved on to that.
        let latest = currentText
        currentText = text
        // Answers given while the run was out are kept: a note marked Done
        // half a minute ago is still Done.
        let live = Dictionary(
            items.map { ($0.id, $0.resolution) },
            uniquingKeysWith: { first, _ in first }
        )
        func current(_ item: Item) -> Item {
            guard let resolution = live[item.id] else { return item }
            var item = item
            item.resolution = resolution
            return item
        }

        let kept = plan.kept.map(current)
        var claimed = kept.compactMap(\.range)
        var said = kept.map(\.finding)
        var carried: [Item] = []
        var fixed: [Item] = []
        var reopened = 0
        for (index, note) in plan.asked.map(current).enumerated() {
            let outcome = CritiqueCarry.resolve(
                CritiqueCarry.Note(
                    finding: note.finding,
                    resolution: note.resolution,
                    isEdited: note.isEdited,
                    passage: note.range.flatMap { Self.passage($0, in: text) }
                ),
                verdict: answer.verdicts[CritiqueCarry.key(at: index)],
                in: text
            )
            if outcome.isFixed {
                fixed.append(Item(finding: outcome.finding, range: nil, resolution: nil, isFixed: true))
                continue
            }
            if outcome.change == .reopened { reopened += 1 }
            // The answer is filed under the note's passage, so it moves when
            // the quote does.
            resolutions.set(nil, for: note.finding)
            resolutions.set(outcome.resolution, for: outcome.finding)
            let range: NSRange?
            if outcome.finding.quote == note.finding.quote, !note.isEdited, let held = note.range {
                range = held
            } else {
                range = CritiqueAnchoring.range(for: outcome.finding, in: text, avoiding: claimed)
            }
            if let range { claimed.append(range) }
            carried.append(Item(
                finding: outcome.finding,
                range: range,
                resolution: outcome.resolution,
                anchoredText: range.flatMap { Self.passage($0, in: text) }
            ))
            // Both quotes: the critic may repeat the note in either words.
            said.append(note.finding)
            said.append(outcome.finding)
        }

        var fresh: [Item] = []
        for finding in Self.keepingArrivalIDs(answer.report.findings, arrived: arrived) {
            if plan.isCarried, CritiqueCarry.isRepeat(finding, of: said) { continue }
            let range = CritiqueAnchoring.range(for: finding, in: text, avoiding: claimed)
            if let range { claimed.append(range) }
            // A finding the author has already answered arrives answered.
            // Without this every re-run resurrects every dismissal, and the
            // feature nags at somebody who told it not to.
            fresh.append(Item(
                finding: finding,
                range: range,
                resolution: resolutions.resolution(for: finding),
                anchoredText: range.flatMap { Self.passage($0, in: text) }
            ))
        }

        // The report that goes into the history is the whole rail, not just
        // what came back from this run. A narrowed run returns findings about
        // one passage, and filing only those would lose every note it kept
        // the next time the document was opened. The summary fields come from
        // this run, which was asked to describe the whole draft even when it
        // only criticised part of it.
        let standing = kept + carried + fresh
        // A quick pass is told to return what works, what doesn't and the
        // patterns as empty lists, because it does not read for them. One
        // that fills them in anyway did so at low effort on a read that was
        // not looking; filed, they would sit on the rail as a judgement of
        // the whole draft from the one kind of critique that does not give
        // one. `overall` stays: it is where the pass says what it found.
        let summary = depth == .quick
            ? CritiqueReport(
                jobRead: answer.report.jobRead, overall: answer.report.overall, findings: []
            )
            : answer.report
        let stored = summary.replacingFindings(with: standing.map(\.finding))
        resolutions.prune(keeping: stored.findings)
        CritiqueResolutionStore.save(resolutions, for: documentURL)
        history.add(
            CritiqueRevision(
                report: stored,
                documentText: text,
                fixed: fixed.map(\.finding),
                brief: sent?.text,
                depth: depth
            )
        )
        CritiqueHistoryStore.save(history, for: documentURL)
        // Cleared so the critic would guess again, and now it has: the line
        // goes back to showing the critic's read, which is this run's.
        if sent == nil, authorBrief?.isEmpty == true {
            authorBrief = nil
            CritiqueBriefStore.save(nil, for: documentURL)
        }
        shownRevisionID = nil
        report = stored
        items = Self.ordered(Self.placed(standing + fixed, in: outline(of: text)))
        criticisedText = text
        lastChange = plan.isCarried
            ? CritiqueCarry.Delta(
                fixed: fixed.count,
                reopened: reopened,
                new: fresh.filter(\.isOutstanding).count
            )
            : nil
        isRunning = false
        progress = nil
        failure = nil
        arriving = []
        arrived = []
        // A note pressed while the run was out — one of the old ones, or one
        // that arrived early — stays open if it is still a note to act on.
        // Anything else is a new pad.
        if let selected = selectedFindingID,
           !items.contains(where: { $0.id == selected && $0.isOutstanding }) {
            selectedFindingID = nil
        }
        // The pointer may well still be over the same patch of screen, but
        // the notes under it have moved.
        hoveredFindingID = nil
        if showsUnchangedNotice { showsUnchangedNotice = false }
        // Then on to the draft as it is now, the way any other edit goes.
        // Without this, typing while the critic read left every note with a
        // range measured in the text it read rather than the one on screen.
        if latest != text { noteCurrentText(latest) }
    }

    private func reorder() {
        let ordered = Self.ordered(items)
        if ordered != items { items = ordered }
    }

    /// Outstanding first in reading order, answered ones after them, and the
    /// ones a critique found fixed last of all.
    ///
    /// Ordered by where they are in the document, not by severity. The rail
    /// sits beside the text, and a rail beside the text that is ordered by
    /// something other than the text reads as a list that happens to be on
    /// the right. Reading down the notes should mean reading down the draft.
    /// Severity is not lost — it is the colour and the label on
    /// every card, and counted at the top — but it decides how a finding
    /// *looks*, not where it sits.
    ///
    /// Answered findings stay in the list rather than disappearing, because a
    /// decision the author cannot see is a decision they cannot take back —
    /// and because "I already dealt with that" is worth being able to check.
    /// A finding whose quote was not found has no position, so it goes last
    /// in its group rather than to the top, which is where an unset offset
    /// would put it.
    static func ordered(_ items: [Item]) -> [Item] {
        func group(_ item: Item) -> Int {
            if item.isOutstanding { return 0 }
            return item.isFixed ? 2 : 1
        }
        return items
            .enumerated()
            .sorted { left, right in
                let leftGroup = group(left.element)
                let rightGroup = group(right.element)
                if leftGroup != rightGroup { return leftGroup < rightGroup }
                let leftAt = left.element.range?.location ?? Int.max
                let rightAt = right.element.range?.location ?? Int.max
                if leftAt != rightAt { return leftAt < rightAt }
                // Two findings on the same passage keep the order the critique
                // reported them in, which is worst first.
                return left.offset < right.offset
            }
            .map(\.element)
    }

    /// Says what went wrong, and keeps the critique that was already there.
    ///
    /// A failed re-run used to clear the rail. Every note the author had not
    /// got to yet, and every answer they had given, disappeared behind an
    /// error about a request — for a draft that had not changed. The rail
    /// shows the failure above the notes instead, and only fills the panel
    /// with it when there is nothing else to show.
    private func fail(with failure: CritiqueService.Failure) {
        self.failure = failure
        isRunning = false
        progress = nil
        letGoOfArrivals()
    }

    /// Puts away a failure the author has read.
    func clearFailure() {
        failure = nil
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
    /// The paper a note is written on.
    ///
    /// Theme-aware, and it has to be: the papers were three fixed pastels
    /// while the writing on them followed the theme, so in a dark theme the
    /// notes were light grey text on pale pink and pale yellow — the pad was
    /// there, and unreadable. Paper this pale only works under dark ink.
    ///
    /// The dark set is the same three hues taken down to a depth the theme's
    /// own text reads on, rather than to grey: a note should still be *the
    /// pink one* at a glance, which is how the pad is navigated.
    func notePaper(on mode: EditorAppearanceMode) -> Color {
        switch (self, mode) {
        case (.high, .light): return Color(red: 1.00, green: 0.85, blue: 0.84)
        case (.medium, .light): return Color(red: 1.00, green: 0.96, blue: 0.76)
        case (.low, .light): return Color(red: 0.85, green: 0.93, blue: 1.00)
        case (.high, .dark): return Color(red: 0.30, green: 0.15, blue: 0.16)
        case (.medium, .dark): return Color(red: 0.28, green: 0.23, blue: 0.10)
        case (.low, .dark): return Color(red: 0.14, green: 0.21, blue: 0.32)
        }
    }
}
