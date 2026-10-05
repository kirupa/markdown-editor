import MarkdownEditorCore
import MarkdownEditorUI
import SwiftUI

/// The theme's colours as SwiftUI expects them.
///
/// The shared theme publishes most of its palette as `PlatformColor`, because
/// nearly every consumer is an `NSTextView` or a `UITextView`. This is the one
/// screen built entirely in SwiftUI, so it converts them here rather than
/// widening the shared type for a feature only the Mac has.
private extension EditorColorTheme {
    var primaryText: Color { Color(platformColor: primaryTextColor) }
    var secondaryText: Color { Color(platformColor: secondaryTextColor) }
    var separator: Color { Color(platformColor: separatorColor) }
    var accent: Color { Color(platformColor: accentColor) }
    var cardBackground: Color { Color(platformColor: editorBackgroundColor) }
}

/// The colours the critique feature writes in.
///
/// Its own rather than the theme's. The theme's text colours are chosen
/// against the theme's page, and almost nothing here is on the page: the
/// notes are on pale paper in a light theme and deep paper in a dark one,
/// and the rail's own lines are on the grid canvas. The theme's grey
/// secondary measured 4.2:1 on pale pink and 4.3:1 on the canvas.
enum CritiqueInk {
    /// The colour a note's own words are set in.
    ///
    /// A note is not on the page — it is on pale paper in a light theme and
    /// on a deep version of the same in a dark one — so it is not written in
    /// the page's ink.
    static func body(on mode: EditorAppearanceMode) -> Color {
        mode == .dark
            ? Color(red: 0.95, green: 0.95, blue: 0.94)
            : Color(red: 0.12, green: 0.11, blue: 0.11)
    }

    /// The quieter one, for labels and locations. Still a reading colour: it
    /// is quieter by being lighter than the body, not by being too faint.
    static func quiet(on mode: EditorAppearanceMode) -> Color {
        mode == .dark
            ? Color(red: 0.78, green: 0.77, blue: 0.76)
            : Color(red: 0.34, green: 0.32, blue: 0.32)
    }
}

/// The hands the critique can be written in.
///
/// The catalog is shared — Customize Theme ▸ Font offers the document exactly
/// the same faces — so it lives in `EditorTypeface`. What is the critique's own
/// is only which one it is currently written in.
typealias CritiqueHand = EditorTypeface

extension EditorTypeface {
    /// The critique's choice. Not the document's, which is
    /// `EditorColorTheme.typefaceStorageKey`: one list, two choices.
    static let storageKey = "critiqueHandFont"

    /// Read straight from defaults rather than held in a view.
    ///
    /// `CritiqueTypography.hand` is a static called from every label on the
    /// rail, and threading a binding through all of them to change a font is
    /// more machinery than the feature is worth. The picker writes the same
    /// key through `@AppStorage`, which redraws the rail, and the redraw picks
    /// this up.
    static var selected: CritiqueHand {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap(CritiqueHand.init(rawValue:)) ?? .initial
    }

    /// The face to use before anybody has chosen one.
    ///
    /// Named once and read everywhere, because it was written out three times
    /// and two of them disagreed: the rail's menu defaulted to Architects
    /// Daughter while Settings and the drawing code both defaulted to the
    /// system face. With nothing stored the menu therefore ticked a hand the
    /// rail was not writing in — the control lying about its own state, which
    /// is the worst kind of wrong a picker can be.
    static let initial: CritiqueHand = .sans
}

/// The hand the comments are written in.
///
/// Margin notes on a draft are handwritten, and setting them in the same face
/// as the document makes them read as more document. A different hand says
/// plainly that somebody wrote *on* this, not *in* it.
///
/// Bradley Hand, chosen by rendering every face macOS classifies as a script
/// at the size it is actually used. It is the only one with the irregularity
/// that reads as a person writing: letterforms that vary, a natural slant, an
/// uneven baseline. Noteworthy and Segoe Marker are printed marker lettering —
/// even and upright, which is what makes them look typed rather than written.
/// Xiomara, Trattatello and Brush Script are formal scripts that stop being
/// readable a sentence in.
///
/// It ships in one weight, which is a real limitation and an acceptable one:
/// a pen has one weight too. Emphasis is carried by size and colour instead.
///
/// The chain is a chain because any font can be disabled in Font Book, and a
/// comment nobody can read is worse than one in the wrong face.
enum CritiqueTypography {
    /// The hand the feedback is written in, whichever one is chosen.
    ///
    /// The chain is a chain because any font can be disabled in Font Book, and
    /// a comment nobody can read is worse than one in the wrong face.
    static var familyChain: [String] {
        [CritiqueHand.selected.fontName] + fallbackChain
    }

    static let fallbackChain = [
        "PermanentMarker-Regular", "BradleyHandITCTT-Bold", "Noteworthy-Light",
        "SegoeMarker", "ChalkboardSE-Light",
    ]

    /// The same hand. All three ship in one weight.
    ///
    /// A separate chain rather than a trait, because asking `NSFontManager` to
    /// embolden a single-weight face returns it unchanged — the request looks
    /// like it did something and did not. With one weight available, emphasis
    /// here is carried by size, which is what `sectionSize` is for.
    static var boldFamilyChain: [String] { familyChain }

    /// The three sizes the rail sets anything at.
    ///
    /// One face means hierarchy is carried by size alone, and it was carried
    /// the wrong way: every label — the category on a note, WHAT WORKS, TRY,
    /// ANSWERED — was set at 13 against a body of 14 to 15. The signposts were
    /// smaller than the prose they signposted, so there was nothing to scan by
    /// and the pad had to be read end to end to find anything.
    ///
    /// A heading is plainly bigger than its body now, which is the only thing
    /// that makes a stack of notes skimmable.
    static let sectionSize: CGFloat = 19
    static let bodySize: CGFloat = 16
    static let captionSize: CGFloat = 13

    /// Faces that run large for their point size, and by how much.
    ///
    /// Type is specified in points but read at whatever size it happens to
    /// draw, and these two are not the same size at the same number: Permanent
    /// Marker at 15 takes half again as many lines as Bradley Hand at 15. The
    /// rail asks for an *optical* size and this is what turns that into a
    /// number each face can be given.
    /// Anchored on x-height, not cap height.
    ///
    /// These three disagree about capitals far more than about lowercase:
    /// Architects Daughter's x-height is 0.43 and Permanent Marker's is 0.61
    /// against cap heights of 0.66 and 0.74. Almost every word here is
    /// lowercase, so matching the capitals sets the text people actually read
    /// as much as a fifth too small. Measured from the faces, not guessed.
    static var opticalScale: [String: CGFloat] {
        var scales: [String: CGFloat] = ["PermanentMarker-Regular": 0.84]
        for hand in CritiqueHand.allCases {
            scales[hand.fontName] = hand.opticalScale
        }
        return scales
    }

    /// Handwriting runs small for its point size, so it is set a shade larger
    /// than the system text it sits beside. Measured against the cards: 14
    /// here reads about the size of 12 there.
    ///
    /// `bold` asks for emphasis rather than a weight. Bradley Hand has no
    /// bolder member, and `NSFontManager` answers such a request with the font
    /// it was given — so emphasis has to come from size, which the callers do.
    /// A specific hand, for showing a face by example rather than by name.
    static func named(_ hand: CritiqueHand, size: CGFloat) -> Font {
        guard hand != .sans else { return .system(size: size) }
        return NSFont(name: hand.fontName, size: size * hand.opticalScale)
            .map(Font.init) ?? .system(size: size)
    }

    static func hand(_ size: CGFloat, bold: Bool = false) -> Font {
        // The system face is not in the chain: it has no stable PostScript
        // name to look up, and it can never be missing, so it is answered
        // directly rather than searched for.
        if CritiqueHand.selected == .sans {
            return .system(size: size, weight: bold ? .semibold : .regular)
        }
        for name in bold ? boldFamilyChain : familyChain {
            let scaled = size * (opticalScale[name] ?? 1)
            guard let found = NSFont(name: name, size: scaled) else { continue }
            return Font(found)
        }
        return .system(size: size, weight: bold ? .semibold : .regular)
    }

    /// The face the app speaks in.
    ///
    /// The rail says two different kinds of thing and they were set in one
    /// face, so they read as one voice. What a reviewer wrote about your
    /// sentence is theirs; "AWESOMENESS", "62/100", "WHAT WORKS", "Stop",
    /// "3 of 5 notes still point at the words they were written about" are
    /// the app talking *about* that — furniture, not commentary. Handwriting
    /// on the furniture makes the rail look like a novelty and, worse, makes
    /// a score and a criticism carry the same weight when only one of them is
    /// somebody's judgement.
    ///
    /// Set a little smaller than the number asks for. These sizes were chosen
    /// against handwriting, which runs small for its point size — Architects
    /// Daughter is drawn at 0.62 of the size it is given — so handing the same
    /// number to the system face makes the furniture louder than the writing
    /// it is supposed to be labelling. The furniture should recede.
    static let chromeScale: CGFloat = 0.88

    static func chrome(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: (size * chromeScale).rounded(), weight: weight)
    }

    /// A heading in the app's voice — CRITIQUE, WHAT WORKS, ANSWERED, KEEP.
    ///
    /// Small and bold, rather than large and regular. A heading earns its place
    /// by weight and by the space around it; making it big *as well* means the
    /// signpost competes with the thing it is pointing at, and a rail of
    /// oversized labels is harder to skim than one where the labels sit back
    /// and the writing carries the size.
    static let headingSize: CGFloat = 15

    static func heading(_ size: CGFloat = headingSize) -> Font {
        chrome(size, weight: .bold)
    }

    // MARK: - Inside a note

    /// The criticism itself. The smallest of the three, because it is the only
    /// one there is a lot of.
    static let noteBodySize: CGFloat = 14

    /// What the note is about — the category, at the top of the card.
    ///
    /// Larger than the body it introduces, and in the reviewer's hand rather
    /// than the app's: it is part of what they wrote on the note, not a label
    /// the app has stuck on top of it. This is the opposite call from the rail's
    /// own headings, and for the opposite reason — inside a card there is no
    /// surrounding space to give a heading weight, so it has to come from size.
    static let noteHeadingSize: CGFloat = 19

    /// TRY and DIRECTION: a sub-heading within the note, so between the two.
    static let noteLabelSize: CGFloat = 16

}

/// The rail of comments down the right-hand side.
///
/// Modelled on the one place this interaction is already familiar: a Google
/// Docs comment thread. A card per finding, the open one raised and tinted,
/// the passage it describes shaded in the text, and a click on either side
/// moving the other.
struct CritiqueSidebar: View {
    @AppStorage(CritiqueHand.storageKey) private var hand =
        CritiqueHand.initial.rawValue
    @AppStorage(CritiqueSidebar.compactNotesKey) private var compactNotes = false
    @AppStorage(CritiqueSidebar.summaryExpandedKey) private var summaryExpanded = false

    /// Whether notes are drawn a line each until opened. Kept, like the hand,
    /// because it is how somebody likes to read, not a fact about one critique.
    static let compactNotesKey = "critiqueCompactNotes"
    /// Whether the summary shows its lists or only its one-sentence read.
    static let summaryExpandedKey = "critiqueSummaryExpanded"

    @ObservedObject var critique: CritiqueModel
    let colorTheme: EditorColorTheme
    let isStale: Bool
    /// Re-read the whole draft.
    let onRerun: () -> Void
    /// Re-read what changed: only the paragraphs that did, when they are few
    /// enough to be worth narrowing to, and nothing when nothing has.
    /// Required rather than defaulted: a default of "do nothing" is a button
    /// that silently does nothing, and a default of "re-read everything" is
    /// the expensive thing this exists to avoid.
    let onRerunChanges: () -> Void
    /// A quick pass over the whole draft: typos and serious problems only.
    /// Optional, and not offered without it, like `replaceText`.
    var onQuickPass: (() -> Void)? = nil
    /// Changes the draft on a note's behalf — its suggestion put in, or the
    /// passage's own words put back — and returns the draft as it then reads,
    /// or nil when the words there were not the ones expected.
    ///
    /// Optional, and the buttons are not drawn without it rather than drawn
    /// doing nothing: a rail with no document behind it has nothing to put a
    /// suggestion into.
    var replaceText: ((CritiqueModel.Swap) -> String?)? = nil
    /// Puts the keyboard back in the draft, for a field on the rail that has
    /// been finished with. Optional for the same reason: a rail drawn on its
    /// own has no draft to go back to.
    var returnToDraft: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Not until a critique can run: before a key is set the only thing
            // worth saying is how to get one.
            if state != .needsSetUp {
                CritiqueBriefLine(
                    critique: critique, colorTheme: colorTheme,
                    onRerun: onRerun, returnToDraft: returnToDraft
                )
                Divider()
            }
            content
        }
        // Docked against the document, not floating beside it.
        //
        // There was a 16pt gutter here to keep the cards off the page edge.
        // What it actually did was leave the rail unattached to anything: the
        // notes are *about* the text they sit next to, and a gap plus a rule
        // read as a divider between two panes rather than as a margin on one
        // document. The cards have their own inset, so they still do not touch
        // the edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // The same desk the page lies on, so the notes read as pinned to
            // the surface rather than as a panel bolted to the window.
            Color(platformColor: colorTheme.editorBackgroundColor)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(colorTheme.accent)
            Text("CRITIQUE")
                .font(CritiqueTypography.heading(16))
                .tracking(0.5)
                .foregroundStyle(colorTheme.primaryText)

            Spacer()

            // The key and the model live behind this, not behind the font
            // menu. They were only reachable from the app's Settings window or
            // from the rail's first-run state, so once a key was entered there
            // was no way back to change the model without going looking for it.
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
            .help("Provider, API key, model and the KONVO skill")
            // Named for VoiceOver, which otherwise reads the five glyphs in
            // this row as "button" five times.
            .accessibilityLabel("Critique settings")

            handMenu

            if !critique.history.isEmpty, !critique.isRunning {
                revisionMenu
            }

            if critique.isRunning {
                Button("Stop") { critique.cancel() }
                    .buttonStyle(.plain)
                    .font(CritiqueTypography.chrome(15))
                    .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
            } else if critique.report != nil {
                // The header's re-run follows the default: the changed
                // paragraphs when there are any worth narrowing to, and
                // otherwise the whole draft. The stale notice is where the
                // choice is spelled out; this is the same action without the
                // explanation, so it must not quietly mean the expensive one.
                Button {
                    onRerunChanges()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                .help(
                    critique.canCritiqueChangesOnly
                        ? "Critique what has changed"
                        : "Critique the document again"
                )
                .accessibilityLabel("Critique again")
            }

            Button {
                critique.dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
            .help("Close the critique (⌃⌘I)")
            .accessibilityLabel("Close critique")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Pick the hand the comments are written in — from the same list, shown
    /// the same way, as Customize Theme ▸ Font. See `TypefaceMenuItems`.
    private var handMenu: some View {
        Menu {
            TypefaceMenuItems(
                selected: CritiqueHand(rawValue: hand) ?? .initial
            ) { candidate in
                hand = candidate.rawValue
            }
        } label: {
            Image(systemName: "textformat")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
        .help("The hand the notes are written in")
        .accessibilityLabel("Handwriting for notes")
    }

    /// The list of earlier critiques.
    ///
    /// Named by when they were written rather than by number, because that is
    /// what anybody is actually looking for — "the one before I rewrote the
    /// opening" — and carrying their score, so the list reads as a record of
    /// whether the draft is getting better.
    private var revisionMenu: some View {
        Menu {
            Button {
                critique.show(revision: nil)
            } label: {
                Label(
                    "Latest",
                    systemImage: critique.shownRevisionID == nil ? "checkmark" : ""
                )
            }
            if critique.history.revisions.count > 1 {
                Divider()
            }
            ForEach(critique.history.revisions.dropFirst()) { revision in
                Button {
                    critique.show(revision: revision.id)
                } label: {
                    Text(
                        "\(CritiqueRevisionLabel.relative(revision.date))"
                            + "  ·  \(CritiqueRevisionLabel.measure(revision))"
                    )
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath")
                Text("\(critique.history.revisions.count)")
                    .font(CritiqueTypography.chrome(15))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
        .help("Earlier critiques of this document")
        .accessibilityLabel("Earlier critiques")
    }

    /// What the rail is showing.
    ///
    /// Named so it can be asserted. SwiftUI draws most of this without a
    /// backing `NSTextField`, so walking the accessibility tree finds nothing
    /// — a check written that way passed against a rail showing the wrong
    /// state entirely, because it could not see either one.
    enum State: Equatable {
        case running
        case failed
        case findings
        case needsSetUp
        case nothingYet
    }

    /// A failure only takes the panel when there are no notes to keep on
    /// screen; with a critique already there it is a banner above them.
    var state: State {
        if critique.isRunning { return .running }
        if critique.report != nil { return .findings }
        if critique.failure != nil { return .failed }
        if !isConfigured { return .needsSetUp }
        return .nothingYet
    }

    @ViewBuilder
    private var content: some View {
        if critique.isRunning {
            // The notes stay on the rail while the critic reads again, and its
            // new ones join them as each is written. The whole panel is only
            // for a first run that has nothing to show yet: a re-run used to
            // take every note off the rail for the length of the run, which
            // is the half minute somebody would most like to be working
            // through them.
            if !critique.items.isEmpty || !critique.arriving.isEmpty {
                findings(in: critique.report)
            } else {
                running
            }
        } else if let report = critique.report {
            findings(in: report)
        } else if let failure = critique.failure {
            self.failure(failure)
        } else if !isConfigured {
            // Before anything else, including "no critique yet": there is no
            // point offering to run something that cannot run.
            setUp
        } else {
            empty
        }
    }

    /// What a first run looks like.
    ///
    /// The rail is always on screen now, so for most people the first thing it
    /// ever says is this. It names what is needed and offers the same button
    /// the rail always offers — pressing it here opens the window that takes
    /// the key, because that is what stands between you and a critique. The
    /// sentence above sets that expectation, so the button is not a surprise.
    private var setUp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up a critique")
                .font(CritiqueTypography.chrome(CritiqueTypography.sectionSize))
                .foregroundStyle(colorTheme.primaryText)
            Text(
                "A critique reads your draft and writes back what works, what "
                    + "does not, and where. It needs an API key from a model "
                    + "provider."
            )
            .font(CritiqueTypography.chrome(CritiqueTypography.bodySize))
            .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
            .fixedSize(horizontal: false, vertical: true)

            Button("Run critique") { beginCritique() }
                .controlSize(.large)

            Text(
                "\(CritiqueCredentials.provider.title) is selected. "
                    + (CritiqueCredentials.provider.keyOrigin.map {
                        "Keys come from \($0)."
                    } ?? "")
            )
            .font(CritiqueTypography.chrome(CritiqueTypography.captionSize))
            .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether a critique could run at all right now.
    ///
    /// Read once per redraw rather than held: the settings window writes to
    /// the Keychain, and there is no notification to observe.
    private var isConfigured: Bool { CritiqueCredentials.isConfigured }

    /// Opens the settings window. See `CritiqueSettingsWindow`.
    private func openSettings() {
        CritiqueSettingsWindow.open()
    }

    private var running: some View {
        let progress = critique.progress ?? CritiqueProgress(stage: .starting)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                if critique.runningDepth == .quick {
                    Text("QUICK PASS")
                        .font(CritiqueTypography.chrome(CritiqueTypography.captionSize))
                        .tracking(0.5)
                        .foregroundStyle(colorTheme.accent)
                }
                Text(progress.stage.headline.uppercased())
                    .font(CritiqueTypography.chrome(18))
                    .tracking(0.5)
                    .foregroundStyle(colorTheme.primaryText)
                Text(progress.stage.explanation)
                    .font(CritiqueTypography.chrome(16))
                    .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                    .fixedSize(horizontal: false, vertical: true)
            }

            stageBar(progress, height: 5)

            if progress.findingsSoFar > 0 {
                Text(
                    progress.findingsSoFar == 1
                        ? "1 NOTE SO FAR"
                        : "\(progress.findingsSoFar) NOTES SO FAR"
                )
                .font(CritiqueTypography.chrome(16))
                .foregroundStyle(colorTheme.accent)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: progress.findingsSoFar)
            }

            // The model's own account of what it is looking at. Shown as-is:
            // it is a better progress message than anything this code could
            // invent, because it is actually true.
            if let detail = progress.detail, progress.stage == .reading {
                Text(detail)
                    .font(CritiqueTypography.chrome(15))
                    .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(colorTheme.accent.opacity(0.35))
                            .frame(width: 2)
                    }
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .animation(.easeOut(duration: 0.2), value: progress.stage)
    }

    /// The four stages, so the wait has a shape. A spinner says only that
    /// something is happening; this says which part, and how much of it is
    /// behind you.
    private func stageBar(_ progress: CritiqueProgress, height: CGFloat) -> some View {
        HStack(spacing: 4) {
            ForEach(CritiqueProgress.Stage.allCases, id: \.self) { stage in
                Rectangle()
                    .fill(
                        stage.rawValue <= progress.stage.rawValue
                            ? colorTheme.accent
                            : CritiqueInk.quiet(on: colorTheme.mode).opacity(0.18)
                    )
                    .frame(height: height)
            }
        }
        .animation(.easeOut(duration: 0.3), value: progress.stage)
    }

    /// The run's progress, small enough to sit above the notes rather than
    /// in place of them.
    private var runningSummary: some View {
        let progress = critique.progress ?? CritiqueProgress(stage: .starting)
        let count = critique.arriving.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(
                    (critique.runningDepth == .quick ? "QUICK PASS · " : "")
                        + progress.stage.headline.uppercased()
                )
                    .font(CritiqueTypography.chrome(15))
                    .tracking(0.5)
                    .foregroundStyle(colorTheme.primaryText)
                Spacer(minLength: 0)
                if count > 0 {
                    Text(count == 1 ? "1 NEW SO FAR" : "\(count) NEW SO FAR")
                        .font(CritiqueTypography.chrome(15))
                        .foregroundStyle(colorTheme.accent)
                        .contentTransition(.numericText())
                }
            }
            stageBar(progress, height: 3)
            if let detail = progress.detail, progress.stage == .reading {
                Text(detail)
                    .font(CritiqueTypography.chrome(14))
                    .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                    .lineLimit(2)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .animation(.easeOut(duration: 0.2), value: count)
        .accessibilityElement(children: .combine)
    }

    /// One note on the rail.
    ///
    /// `isPreview` is a note from a run still being written: it can be read
    /// and pressed, which takes the reader to its passage, but not answered or
    /// applied until the run lands — an answer given to half a report has
    /// nowhere to be kept if the run is stopped.
    private func card(for item: CritiqueModel.Item, isPreview: Bool = false) -> some View {
        let isSelected = critique.selectedFindingID == item.id
        return CritiqueCard(
            item: item,
            colorTheme: colorTheme,
            isSelected: isSelected,
            onTap: { critique.press(item) },
            onHoverChange: { hovering in
                if hovering {
                    critique.hover(item.id)
                } else {
                    critique.endHover(item.id)
                }
            },
            onResolve: isPreview ? nil : { resolution in
                withAnimation(.easeOut(duration: 0.2)) {
                    critique.setResolution(resolution, for: item.id)
                }
            },
            onApply: isPreview ? nil : replaceText.map { replace in
                {
                    if !critique.applySuggestion(for: item.id, using: replace) {
                        NSSound.beep()
                    }
                }
            },
            onRevert: isPreview ? nil : replaceText.map { replace in
                {
                    if !critique.revertSuggestion(for: item.id, using: replace) {
                        NSSound.beep()
                    }
                }
            },
            isPreview: isPreview,
            // The open note is always in full: it is the one being read.
            isCompact: compactNotes && !isSelected
        )
        .id(item.id)
    }

    private func failure(_ failure: CritiqueService.Failure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(failure.errorDescription ?? "Something went wrong.")
                .font(CritiqueTypography.chrome(19, weight: .semibold))
                .foregroundStyle(colorTheme.primaryText)
            if let suggestion = failure.recoverySuggestion {
                Text(suggestion)
                    .font(CritiqueTypography.chrome(18))
                    .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                    .textSelection(.enabled)
            }
            Button(failure.retryTitle) { onRerun() }
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    /// Before the first critique of a document.
    ///
    /// Top and leading, like the set-up state, rather than a line and a button
    /// floating in the middle of a third of the window: the rail is this wide
    /// from the start so a critique has room to land, and until one does the
    /// room is better spent saying what it will do and how to drive it
    /// without the pointer.
    ///
    /// In a scroll view, which a short window needs to reach the keys at the
    /// bottom, and which keeps the paragraphs' heights to themselves. In a
    /// plain stack, a paragraph allowed to grow downward set the window's
    /// least height from how tall it would be at almost no width: the
    /// 1,400-point window a check draws the rail in grew to 3,357.
    private var empty: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nothing read yet")
                    .font(CritiqueTypography.chrome(CritiqueTypography.sectionSize))
                    .foregroundStyle(colorTheme.primaryText)
                Text(
                    "A critique reads the whole draft and pins a note to each "
                        + "passage worth another look, with a score for how close "
                        + "it is to ready."
                )
                .font(CritiqueTypography.chrome(CritiqueTypography.bodySize))
                .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))

                Button("Run critique") { beginCritique() }
                    .controlSize(.large)
                // Second, and quieter: the full critique is the one that
                // scores the draft, and the one to reach for first. This is
                // for the draft that only wants checking before it goes.
                if let onQuickPass {
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Quick pass") { begin(onQuickPass) }
                            .buttonStyle(.plain)
                            .font(CritiqueTypography.chrome(CritiqueTypography.bodySize))
                            .foregroundStyle(colorTheme.accent)
                        Text(Self.quickPassCaption)
                            .font(CritiqueTypography.chrome(CritiqueTypography.captionSize))
                            .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                    }
                }

                keys
                    .padding(.top, 8)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The Critique menu's keys, where somebody about to use them will see
    /// them. A menu is where shortcuts are kept, not where they are learned.
    struct KeyHint: Hashable {
        let keys: String
        let what: String
    }

    static let keyList: [KeyHint] = [
        KeyHint(keys: "⌃⌘C", what: "Critique"),
        KeyHint(keys: "⌥⌃⌘C", what: "Quick pass"),
        KeyHint(keys: "⌥⌘↓  ⌥⌘↑", what: "Next note, previous note"),
        KeyHint(keys: "⌥⌘↩", what: "Done"),
        KeyHint(keys: "⌥⌘⌫", what: "Dismiss"),
        KeyHint(keys: "⇧⌥⌘↩", what: "Apply the suggestion"),
        KeyHint(keys: "⌃⌘I", what: "Show or hide this rail"),
    ]

    private var keys: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("KEYS")
                .font(CritiqueTypography.heading())
                .tracking(0.5)
                .foregroundStyle(colorTheme.primaryText)
            ForEach(Self.keyList, id: \.keys) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.keys)
                        .font(CritiqueTypography.chrome(CritiqueTypography.captionSize, weight: .semibold))
                        .foregroundStyle(colorTheme.primaryText)
                        .frame(width: 78, alignment: .leading)
                    Text(entry.what)
                        .font(CritiqueTypography.chrome(CritiqueTypography.captionSize))
                        .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// What a quick pass is, where it is offered before anything has run.
    ///
    /// "Sooner" rather than a figure: the CLI's quick pass is also told to
    /// think less, and answered a 467-word post in 7 to 14 seconds against 52,
    /// but an API provider is sent only the narrower question, and nobody has
    /// timed that.
    static let quickPassCaption =
        "Typos and serious problems only, so it comes back sooner. No score."

    /// What pressing the rail's button will do.
    ///
    /// Named and exposed for the same reason `State` is: SwiftUI draws this
    /// rail without backing views, so the accessibility walk other checks use
    /// comes back empty and a check written against the drawn words passes for
    /// every state. The decision is worth asserting on its own.
    enum Action: Equatable {
        case run
        case askForKey
    }

    var buttonAction: Action {
        CritiqueCredentials.isConfigured ? .run : .askForKey
    }

    /// The rail's one action, wherever it is offered.
    ///
    /// "Run critique" is what somebody wants; needing a key first is an
    /// obstacle in the way of it, not a separate errand to go and do. So the
    /// button is the same in both states and this decides what pressing it
    /// means: run if it can, and otherwise open the window that takes the key.
    /// Read at the moment of the press rather than when the view was drawn,
    /// because the settings window writes to the Keychain and there is no
    /// notification to redraw on — so a key entered a second ago would
    /// otherwise still be treated as missing.
    private func beginCritique() {
        begin(onRerun)
    }

    /// `run` if a critique can run, and otherwise the window that takes the
    /// key. See `beginCritique`.
    private func begin(_ run: () -> Void) {
        switch buttonAction {
        case .run: run()
        case .askForKey: openSettings()
        }
    }

    private func findings(in report: CritiqueReport?) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if critique.isRunning {
                        // The score and the summary belong to the critique
                        // being replaced; the notes are what is still useful.
                        runningSummary
                    } else if let report {
                        if let failure = critique.failure { failureBanner(failure) }
                        if critique.isQuick { quickBanner } else { scoreBanner }
                        if !critique.items.isEmpty { noteStrip }
                        if isStale { staleNotice }
                        if critique.showsUnchangedNotice { unchangedNotice }
                        summary(report)

                        if critique.standingCount == 0 {
                            Text(
                                critique.isQuick
                                    ? "No typos or serious problems found."
                                    : "No high or medium problems found."
                            )
                                .font(CritiqueTypography.chrome(18))
                                .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                                .padding(.horizontal, 12)
                        } else if let filter = critique.severityFilter,
                                  !critique.outstanding.contains(where: critique.matchesFilter) {
                            filterExhausted(filter)
                        }
                    }

                    let arriving = critique.arriving.filter(critique.matchesFilter)
                    let items = critique.items.filter(critique.matchesFilter)
                    let firstResolved = firstResolvedID(in: items)
                    // Fixed notes are always last.
                    let firstFixed = items.first(where: \.isFixed)?.id
                    if !arriving.isEmpty {
                        if !items.isEmpty { groupHeading("NEW") }
                        ForEach(arriving) { item in
                            card(for: item, isPreview: true)
                        }
                        if items.first?.isOutstanding == true {
                            groupHeading("STILL OPEN")
                        }
                    }

                    ForEach(items) { item in
                        if item.id == firstResolved {
                            groupHeading("ANSWERED")
                        }
                        if item.id == firstFixed {
                            groupHeading("FIXED")
                        }
                        card(for: item)
                    }

                    if !critique.isRunning, let report {
                    if !report.repeatedPatterns.isEmpty {
                        section(
                            "Repeated patterns",
                            id: Self.repeatedID,
                            tint: CritiqueSeverity.medium.ink(on: colorTheme.mode)
                        ) {
                            ForEach(report.repeatedPatterns) { pattern in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(pattern.pattern)
                                        .font(CritiqueTypography.hand(CritiqueTypography.noteBodySize))
                                    if !pattern.locations.isEmpty {
                                        Text(pattern.locations.joined(separator: " · "))
                                            .font(CritiqueTypography.chrome(14))
                                            .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                                    }
                                }
                            }
                        }
                    }

                    if !report.keep.isEmpty {
                        section(
                            "Keep",
                            id: Self.keepID,
                            tint: CritiqueCard.worksGreen(on: colorTheme.mode)
                        ) {
                            ForEach(Array(report.keep.enumerated()), id: \.offset) { _, note in
                                Text(note)
                                    .font(CritiqueTypography.hand(CritiqueTypography.noteBodySize))
                            }
                        }
                    }
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: critique.selectedFindingID) { id in
                // A click in the *text* has to bring its card into view, or the
                // selection is invisible whenever the rail is scrolled
                // elsewhere — which is most of the time on a long document.
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    scroller.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    /// What went wrong with the last request, above the notes it did not
    /// replace.
    ///
    /// The notes stay because they are still the last thing the critic said
    /// about this draft: a request that failed has not changed the draft, and
    /// clearing the rail made a timeout cost every answer given so far.
    private func failureBanner(_ failure: CritiqueService.Failure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(
                    failure.errorDescription ?? "Something went wrong.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(CritiqueTypography.chrome(17, weight: .semibold))
                .foregroundStyle(colorTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    critique.clearFailure()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                .help("Hide this message")
                .accessibilityLabel("Hide this message")
            }
            if let suggestion = failure.recoverySuggestion {
                Text(suggestion)
                    .font(CritiqueTypography.chrome(15))
                    .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text("The notes below are from the last critique that finished.")
                .font(CritiqueTypography.chrome(CritiqueTypography.captionSize))
                .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                .fixedSize(horizontal: false, vertical: true)
            // The same default as the menu item: the changed paragraphs when
            // there are some, so retrying a narrowed run stays narrowed.
            Button(failure.retryTitle) { onRerunChanges() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                Rectangle().fill(CritiqueSeverity.high.tint.opacity(0.10))
                Rectangle().strokeBorder(
                    CritiqueSeverity.high.tint, lineWidth: PixelStyle.border
                )
            }
        )
        .padding(.horizontal, 12)
    }

    /// How good the draft looks, out of a hundred.
    ///
    /// Done takes a note off; Dismiss does not, and the problems the summary
    /// lists count too — see `CritiqueScore`. A hundred reached by answering
    /// rather than by a fresh critique says "Looks ready" and offers the
    /// critique that would confirm it, because "Ready" is a claim about the
    /// draft and only the critic can make it.
    private var scoreBanner: some View {
        let score = critique.score
        let tint = scoreTint(score)
        let ink = scoreTintSeverity(score).ink(on: colorTheme.mode)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(score)")
                    // The bold hand, because this one is a display numeral on
                    // a wash of its own colour. Set in the regular weight the
                    // strokes are thin enough that it measured 3.4:1 where the
                    // marker face made 5.3:1 — the colour did not change, the
                    // amount of it did.
                    .font(CritiqueTypography.chrome(48))
                    .foregroundStyle(ink)
                    .contentTransition(.numericText())
                Text("/100")
                    .font(CritiqueTypography.chrome(CritiqueTypography.sectionSize))
                    .foregroundStyle(ink)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("AWESOMENESS")
                        .font(CritiqueTypography.chrome(CritiqueTypography.captionSize))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                    Text(critique.verdict)
                        .font(CritiqueTypography.chrome(CritiqueTypography.bodySize))
                        .foregroundStyle(colorTheme.primaryText)
                        .multilineTextAlignment(.trailing)
                }
            }

            // A bar, because a number alone gives nothing to compare against.
            // It fills as findings are answered, which is the whole loop: the
            // rail is a list of things to do, and this is how much is left.
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(colorTheme.secondaryText.opacity(0.16))
                    // Stepped, not smooth: the bar reads in whole blocks, the
                    // way a health meter does, rather than as a continuous
                    // measurement it cannot honestly claim to be.
                    HStack(spacing: 2) {
                        ForEach(0..<20, id: \.self) { block in
                            Rectangle()
                                .fill(block * 5 < score ? tint : .clear)
                        }
                    }
                }
            }
            .frame(height: 7)

            // What this run changed, in words. The number moving says that
            // something happened; this says what.
            if let change = critique.lastChange {
                Text(change.summary)
                    .font(CritiqueTypography.chrome(CritiqueTypography.captionSize))
                    .foregroundStyle(colorTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let caption = scoreCaption {
                Text(caption)
                    .font(CritiqueTypography.chrome(CritiqueTypography.captionSize))
                    .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Offered here only when the draft is unchanged: when it has
            // changed, the notice below already offers both ways to re-read.
            if score == 100, !critique.isConfirmed, !isStale {
                Button("Critique again") { onRerun() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                Rectangle()
                    .fill(PixelStyle.shadow(colorTheme))
                    .offset(x: PixelStyle.shadowOffset, y: PixelStyle.shadowOffset)
                // Opaque paper first, then the wash on top.
                //
                // Without the paper the banner is 12% tint over the *grid
                // canvas*, which is a mid grey — so the wash came out a muddy
                // khaki and the numeral on it measured 3.37:1 however dark the
                // ink was made. Every other panel on the rail is a card; this
                // one only looked like one.
                Rectangle().fill(colorTheme.cardBackground)
                // The wash and the border stay the bright colour: they are
                // fills, and a fill is read by area rather than by edge.
                Rectangle().fill(tint.opacity(0.12))
                Rectangle().strokeBorder(tint, lineWidth: PixelStyle.border)
            }
        )
        .padding(.horizontal, 12)
        .animation(.easeOut(duration: 0.3), value: score)
    }

    /// What a quick pass shows in place of a score: how much it found to fix.
    ///
    /// No number out of a hundred and no verdict. A quick pass did not read
    /// for structure, pacing or voice, so a score from it would be marking the
    /// draft on the parts it skipped — and a clean quick pass scored a hundred
    /// would say "Ready" about a draft nobody had read for anything but typos.
    private var quickBanner: some View {
        let open = critique.outstanding.count
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(open)")
                    .font(CritiqueTypography.chrome(48))
                    .foregroundStyle(colorTheme.primaryText)
                    .contentTransition(.numericText())
                Text("TO FIX")
                    .font(CritiqueTypography.chrome(CritiqueTypography.sectionSize))
                    .foregroundStyle(colorTheme.primaryText)
                Spacer(minLength: 0)
                Text("QUICK PASS")
                    .font(CritiqueTypography.chrome(CritiqueTypography.captionSize))
                    .tracking(0.5)
                    .lineLimit(1)
                    .foregroundStyle(colorTheme.accent)
            }

            if let change = critique.lastChange {
                Text(change.summary)
                    .font(CritiqueTypography.chrome(CritiqueTypography.captionSize))
                    .foregroundStyle(colorTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(Self.quickBannerCaption)
                .font(CritiqueTypography.chrome(CritiqueTypography.captionSize))
                .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                .fixedSize(horizontal: false, vertical: true)
            // As for "Critique again" on the score: when the draft has
            // changed, the notice below offers the same thing.
            if !isStale {
                Button("Full critique") { onRerun() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                Rectangle()
                    .fill(PixelStyle.shadow(colorTheme))
                    .offset(x: PixelStyle.shadowOffset, y: PixelStyle.shadowOffset)
                Rectangle().fill(colorTheme.cardBackground)
                Rectangle().fill(colorTheme.accent.opacity(0.08))
                Rectangle().strokeBorder(colorTheme.accent, lineWidth: PixelStyle.border)
            }
        )
        .padding(.horizontal, 12)
        .animation(.easeOut(duration: 0.3), value: open)
    }

    static let quickBannerCaption =
        "Typos and serious problems only. A full critique also reads "
            + "structure and voice, and scores the draft."

    /// Why the number is what it is, when that is not obvious from the notes.
    ///
    /// Each line answers a question the old banner left open. "Everything
    /// answered" beside a perfect score was the rail agreeing with itself; a
    /// score that does not move when a note is dismissed needs to say that it
    /// was not meant to.
    var scoreCaption: String? {
        let answered = critique.resolvedCount
        if critique.score == 100 {
            guard !critique.isConfirmed else { return nil }
            return answered > 0
                ? "Every note answered. Critique again to confirm it is ready."
                : "The draft has changed since. Critique again to confirm it is ready."
        }
        var stillCounting: [String] = []
        if critique.dismissedCount > 0 { stillCounting.append("dismissed notes") }
        if critique.outstanding.isEmpty, critique.listedProblems > 0 {
            stillCounting.append("the problems in the summary")
        }
        var sentences: [String] = []
        if answered > 0 {
            sentences.append("\(answered) of \(critique.standingCount) answered.")
        }
        if !stillCounting.isEmpty {
            let list = stillCounting.joined(separator: " and ")
            sentences.append(list.prefix(1).uppercased() + list.dropFirst() + " still count.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private func scoreTintSeverity(_ score: Int) -> CritiqueSeverity {
        switch score {
        case 85...: return .low
        case 50...: return .medium
        default: return .high
        }
    }

    private func scoreTint(_ score: Int) -> Color {
        scoreTintSeverity(score).tint
    }

    /// The first answered card, so the divider can be drawn above it.
    ///
    /// The first of the answered ones at the *end* of the list, rather than
    /// the first anywhere. A note the author is rewriting stops being
    /// outstanding with the first keystroke, and is deliberately not moved
    /// while they type — so it can sit among the outstanding ones, and a
    /// heading drawn above it would split them in two.
    ///
    /// Of the cards the filter shows: a heading keyed to a hidden card is a
    /// heading that silently goes missing.
    private func firstResolvedID(in items: [CritiqueModel.Item]) -> UUID? {
        let start = (items.lastIndex(where: \.isOutstanding) ?? -1) + 1
        return items[start...].first { !$0.isFixed }?.id
    }

    private func groupHeading(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(CritiqueTypography.heading())
                .tracking(0.5)
                .foregroundStyle(colorTheme.primaryText)
            Rectangle()
                .fill(colorTheme.separator.opacity(0.7))
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    /// Which notes the rail shows, and how much of each.
    ///
    /// The counts used to be a line at the foot of the summary, below
    /// everything it summarised and with nothing to be done with them. Here
    /// each is the switch for its own notes: HIGH shows only those, on the rail
    /// and in the draft, which is how somebody with one pass to make before
    /// publishing deals with what matters first.
    private var noteStrip: some View {
        HStack(spacing: 6) {
            ForEach(stripSeverities, id: \.self) { severity in
                filterChip(severity)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { compactNotes.toggle() }
            } label: {
                Image(
                    systemName: compactNotes
                        ? "rectangle.expand.vertical"
                        : "rectangle.compress.vertical"
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
            .help(
                compactNotes
                    ? "Show every note in full"
                    : "Show each note in two lines until it is opened"
            )
            .accessibilityLabel(compactNotes ? "Show notes in full" : "Compact notes")
        }
        .padding(.horizontal, 12)
    }

    /// The severities with notes still open, and the one being filtered on
    /// even once it has none: its chip is the way back out.
    private var stripSeverities: [CritiqueSeverity] {
        CritiqueSeverity.allCases.filter { severity in
            severity == critique.severityFilter
                || critique.outstanding.contains { $0.finding.severity == severity }
        }
    }

    private func filterChip(_ severity: CritiqueSeverity) -> some View {
        let count = critique.outstanding.filter { $0.finding.severity == severity }.count
        let isChosen = critique.severityFilter == severity
        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                critique.severityFilter = isChosen ? nil : severity
            }
        } label: {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(severity.tint)
                    .frame(width: 6, height: 6)
                Text("\(count) \(severity.label)")
                    .font(CritiqueTypography.chrome(15))
                    .textCase(.uppercase)
                    .foregroundStyle(
                        isChosen ? colorTheme.primaryText : CritiqueInk.quiet(on: colorTheme.mode)
                    )
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isChosen ? severity.tint.opacity(0.18) : Color.clear)
            .overlay(
                Rectangle().strokeBorder(
                    isChosen ? severity.tint : PixelStyle.line(colorTheme).opacity(0.35),
                    lineWidth: PixelStyle.border
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            isChosen
                ? "Show every note again"
                : "Show only \(severity.label.lowercased())-severity notes"
        )
        .accessibilityLabel("\(count) \(severity.label.lowercased())")
        .accessibilityHint(isChosen ? "Shows every note again" : "Shows only these notes")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// Where the notes were, once the last one the filter shows is answered.
    ///
    /// Said, and with the way back beside it, rather than a rail that simply
    /// ends: the other severities' notes are still open, and nothing else on
    /// screen would say so.
    private func filterExhausted(_ severity: CritiqueSeverity) -> some View {
        HStack(spacing: 8) {
            Text("No open \(severity.label.lowercased()) notes left.")
                .font(CritiqueTypography.chrome(18))
                .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
            Button("Show all") {
                withAnimation(.easeOut(duration: 0.2)) { critique.severityFilter = nil }
            }
            .buttonStyle(.plain)
            .font(CritiqueTypography.chrome(16))
            .foregroundStyle(colorTheme.accent)
        }
        .padding(.horizontal, 12)
    }

    /// Said instead of running, when re-run is asked for a draft the critique
    /// on screen already describes.
    ///
    /// Reading the same words again costs a request and half a minute, and
    /// comes back as the same notes in other words — which reads as the
    /// critic changing its mind. So the rail says what would make another
    /// read worth having, and still offers one to somebody who wants it.
    private var unchangedNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Nothing has changed since this critique. Rewrite a passage or "
                    + "mark a note Done, and the next one checks it.",
                systemImage: "equal.circle"
            )
            .font(CritiqueTypography.chrome(18))
            .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
            .fixedSize(horizontal: false, vertical: true)
            Button("Critique again anyway") { onRerun() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(noticeBackground)
        .padding(.horizontal, 12)
    }

    private var noticeBackground: some View {
        ZStack {
            Rectangle().fill(CritiqueInk.quiet(on: colorTheme.mode).opacity(0.10))
            Rectangle().strokeBorder(
                PixelStyle.line(colorTheme), lineWidth: PixelStyle.border
            )
        }
    }

    private var staleNotice: some View {
        // A critique describes the draft at the moment it was asked for. Once
        // the words move, the offsets it was anchored to are pointing at
        // whatever now sits there — so this says so rather than letting the
        // highlights drift quietly out of true.
        //
        // And it says *how much* still applies, which is the useful number: an
        // old critique is worth reading in proportion to how much of the draft
        // it described is still there, not to how recent it is.
        let total = critique.standingCount
        let applying = critique.stillApplyingCount
        let when = critique.shownRevision.map {
            CritiqueRevisionLabel.relative($0.date).lowercased()
        }
        let opening = when.map { "Written \($0), and the draft has changed since." }
            ?? "The draft has changed since this critique."
        let survivors = total > 0
            ? " \(applying) of \(total) notes still point at the words they were written about."
            : ""
        return VStack(alignment: .leading, spacing: 10) {
            Label(opening + survivors, systemImage: "clock.badge.exclamationmark")
                .font(CritiqueTypography.chrome(18))
                .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                .fixedSize(horizontal: false, vertical: true)

            // Two ways to re-read, and the cheap one is first.
            //
            // Reading the whole draft again to find out what one new paragraph
            // broke costs a whole request, and asks the critic about every
            // note again — the ones about paragraphs nobody touched included,
            // each a chance for it to word the same complaint differently.
            // Most edits are local. The default should be too.
            //
            // Both are offered because "only the changes" is a judgement about
            // the draft that the app is not entitled to make alone: a new
            // opening paragraph can invalidate a note about the ending, and
            // only the author knows they have just done that.
            HStack(spacing: 8) {
                if critique.canCritiqueChangesOnly {
                    Button("Critique the changes") { onRerunChanges() }
                    Button("Everything") { onRerun() }
                        .buttonStyle(.plain)
                        .font(CritiqueTypography.chrome(16))
                        .foregroundStyle(colorTheme.accent)
                } else {
                    Button("Critique again") { onRerun() }
                    // The fast loop: rewrite, then check the rewrite for
                    // slips without waiting on a full read. Only here, where
                    // there is room for it beside one button.
                    if let onQuickPass {
                        Button("Quick pass") { begin(onQuickPass) }
                            .buttonStyle(.plain)
                            .font(CritiqueTypography.chrome(16))
                            .foregroundStyle(colorTheme.accent)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(noticeBackground)
        .padding(.horizontal, 12)
    }

    /// The first note on the pad: what the piece is, what works, what does not.
    ///
    /// White, and the only white note, because it is not a finding — it is the
    /// reader's impression of the whole draft. Colour on this one would file it
    /// alongside the problems, which is exactly what it is not.
    ///
    /// The one-sentence read, and the two lists only when asked for. Open, the
    /// lists filled the first screen after a real critique, and a writer had
    /// to scroll past them to reach a single note to act on — the summary is
    /// for after the notes, not in front of them. Whether it is open is kept,
    /// for somebody who always wants it.
    @ViewBuilder
    private func summary(_ report: CritiqueReport) -> some View {
        let disclosure = Self.summaryDisclosure(
            works: report.whatWorks.count,
            doesNotWork: report.whatDoesNotWork.count,
            isExpanded: summaryExpanded
        )
        let unanchored = critique.unmatchedCount
        if !report.overall.isEmpty || disclosure != nil || unanchored > 0 {
            StickyNote(
                colorTheme: colorTheme,
                paper: colorTheme.cardBackground,
                angle: PixelJitter.angle(for: summaryID),
                nudge: PixelJitter.offset(for: summaryID),
                tag: nil as AnyView?
            ) {
                VStack(alignment: .leading, spacing: 9) {
                    // No line saying what the critic took the piece to be. That
                    // read is the audience and goal at the top of the rail now,
                    // where it can be corrected; repeating it here, in grey, was
                    // where it used to sit uncorrectable.
                    if !report.overall.isEmpty {
                        Text(report.overall)
                            .font(CritiqueTypography.chrome(16))
                            .foregroundStyle(colorTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if summaryExpanded {
                        if !report.whatWorks.isEmpty {
                            noteSection("WHAT WORKS", report.whatWorks, mark: "+", tint: worksTint)
                        }
                        // An empty list is what the critic is told to return
                        // when nothing holds the draft back, so it gets no
                        // heading rather than a heading over nothing.
                        if !report.whatDoesNotWork.isEmpty {
                            noteSection(
                                "WHAT DOESN'T WORK", report.whatDoesNotWork, mark: "–",
                                tint: CritiqueSeverity.high.ink(on: colorTheme.mode)
                            )
                        }
                    }
                    if let disclosure {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { summaryExpanded.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: summaryExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .accessibilityHidden(true)
                                Text(disclosure)
                                    .font(CritiqueTypography.chrome(15))
                            }
                            .foregroundStyle(colorTheme.accent)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(summaryExpanded ? "Show only the overall read" : "Show what works and what doesn't")
                    }

                    if unanchored > 0 {
                        // Said plainly rather than hidden: a note with no highlight
                        // is otherwise just a comment that does nothing when clicked.
                        Text(
                            "\(unanchored) of \(critique.standingCount) could not be matched to a passage."
                        )
                        .font(CritiqueTypography.chrome(14))
                        .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                    }
                }
            }
        }
    }

    /// What the summary's switch says, or nil when it has nothing to open.
    ///
    /// Closed, it says what is behind it and how much, so whether it is worth
    /// opening can be told without opening it.
    static func summaryDisclosure(works: Int, doesNotWork: Int, isExpanded: Bool) -> String? {
        guard works > 0 || doesNotWork > 0 else { return nil }
        if isExpanded { return "Show less" }
        if works == 0 { return "What doesn't work (\(doesNotWork))" }
        if doesNotWork == 0 { return "What works (\(works))" }
        return "What works (\(works)) and what doesn't (\(doesNotWork))"
    }

    /// A stable identity for the summary note, so its angle does not change.
    private var summaryID: UUID {
        critique.shownRevision?.id
            ?? UUID(uuidString: "00000000-0000-0000-0000-00000000FEED")!
    }

    private var worksTint: Color { CritiqueCard.worksGreen(on: colorTheme.mode) }

    private func noteSection(
        _ title: String,
        _ lines: [String],
        mark: String,
        tint: Color
    ) -> some View {
        // Bullets are set apart from each other, not stacked.
        //
        // Each of these is a separate observation about the draft, and at a
        // three point gap a list of them ran together as one paragraph with
        // marks in it — particularly once an entry wrapped onto a second line,
        // where the gap inside an entry equalled the gap between two.
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(CritiqueTypography.heading())
                .tracking(0.5)
                .foregroundStyle(tint)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text(mark)
                        .font(CritiqueTypography.chrome(16))
                        .foregroundStyle(tint.opacity(0.8))
                    Text(line)
                        .font(CritiqueTypography.chrome(16))
                        .foregroundStyle(colorTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A whole-draft observation, on its own note.
    ///
    /// These two were the last things on the rail still drawn as bare text on
    /// the canvas — a leftover from the list this used to be, missed when
    /// everything else became a note. They read as a caption belonging to the
    /// note above rather than as observations in their own right.
    ///
    /// White paper, like the summary: neither is a fault to be answered, so
    /// neither takes a severity colour or a tag.
    private func section(
        _ title: String,
        id: UUID,
        tint: Color,
        @ViewBuilder body: () -> some View
    ) -> some View {
        StickyNote(
            colorTheme: colorTheme,
            paper: colorTheme.cardBackground,
            angle: PixelJitter.angle(for: id),
            nudge: PixelJitter.offset(for: id),
            tag: nil as AnyView?
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased())
                    .font(CritiqueTypography.heading())
                    .tracking(0.5)
                    .foregroundStyle(tint)
                body()
                    .foregroundStyle(CritiqueInk.body(on: colorTheme.mode))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    /// Fixed, so these two notes do not re-tilt on every redraw.
    private static let repeatedID =
        UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private static let keepID =
        UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
}

/// Who the draft is for, at the top of the rail where it governs everything
/// under it.
///
/// It used to be the first line of the summary note: grey, the quietest type
/// on the rail, written by the critic, worded differently every run, and with
/// no way to say it was wrong. Yet it was the reader every note was being held
/// to, so a wrong guess there made the whole rail advice for somebody else.
/// Up here it is a line the author can type into — the one input that changes
/// what every note says — and before the first critique as well as after it.
struct CritiqueBriefLine: View {
    @ObservedObject var critique: CritiqueModel
    let colorTheme: EditorColorTheme
    /// Critique the whole draft again, for when the notes on screen were
    /// written for a reader the author has since corrected.
    let onRerun: () -> Void
    /// Gives the keyboard back to the draft. Return and Esc are how a writer
    /// finishes with the line, and both mean "back to writing": left on the
    /// window instead, the next keystroke went nowhere.
    let returnToDraft: (() -> Void)?

    static let placeholder = "Who is it for, and what should it do for them?"

    @State private var draft: String
    @FocusState private var isEditing: Bool

    init(
        critique: CritiqueModel,
        colorTheme: EditorColorTheme,
        onRerun: @escaping () -> Void,
        returnToDraft: (() -> Void)? = nil
    ) {
        self.critique = critique
        self.colorTheme = colorTheme
        self.onRerun = onRerun
        self.returnToDraft = returnToDraft
        // Here rather than in `onAppear`, so the first layout already holds
        // the brief. Laid out once around the placeholder and again around the
        // words, the line changes height under the notes as the rail opens.
        _draft = State(initialValue: critique.brief.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                // One word up here rather than a sentence under the brief.
                // The guess is the line's usual state, so that caption cost
                // the rail a line of height over every critique, pushing the
                // first note further down, to say what one word says. One
                // run of text, so the dot sits evenly between the two.
                (Text("AUDIENCE AND GOAL") + Text(showsGuess ? " · GUESSED" : ""))
                    .font(CritiqueTypography.heading(13))
                    .tracking(0.5)
                    .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                    .help(showsGuess
                        ? "The critic's guess at who this is for. Correct it if it's wrong."
                        : "")
                Spacer()
                if !isEditing {
                    Button {
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                    .help("Say who this draft is for")
                }
            }

            TextField(Self.placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(CritiqueTypography.chrome(CritiqueTypography.bodySize))
                .foregroundStyle(colorTheme.primaryText)
                .lineLimit(1...5)
                .focused($isEditing)
                .onSubmit {
                    isEditing = false
                    returnToDraft?()
                }
                .onExitCommand(perform: putBack)
                // The box is always there and only drawn while typing, so the
                // words do not jump sideways when the field takes focus.
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background {
                    if isEditing {
                        ZStack {
                            Rectangle().fill(colorTheme.cardBackground)
                            Rectangle().strokeBorder(
                                colorTheme.accent, lineWidth: PixelStyle.border
                            )
                        }
                    }
                }
                .padding(.horizontal, -6)
                .accessibilityLabel("Audience and goal")
                .accessibilityHint(
                    critique.brief.isGuess
                        ? "The critic's guess. Correct it if it's wrong." : ""
                )

            if let caption {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(caption)
                        .font(CritiqueTypography.chrome(CritiqueTypography.captionSize))
                        .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                        .fixedSize(horizontal: false, vertical: true)
                    if offersRerun {
                        Spacer(minLength: 0)
                        Button("Critique again", action: onRerun)
                            .buttonStyle(.plain)
                            .font(CritiqueTypography.chrome(
                                CritiqueTypography.captionSize, weight: .semibold
                            ))
                            .foregroundStyle(colorTheme.accent)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Kept in step with the model whenever the author is not typing in
        // it: a critique landing can bring a new guess, and another document's
        // brief arrives when the window opens a file.
        .onChange(of: critique.brief) { brief in
            if !isEditing { draft = brief.text }
        }
        // Leaving the line keeps what was typed, the way leaving any field
        // does. Return leaves it too, so this is the one place a brief is
        // taken from.
        .onChange(of: isEditing) { editing in
            guard !editing else { return }
            critique.setBrief(draft)
            draft = critique.brief.text
        }
    }

    /// Esc: what the line said before, and back to the draft.
    private func putBack() {
        draft = critique.brief.text
        isEditing = false
        returnToDraft?()
    }

    /// The other run is the cheap fix for notes written for the wrong reader,
    /// so it is offered right where the reader was changed.
    private var offersRerun: Bool {
        !isEditing && critique.isForAnotherReader && !critique.isRunning
    }

    /// Not while typing: whatever is in the field by then is the author's.
    private var showsGuess: Bool {
        critique.brief.isGuess && !isEditing
    }

    /// One line under the brief, and only when there is something to do with
    /// it. A brief in force needs no caption, whoever wrote it; the heading
    /// says when it is a guess.
    private var caption: String? {
        if isEditing { return "Return keeps it. Esc puts it back." }
        let brief = critique.brief
        if offersRerun {
            return brief.isEmpty
                ? "The next critique will guess the reader again."
                : "These notes were written for a different reader."
        }
        if brief.isEmpty { return "Leave it empty and the critic will guess." }
        return nil
    }
}


/// A note on a pad: coloured paper, a hard shadow, a slight turn, and a tag.
///
/// One implementation for the summary and the findings, because they are the
/// same object with different contents — and because two of them would drift.
private struct StickyNote<Content: View>: View {
    let colorTheme: EditorColorTheme
    let paper: Color
    let angle: Double
    let nudge: CGFloat
    /// The label pinned to the top edge, if this note has one.
    let tag: AnyView?
    var isSelected: Bool = false
    var selectionColour: Color = .clear
    var dimmed: Bool = false
    /// What pressing this note does, if it is a note you can press.
    var onPress: (() -> Void)?
    /// Told when the pointer arrives over this note and when it leaves.
    var onHoverChange: ((Bool) -> Void)?
    /// A note that is a line in a list rather than a page of its own: a
    /// narrower margin, and no room kept around it for the turn. Measured on
    /// a 700-point rail, the margin and that room were 36 of a compact note's
    /// 92 points, and five such notes did not fit where two full ones did.
    var isCompact = false
    @ViewBuilder let content: Content

    @State private var isHovered = false

    /// Whether the words on this note can be selected with the pointer.
    ///
    /// Not on a note you can press, and this is not a preference — it is the
    /// reason pressing a note used not to work. `.textSelection(.enabled)`
    /// puts an `AppKitTextInteractionView` over the text, and that view takes
    /// the click: `hitTest` at the middle of a note returns it rather than the
    /// hosting view, so the press never reaches SwiftUI's gesture at all.
    /// Since the words are most of a note's area, what a reader saw was a card
    /// that answered a click on its margin and ignored a click on itself —
    /// reported, accurately, as having to click several times.
    ///
    /// Notes with nothing to press keep selectable text: the summary, the
    /// repeated patterns and the keep list are prose somebody may well want to
    /// copy, and nothing is competing for the click there.
    private var allowsTextSelection: Bool { onPress == nil }

    var body: some View {
        selectableContent
            .padding(isCompact ? 8 : 10)
            .padding(.top, tag != nil ? 8 : (isCompact ? 0 : 2))
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(dimmed ? 0.62 : 1)
            .background(
                ZStack {
                    // A block, not a blur: a blurred shadow is a gradient, and
                    // a gradient is the one thing a pixel grid cannot draw.
                    Rectangle()
                        .fill(PixelStyle.shadow(colorTheme))
                        .offset(
                            x: isSelected || isHovered
                                ? PixelStyle.liftedShadowOffset
                                : PixelStyle.shadowOffset,
                            y: isSelected || isHovered
                                ? PixelStyle.liftedShadowOffset
                                : PixelStyle.shadowOffset
                        )
                    Rectangle().fill(paper)
                    Rectangle()
                        .strokeBorder(
                            isSelected
                                ? selectionColour
                                : PixelStyle.line(colorTheme).opacity(0.5),
                            lineWidth: isSelected ? 2 : PixelStyle.border
                        )
                }
            )
            .overlay(alignment: .topLeading) {
                if let tag { tag.padding(.leading, 10) }
            }
            .rotationEffect(.degrees(angle), anchor: .center)
            .offset(x: nudge)
            // Picked up slightly, and it lands rather than glides: a low
            // damping ratio is what makes it read as a bounce instead of a
            // fade. Scale rather than movement, so nothing below it shifts.
            .scaleEffect(isHovered ? 1.035 : 1, anchor: .center)
            .animation(
                // Quick. A hover is a pointer passing over a list, and a
                // spring long enough to watch turns skimming the pad into
                // waiting for it: at 0.28 the note was still settling after
                // the pointer had moved on to the next one.
                .spring(response: 0.11, dampingFraction: 0.5),
                value: isHovered
            )
            .zIndex(isHovered ? 1 : 0)
            .onHover { hovering in
                isHovered = hovering
                onHoverChange?(hovering)
            }
            // Room for the corners to turn and grow into. Without it a rotated
            // note is clipped by the scroll view and the effect reads as a
            // rendering fault rather than as a note pinned at an angle. Not
            // above and below a compact one: the list's own spacing already
            // keeps two of them apart, and the scroll view's padding keeps
            // the first and last clear of its edges.
            .padding(.horizontal, 16)
            .padding(.vertical, isCompact ? 0 : 4)
            // The press lives here rather than around the whole thing outside,
            // so it is applied to the same view the hover is and cannot be
            // separated from the selectable-text decision above it.
            .contentShape(Rectangle())
            .modifier(PressAction(action: onPress))
    }

    @ViewBuilder
    private var selectableContent: some View {
        if allowsTextSelection {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}

/// A tap gesture, or nothing at all.
///
/// `onTapGesture` cannot be applied conditionally without the two branches
/// being different types, and a note with no action must not claim the click:
/// a gesture with an empty body still swallows it, which would take the
/// pointer's press away from anything underneath.
private struct PressAction: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}


/// A small filled square with a white glyph in it.
private struct ActionStamp: View {
    let symbol: String
    let fill: Color
    let theme: EditorColorTheme
    let help: String
    /// What VoiceOver says. Without one it reads the glyph's own name, which
    /// for the tick and the cross is "Selected" and "Close" — neither of them
    /// what pressing it does.
    var label: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 20, height: 18)
                .modifier(StampFace(fill: fill, theme: theme))
                .scaleEffect(isHovered ? 1.14 : 1)
                .animation(
                    .spring(response: 0.10, dampingFraction: 0.52),
                    value: isHovered
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(label ?? help)
        .accessibilityHint(label == nil ? "" : help)
    }
}

/// The same block with a word on it, for an action worth naming.
///
/// Not the system's push button. That one takes its colours from the window's
/// appearance rather than from the paper under it, and drawn where the two
/// disagree it was white lettering on a white bezel on pale yellow: an Apply
/// you could not read. It was also the only rounded thing on a note.
private struct WordStamp: View {
    let word: String
    /// A glyph before the word, for the stamps that used to be only a glyph,
    /// so the one a reader learned is still the one they look for.
    var symbol: String? = nil
    let fill: Color
    let theme: EditorColorTheme
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .black))
                }
                Text(word)
                    .font(CritiqueTypography.chrome(12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 20)
            .modifier(StampFace(fill: fill, theme: theme))
            .scaleEffect(isHovered ? 1.06 : 1)
            .animation(
                .spring(response: 0.10, dampingFraction: 0.52),
                value: isHovered
            )
        }
        .buttonStyle(.plain)
        // Never squeezed by the location beside it: "Dism…" is a stamp
        // nobody can read, and the location can take a second line.
        .fixedSize()
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(word)
        .accessibilityHint(help)
    }
}

/// A stamp's block: its colour, a hard drop, and a hairline edge.
private struct StampFace: ViewModifier {
    let fill: Color
    let theme: EditorColorTheme

    func body(content: Content) -> some View {
        content.background(
            ZStack {
                Rectangle()
                    .fill(PixelStyle.shadow(theme))
                    .offset(x: 2, y: 2)
                Rectangle().fill(fill)
                // A hairline of the paper's own darkness, so the block
                // still has an edge where its colour is close to the
                // note it sits on.
                Rectangle()
                    .strokeBorder(
                        Color.black.opacity(0.25),
                        lineWidth: PixelStyle.border
                    )
            }
        )
    }
}

/// One comment.
// Not `private`: it holds the feature's remaining colour constants, and the
// contrast pass in `check-critique` has to be able to name them. A palette
// nothing outside the file can see is a palette nothing can check.
struct CritiqueCard: View {
    let item: CritiqueModel.Item
    let colorTheme: EditorColorTheme
    let isSelected: Bool
    let onTap: () -> Void
    /// Told when the pointer arrives over this note and when it leaves.
    let onHoverChange: (Bool) -> Void
    /// Nil for a note that cannot be answered yet. See `isPreview`.
    let onResolve: ((CritiqueResolution?) -> Void)?
    /// Puts the note's suggestion in place of its passage. Nil where there is
    /// no draft to change, and then no Apply button is drawn.
    var onApply: (() -> Void)? = nil
    /// Puts the passage's own words back in place of an applied suggestion.
    var onRevert: (() -> Void)? = nil
    /// A note from a run still being written: read in full, suggestion and
    /// all, so it does not change shape when the run lands, but with nothing
    /// to press on it until then.
    var isPreview = false
    /// Drawn as its heading and the first line of its comment, with the stamps
    /// beside the heading, until it is opened. See `CritiqueSidebar.compactNotesKey`.
    var isCompact = false

    private var finding: CritiqueFinding { item.finding }
    private var isAnswered: Bool { !item.isOutstanding }

    /// Stable per note, so answering one does not reshuffle the pad.
    private var angle: Double {
        // A note that has been dealt with is straightened, which reads as
        // "this one has been handled" without needing a word for it.
        guard !isAnswered else { return 0 }
        // Turned less when compact. At the full 2.6 degrees the corners of a
        // note 300 points wide swing 7 points up or down, and two compact
        // notes have only the list's 10 points between them.
        let turn = PixelJitter.angle(for: item.id)
        return isCompact ? turn * 0.4 : turn
    }

    private var paper: Color {
        isAnswered
            ? colorTheme.cardBackground
            : finding.severity.notePaper(on: colorTheme.mode)
    }

    /// The label on the note: its severity, or what became of it.
    ///
    /// Severity reads twice over: the paper it is written on, and the label
    /// itself. That is deliberate rather than redundant — the colour is what
    /// you take in scrolling past, and the word is what you check when it
    /// matters. A note that is no longer outstanding shows what became of it
    /// instead, in grey, because the severity of something dealt with is no
    /// longer the useful fact about it.
    private func tagLabel(size: CGFloat) -> some View {
        let standing = item.standing
        return Text(standing?.label.uppercased() ?? finding.severity.label.uppercased())
            .font(CritiqueTypography.chrome(size))
            .tracking(0.6)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(
                standing == nil ? Color.white : CritiqueInk.body(on: colorTheme.mode)
            )
            .padding(.horizontal, isCompact ? 5 : 8)
            .padding(.vertical, isCompact ? 1 : 2)
            .background(
                ZStack {
                    Rectangle()
                        .fill(PixelStyle.shadow(colorTheme))
                        .offset(x: 2, y: 2)
                    Rectangle()
                        .fill(
                            standing == nil
                                // The deep member of the hue, not the bright
                                // one. White on the bright amber measures
                                // 2.35:1 — the tag was a colour with a word
                                // hidden in it.
                                ? finding.severity.ink(on: .light)
                                : CritiqueInk.quiet(on: colorTheme.mode).opacity(0.18)
                        )
                }
            )
    }

    /// Sits over the note's top edge, the way a tag does. A compact note
    /// carries the same label at the start of its line instead: pinned above
    /// it, the tag needed 8 points of paper to clear and as many again
    /// between notes to stick up into.
    private var severityTag: some View {
        tagLabel(size: 14)
            .offset(y: -9)
    }

    /// Done, Dismiss, or — once answered — a way back.
    ///
    /// Always present rather than revealed on hover: a control that appears
    /// only when the pointer is over it is a control nobody finds, and these
    /// two are the whole reason the rail is not merely a list of complaints.
    ///
    /// Named on a note drawn in full. As a bare ✓ and ✗ they were the two
    /// smallest things on the note, with nothing to say which was which but a
    /// tooltip. A compact note keeps the glyphs, since its whole point is to
    /// be short, but they are named for VoiceOver too, which read them as
    /// "Selected" and "Close".
    ///
    /// A note found fixed has none. The critic said so, and there is nothing
    /// for the author to take back.
    @ViewBuilder
    private var actions: some View {
        if item.isFixed || isPreview {
            EmptyView()
        } else if item.resolution != nil {
            putBack(help: "Put this note back.")
        } else if item.isApplied, let onRevert {
            // Not "my change did not fix this": the change was the critic's,
            // and the thing somebody reading it in place wants is their own
            // words back.
            putBack(help: "Put the original words back.", action: onRevert)
        } else if item.isEdited {
            // Only where the passage is still there to be about. Putting back
            // a note whose sentence was deleted would put back a note about
            // nothing.
            if item.isAnchored {
                putBack(help: "My change did not fix this. Put the note back.")
            }
        } else if isCompact {
            ActionStamp(
                symbol: "checkmark",
                fill: CritiqueCard.doneGreen,
                theme: colorTheme,
                help: Self.doneHelp,
                label: "Done"
            ) { onResolve?(.completed) }

            ActionStamp(
                symbol: "xmark",
                fill: CritiqueCard.dismissRed,
                theme: colorTheme,
                help: Self.dismissHelp,
                label: "Dismiss"
            ) { onResolve?(.dismissed) }
        } else {
            WordStamp(
                word: "Done",
                symbol: "checkmark",
                fill: CritiqueCard.doneGreen,
                theme: colorTheme,
                help: Self.doneHelp
            ) { onResolve?(.completed) }

            WordStamp(
                word: "Dismiss",
                symbol: "xmark",
                fill: CritiqueCard.dismissRed,
                theme: colorTheme,
                help: Self.dismissHelp
            ) { onResolve?(.dismissed) }
        }
    }

    private static let doneHelp =
        "I have fixed this. The next critique checks it. (⌥⌘↩ on the open note)"
    private static let dismissHelp =
        "I am not doing this. It will not be raised again. (⌥⌘⌫ on the open note)"

    /// The critic's rewrite of the passage, and the button that makes it.
    ///
    /// Shown in full, never cut to a line or two the way an unfound quote is:
    /// these are words about to go into the draft, and a preview that hides
    /// the end of them is an Apply nobody can check.
    private func suggested(_ suggestion: String, apply: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUGGESTED")
                .font(CritiqueTypography.hand(CritiqueTypography.noteLabelSize))
                .tracking(0.4)
                .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
            // The author's face, not the critic's hand: once applied, these
            // are the author's words in the author's document.
            Text(suggestion)
                .font(CritiqueTypography.chrome(CritiqueTypography.noteBodySize))
                .foregroundStyle(CritiqueInk.body(on: colorTheme.mode))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 7)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(CritiqueCard.doneGreen.opacity(0.7))
                        .frame(width: 2)
                }
            // A word, not a glyph. The ✓ and ✗ say something about the note;
            // this changes the draft, and a glyph that rewrites a paragraph
            // is not one anybody should have to hover to identify.
            //
            // Drawn, and held, on a note still arriving: taking the button
            // away would make every such note grow a row when the run lands.
            WordStamp(
                word: "Apply",
                fill: CritiqueCard.doneGreen,
                theme: colorTheme,
                help: apply == nil
                    ? "Ready when the critique has finished."
                    : "Put this in place of the passage. ⌘Z takes it back. (⇧⌥⌘↩ on the open note)",
                action: apply ?? {}
            )
            .disabled(apply == nil)
            .opacity(apply == nil ? 0.45 : 1)
            .padding(.top, 2)
        }
        .padding(.top, 2)
    }

    private func putBack(help: String, action: (() -> Void)? = nil) -> some View {
        Button {
            if let action { action() } else { onResolve?(nil) }
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
        .help(help)
        .accessibilityLabel(help)
    }

    /// Deep enough to carry white, on any of the four papers.
    ///
    /// A tinted glyph on tinted paper is the version that does not work: a
    /// green tick on a pale yellow note is two washes of the same lightness,
    /// and at eleven points it disappears. A filled block with a white glyph
    /// reads the same on pink, yellow, blue and white, which is the whole
    /// requirement.
    static let doneGreen = Color(red: 0.09, green: 0.46, blue: 0.20)
    static let dismissRed = Color(red: 0.80, green: 0.15, blue: 0.13)

    /// The two colours a note is written in.
    ///
    /// A note's own, not the theme's. The theme's text colours are picked
    /// against the theme's *page*, and a note is not on the page — it is on
    /// pale pink or pale yellow in a light theme and on a deep version of the
    /// same in a dark one. The theme's grey secondary measured 4.2:1 on pale
    /// pink, which is a label you have to lean in for.
    static func noteInk(on mode: EditorAppearanceMode) -> Color {
        mode == .dark
            ? Color(red: 0.95, green: 0.95, blue: 0.94)
            : Color(red: 0.12, green: 0.11, blue: 0.11)
    }

    /// The quieter one, for labels and locations. Still a reading colour: it
    /// is quieter by being lighter than the body, not by being too faint.
    static func noteSubInk(on mode: EditorAppearanceMode) -> Color {
        mode == .dark
            ? Color(red: 0.78, green: 0.77, blue: 0.76)
            : Color(red: 0.34, green: 0.32, blue: 0.32)
    }

    /// The green the summary's "what works" is headed in.
    ///
    /// Lightened for a dark theme like every other reading colour here: the
    /// one green measured 2.9:1 on the dark card it is set on.
    static func worksGreen(on mode: EditorAppearanceMode) -> Color {
        mode == .dark
            ? Color(red: 0.42, green: 0.82, blue: 0.56)
            : Color(red: 0.13, green: 0.50, blue: 0.29)
    }

    var body: some View {
        StickyNote(
            colorTheme: colorTheme,
            paper: paper,
            angle: angle,
            nudge: PixelJitter.offset(for: item.id),
            tag: isCompact ? nil : AnyView(severityTag),
            isSelected: isSelected,
            selectionColour: finding.severity.tint,
            dimmed: isAnswered,
            // A note that has been decided has nothing to take you to, so it
            // keeps its selectable text: there is no press competing for the
            // click, and it is still prose somebody may want to copy out. One
            // being rewritten has not been decided — it is the one the author
            // is in the middle of — so it still goes to its passage.
            onPress: item.resolution == nil && !item.isFixed ? onTap : nil,
            onHoverChange: onHoverChange,
            isCompact: isCompact
        ) {
            VStack(alignment: .leading, spacing: isCompact ? 2 : 6) {
                HStack(alignment: isCompact ? .center : .top, spacing: 6) {
                    // A full note's severity is the tag pinned to its top
                    // edge, not a word in this row — see `severityTag`.
                    if isCompact {
                        tagLabel(size: 12)
                    }
                    Text(finding.category)
                        .font(CritiqueTypography.hand(CritiqueTypography.noteHeadingSize))
                        .foregroundStyle(CritiqueInk.body(on: colorTheme.mode))
                        .lineLimit(isCompact ? 1 : 2)
                    Spacer(minLength: 0)
                    if isCompact {
                        // Where the bottom row would be, were there one.
                        actions
                    } else if finding.needsVerification {
                        Text("needs verification")
                            .font(CritiqueTypography.chrome(13))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Rectangle().fill(CritiqueInk.quiet(on: colorTheme.mode).opacity(0.18))
                            )
                            .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                    }
                }

                // The passage is *not* repeated here. The highlight in the
                // document is already pointing at it, and a note that restates
                // the sentence it is about makes you read the same words twice
                // to learn nothing — which is not how a comment in a document
                // behaves.
                //
                // The exception is a note nothing points at: when the quote
                // could not be found, there is no highlight, and without the
                // words the note has no subject at all.
                if !isCompact, !item.isAnchored, !finding.quote.isEmpty {
                    // Deliberately not handwriting. This is the author's own
                    // sentence quoted back at them, and it has to be
                    // recognisable as theirs — the comment said so long before
                    // the code did.
                    Text(finding.quote)
                        .font(CritiqueTypography.chrome(CritiqueTypography.noteBodySize))
                        .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                        .lineLimit(isSelected ? nil : 2)
                        .padding(.leading, 7)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(finding.severity.tint.opacity(0.55))
                                .frame(width: 2)
                        }
                }

                Text(finding.why)
                    .font(CritiqueTypography.hand(CritiqueTypography.noteBodySize))
                    .foregroundStyle(CritiqueInk.body(on: colorTheme.mode))
                    .lineLimit(isCompact ? 1 : nil)
                    .fixedSize(horizontal: false, vertical: true)

                if !isCompact {
                    fullNote
                }
            }
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.14), value: isSelected)
    }

    /// Everything under the comment, which a compact note leaves out.
    @ViewBuilder
    private var fullNote: some View {
        if let advice = finding.advice {
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.adviceLabel.uppercased())
                    .font(CritiqueTypography.hand(CritiqueTypography.noteLabelSize))
                    .tracking(0.4)
                    .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                Text(advice)
                    .font(CritiqueTypography.hand(CritiqueTypography.noteBodySize))
                    .foregroundStyle(CritiqueInk.body(on: colorTheme.mode))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }

        if let suggestion = item.suggestion, onApply != nil || isPreview {
            suggested(suggestion, apply: onApply)
        }

        // One row while the status and the stamps fit beside each other, and
        // the status on a line of its own when they do not. Named stamps are
        // wider than the bare ✓ and ✗ were, and "Not found in the document"
        // squeezed in beside them wrapped round them instead: read top to
        // bottom it came out as "Not found in the · Done Dismiss · document".
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                status
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: 4) {
                status
                HStack {
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
        .padding(.top, 3)
    }

    /// What became of the note, or where it is, under its advice.
    @ViewBuilder
    private var status: some View {
        if item.isFixed {
            Label("A later critique found this fixed.", systemImage: "checkmark.seal")
                .font(CritiqueTypography.chrome(14))
                .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
        } else if item.isApplied {
            // The same caution as an edit: the critic wrote the
            // suggestion against the paragraph as it was, and has not
            // read it in place.
            Label(
                "Changed to the suggestion. The next critique checks it.",
                systemImage: "text.badge.checkmark"
            )
            .font(CritiqueTypography.chrome(14))
            .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
        } else if item.isEdited {
            // Not "fixed": a rewrite can as easily keep the problem or
            // make a new one, and only a critique can tell which.
            Label("Changed since. The next critique checks it.", systemImage: "pencil")
                .font(CritiqueTypography.chrome(14))
                .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
        } else if item.isAnchored {
            if !finding.location.isEmpty {
                Text(finding.location)
                    .font(CritiqueTypography.chrome(14))
                    .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
                    .lineLimit(2)
            }
        } else {
            Label("Not found in the document", systemImage: "questionmark.circle")
                .font(CritiqueTypography.chrome(14))
                .foregroundStyle(CritiqueInk.quiet(on: colorTheme.mode))
        }
    }
}
