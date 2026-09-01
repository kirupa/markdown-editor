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
    static let familyChain = [
        "PermanentMarker-Regular", "BradleyHandITCTT-Bold", "Noteworthy-Light",
        "SegoeMarker", "ChalkboardSE-Light",
    ]

    /// Faces that run large for their point size, and by how much.
    ///
    /// Type is specified in points but read at whatever size it happens to
    /// draw, and these two are not the same size at the same number: Permanent
    /// Marker at 15 takes half again as many lines as Bradley Hand at 15. The
    /// rail asks for an *optical* size and this is what turns that into a
    /// number each face can be given.
    static let opticalScale: [String: CGFloat] = [
        "PermanentMarker-Regular": 0.84,
    ]

    /// Handwriting runs small for its point size, so it is set a shade larger
    /// than the system text it sits beside. Measured against the cards: 14
    /// here reads about the size of 12 there.
    ///
    /// `bold` asks for emphasis rather than a weight. Bradley Hand has no
    /// bolder member, and `NSFontManager` answers such a request with the font
    /// it was given — so emphasis has to come from size, which the callers do.
    static func hand(_ size: CGFloat, bold: Bool = false) -> Font {
        for name in familyChain {
            let scaled = size * (opticalScale[name] ?? 1)
            guard let found = NSFont(name: name, size: scaled) else { continue }
            let face = bold
                ? NSFontManager.shared.convert(found, toHaveTrait: .boldFontMask)
                : found
            return Font(face)
        }
        return .system(size: size, weight: bold ? .semibold : .regular)
    }

    // MARK: - The labels

    /// The face the rail's own words are set in — the score, the severities,
    /// the section headings, the field names.
    ///
    /// Monomaniac One: condensed, technical, and nothing like handwriting,
    /// which is the point. The rail says two kinds of thing and they should
    /// not look alike — what the reviewer wrote is in their hand, and what the
    /// editor is telling you *about* that note is in the editor's voice.
    ///
    /// Bundled rather than assumed, under the SIL Open Font License, because
    /// macOS does not ship it. Loaded from the app's own `Fonts` directory via
    /// `ATSApplicationFontsPath`, so it is available to this process without
    /// being installed into anybody's Font Book.
    static let labelFamily = "MonomaniacOne-Regular"

    static func label(_ size: CGFloat) -> Font {
        if let font = NSFont(name: labelFamily, size: size) {
            return Font(font)
        }
        // Condensed and heavy is the shape that matters, so the fallback is
        // the nearest the system has rather than the plain body face.
        return .system(size: size, weight: .heavy).width(.condensed)
    }
}

/// The rail of comments down the right-hand side.
///
/// Modelled on the one place this interaction is already familiar: a Google
/// Docs comment thread. A card per finding, the open one raised and tinted,
/// the passage it describes shaded in the text, and a click on either side
/// moving the other.
struct CritiqueSidebar: View {
    @ObservedObject var critique: CritiqueModel
    let colorTheme: EditorColorTheme
    let isStale: Bool
    let onRerun: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // A gutter, then the rail. Without it the cards touch the page edge
        // and read as part of the document rather than as notes beside it.
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // The same desk the page lies on, so the notes read as pinned to
            // the surface rather than as a panel bolted to the window.
            ZStack {
                PixelStyle.canvas(colorTheme)
                PixelGrid(theme: colorTheme)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(colorTheme.accent)
            Text("CRITIQUE")
                .font(CritiqueTypography.hand(18))
                .tracking(0.5)
                .foregroundStyle(colorTheme.primaryText)

            Spacer()

            if !critique.history.isEmpty, !critique.isRunning {
                revisionMenu
            }

            if critique.isRunning {
                Button("Stop") { critique.cancel() }
                    .buttonStyle(.plain)
                    .font(CritiqueTypography.hand(13))
                    .foregroundStyle(colorTheme.secondaryText)
            } else if critique.report != nil {
                Button {
                    onRerun()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(colorTheme.secondaryText)
                .help("Critique the document again")
            }

            Button {
                critique.dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(colorTheme.secondaryText)
            .help("Close the critique")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
                            + "  ·  \(revision.score)/100"
                    )
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath")
                Text("\(critique.history.revisions.count)")
                    .font(CritiqueTypography.hand(13))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(colorTheme.secondaryText)
        .help("Earlier critiques of this document")
    }

    @ViewBuilder
    private var content: some View {
        if critique.isRunning {
            running
        } else if let failure = critique.failure {
            self.failure(failure)
        } else if let report = critique.report {
            findings(in: report)
        } else {
            empty
        }
    }

    private var running: some View {
        let progress = critique.progress ?? CritiqueProgress(stage: .starting)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(progress.stage.headline.uppercased())
                    .font(CritiqueTypography.hand(16))
                    .tracking(0.5)
                    .foregroundStyle(colorTheme.primaryText)
                Text(progress.stage.explanation)
                    .font(CritiqueTypography.hand(14))
                    .foregroundStyle(colorTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The four stages, so the wait has a shape. A spinner says only
            // that something is happening; this says which part, and how much
            // of it is behind you.
            HStack(spacing: 4) {
                ForEach(CritiqueProgress.Stage.allCases, id: \.self) { stage in
                    Rectangle()
                        .fill(
                            stage.rawValue <= progress.stage.rawValue
                                ? colorTheme.accent
                                : colorTheme.secondaryText.opacity(0.18)
                        )
                        .frame(height: 5)
                }
            }
            .animation(.easeOut(duration: 0.3), value: progress.stage)

            if progress.findingsSoFar > 0 {
                Text(
                    progress.findingsSoFar == 1
                        ? "1 NOTE SO FAR"
                        : "\(progress.findingsSoFar) NOTES SO FAR"
                )
                .font(CritiqueTypography.hand(14))
                .foregroundStyle(colorTheme.accent)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: progress.findingsSoFar)
            }

            // The model's own account of what it is looking at. Shown as-is:
            // it is a better progress message than anything this code could
            // invent, because it is actually true.
            if let detail = progress.detail, progress.stage == .reading {
                Text(detail)
                    .font(CritiqueTypography.hand(13))
                    .foregroundStyle(colorTheme.secondaryText)
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

    private func failure(_ failure: CritiqueService.Failure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(failure.errorDescription ?? "Something went wrong.")
                .font(CritiqueTypography.hand(16, bold: true))
                .foregroundStyle(colorTheme.primaryText)
            if let suggestion = failure.recoverySuggestion {
                Text(suggestion)
                    .font(CritiqueTypography.hand(15))
                    .foregroundStyle(colorTheme.secondaryText)
                    .textSelection(.enabled)
            }
            Button("Try Again") { onRerun() }
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No critique yet.")
                .font(CritiqueTypography.hand(15))
                .foregroundStyle(colorTheme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func findings(in report: CritiqueReport) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    scoreBanner
                    if isStale { staleNotice }
                    summary(report)

                    if critique.items.isEmpty {
                        Text("No high or medium problems found.")
                            .font(CritiqueTypography.hand(15))
                            .foregroundStyle(colorTheme.secondaryText)
                            .padding(.horizontal, 12)
                    }

                    ForEach(critique.items) { item in
                        if item.id == firstResolvedID {
                            answeredHeading
                        }
                        CritiqueCard(
                            item: item,
                            colorTheme: colorTheme,
                            isSelected: critique.selectedFindingID == item.id,
                            onTap: {
                                guard item.isOutstanding else { return }
                                critique.selectedFindingID =
                                    critique.selectedFindingID == item.id ? nil : item.id
                            },
                            onResolve: { resolution in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    critique.setResolution(resolution, for: item.id)
                                }
                            }
                        )
                        .id(item.id)
                    }

                    if !report.repeatedPatterns.isEmpty {
                        section("Repeated patterns") {
                            ForEach(report.repeatedPatterns) { pattern in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pattern.pattern)
                                        .font(CritiqueTypography.hand(15))
                                    if !pattern.locations.isEmpty {
                                        Text(pattern.locations.joined(separator: " · "))
                                            .font(CritiqueTypography.hand(12))
                                            .foregroundStyle(colorTheme.secondaryText)
                                    }
                                }
                            }
                        }
                    }

                    if !report.keep.isEmpty {
                        section("Keep") {
                            ForEach(Array(report.keep.enumerated()), id: \.offset) { _, note in
                                Text(note).font(CritiqueTypography.hand(15))
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

    /// How good the draft looks, out of a hundred.
    ///
    /// Counts only what is outstanding, so answering everything returns it to
    /// 100. That is the point of the two actions: the author has said what
    /// they meant to say, and the score should agree with them rather than
    /// keep score against them.
    private var scoreBanner: some View {
        let score = critique.score
        let tint = scoreTint(score)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(score)")
                    .font(CritiqueTypography.hand(46))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                Text("/100")
                    .font(CritiqueTypography.hand(16))
                    .foregroundStyle(tint.opacity(0.55))
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("AWESOMENESS")
                        .font(CritiqueTypography.hand(12))
                        .tracking(0.8)
                        .foregroundStyle(colorTheme.secondaryText)
                    Text(critique.verdict)
                        .font(CritiqueTypography.hand(14))
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

            if critique.resolvedCount > 0 {
                Text(
                    critique.outstanding.isEmpty
                        ? "Everything answered."
                        : "\(critique.resolvedCount) of \(critique.items.count) answered."
                )
                .font(CritiqueTypography.hand(12))
                .foregroundStyle(colorTheme.secondaryText)
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
                Rectangle().fill(tint.opacity(0.12))
                Rectangle().strokeBorder(tint, lineWidth: PixelStyle.border)
            }
        )
        .padding(.horizontal, 12)
        .animation(.easeOut(duration: 0.3), value: score)
    }

    private func scoreTint(_ score: Int) -> Color {
        switch score {
        case 85...: return CritiqueSeverity.low.tint
        case 50...: return CritiqueSeverity.medium.tint
        default: return CritiqueSeverity.high.tint
        }
    }

    /// The first answered card, so the divider can be drawn above it.
    private var firstResolvedID: UUID? {
        critique.items.first { !$0.isOutstanding }?.id
    }

    private var answeredHeading: some View {
        HStack(spacing: 6) {
            Text("ANSWERED")
                .font(CritiqueTypography.hand(13))
                .tracking(0.5)
                .foregroundStyle(colorTheme.secondaryText)
            Rectangle()
                .fill(colorTheme.separator.opacity(0.7))
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
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
        let total = critique.items.count
        let applying = critique.stillApplyingCount
        let when = critique.shownRevision.map {
            CritiqueRevisionLabel.relative($0.date).lowercased()
        }
        let opening = when.map { "Written \($0), and the draft has changed since." }
            ?? "The draft has changed since this critique."
        let survivors = total > 0
            ? " \(applying) of \(total) notes still point at something."
            : ""
        return Label(opening + survivors, systemImage: "clock.badge.exclamationmark")
        .font(CritiqueTypography.hand(15))
        .foregroundStyle(colorTheme.secondaryText)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                Rectangle().fill(colorTheme.secondaryText.opacity(0.10))
                Rectangle().strokeBorder(
                    PixelStyle.line(colorTheme), lineWidth: PixelStyle.border
                )
            }
        )
        .padding(.horizontal, 12)
    }

    /// The first note on the pad: what the piece is, what works, what does not.
    ///
    /// White, and the only white note, because it is not a finding — it is the
    /// reader's impression of the whole draft. Colour on this one would file it
    /// alongside the problems, which is exactly what it is not.
    private func summary(_ report: CritiqueReport) -> some View {
        StickyNote(
            colorTheme: colorTheme,
            paper: colorTheme.cardBackground,
            angle: PixelJitter.angle(for: summaryID),
            nudge: PixelJitter.offset(for: summaryID),
            tag: nil as AnyView?
        ) {
            VStack(alignment: .leading, spacing: 9) {
                if !report.jobRead.isEmpty {
                    Text(report.jobRead)
                        .font(CritiqueTypography.hand(13))
                        .foregroundStyle(colorTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !report.whatWorks.isEmpty {
                    noteSection("WHAT WORKS", report.whatWorks, mark: "+", tint: worksTint)
                }
                let problems = report.whatDoesNotWork.isEmpty
                    ? (report.overall.isEmpty ? [] : [report.overall])
                    : report.whatDoesNotWork
                if !problems.isEmpty {
                    noteSection(
                        "WHAT DOESN'T WORK", problems, mark: "–",
                        tint: CritiqueSeverity.high.tint
                    )
                }

                if !critique.severityCounts.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(critique.severityCounts, id: \.severity) { entry in
                            HStack(spacing: 4) {
                                Rectangle()
                                    .fill(entry.severity.tint)
                                    .frame(width: 6, height: 6)
                                Text("\(entry.count) \(entry.severity.label)")
                                    .font(CritiqueTypography.hand(13))
                                    .textCase(.uppercase)
                                    .foregroundStyle(colorTheme.secondaryText)
                            }
                        }
                    }
                    .padding(.top, 1)
                }

                let unanchored = critique.items.count - critique.anchoredCount
                if unanchored > 0 {
                    // Said plainly rather than hidden: a note with no highlight
                    // is otherwise just a comment that does nothing when clicked.
                    Text(
                        "\(unanchored) of \(critique.items.count) could not be matched to a passage."
                    )
                    .font(CritiqueTypography.hand(12))
                    .foregroundStyle(colorTheme.secondaryText)
                }
            }
        }
    }

    /// A stable identity for the summary note, so its angle does not change.
    private var summaryID: UUID {
        critique.shownRevision?.id
            ?? UUID(uuidString: "00000000-0000-0000-0000-00000000FEED")!
    }

    private var worksTint: Color { Color(red: 0.16, green: 0.60, blue: 0.35) }

    private func noteSection(
        _ title: String,
        _ lines: [String],
        mark: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(CritiqueTypography.hand(13))
                .tracking(0.5)
                .foregroundStyle(tint)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 5) {
                    Text(mark)
                        .font(CritiqueTypography.hand(14))
                        .foregroundStyle(tint.opacity(0.8))
                    Text(line)
                        .font(CritiqueTypography.hand(14))
                        .foregroundStyle(colorTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func section(
        _ title: String,
        @ViewBuilder body: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(CritiqueTypography.hand(13))
                .tracking(0.5)
                .foregroundStyle(colorTheme.secondaryText)
                .padding(.top, 8)
            body()
                .foregroundStyle(colorTheme.primaryText)
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
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
    @ViewBuilder let content: Content

    @State private var isHovered = false

    var body: some View {
        content
            .textSelection(.enabled)
            .padding(10)
            .padding(.top, tag == nil ? 2 : 8)
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
                .spring(response: 0.28, dampingFraction: 0.42),
                value: isHovered
            )
            .zIndex(isHovered ? 1 : 0)
            .onHover { isHovered = $0 }
            // Room for the corners to turn and grow into. Without it a rotated
            // note is clipped by the scroll view and the effect reads as a
            // rendering fault rather than as a note pinned at an angle.
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }
}


/// A small filled square with a white glyph in it.
private struct ActionStamp: View {
    let symbol: String
    let fill: Color
    let theme: EditorColorTheme
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 20, height: 18)
                .background(
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
                .scaleEffect(isHovered ? 1.14 : 1)
                .animation(.spring(response: 0.24, dampingFraction: 0.45), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// One comment.
private struct CritiqueCard: View {
    let item: CritiqueModel.Item
    let colorTheme: EditorColorTheme
    let isSelected: Bool
    let onTap: () -> Void
    let onResolve: (CritiqueResolution?) -> Void

    @State private var isHovered = false

    private var finding: CritiqueFinding { item.finding }
    private var isAnswered: Bool { !item.isOutstanding }

    /// Stable per note, so answering one does not reshuffle the pad.
    private var angle: Double {
        // A note that has been dealt with is straightened, which reads as
        // "this one has been handled" without needing a word for it.
        isAnswered ? 0 : PixelJitter.angle(for: item.id)
    }

    private var paper: Color {
        isAnswered
            ? colorTheme.cardBackground
            : finding.severity.notePaper
    }

    /// The tag pinned to the top of the note.
    ///
    /// Severity reads twice over: the paper it is written on, and the tag
    /// itself. That is deliberate rather than redundant — the colour is what
    /// you take in scrolling past, and the word is what you check when it
    /// matters. An answered note shows what was decided instead, in grey,
    /// because the severity of something you have dealt with is no longer the
    /// useful fact about it.
    private var severityTag: some View {
        let answered = item.resolution
        return Text(answered?.label.uppercased() ?? finding.severity.label.uppercased())
            .font(CritiqueTypography.hand(12))
            .tracking(0.6)
            .foregroundStyle(answered == nil ? Color.white : colorTheme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                ZStack {
                    Rectangle()
                        .fill(PixelStyle.shadow(colorTheme))
                        .offset(x: 2, y: 2)
                    Rectangle()
                        .fill(
                            answered == nil
                                ? finding.severity.tint
                                : colorTheme.secondaryText.opacity(0.18)
                        )
                }
            )
            // Sits over the note's top edge, the way a tag does.
            .offset(y: -9)
    }

    /// Done, Dismiss, or — once answered — a way back.
    ///
    /// Always present rather than revealed on hover: a control that appears
    /// only when the pointer is over it is a control nobody finds, and these
    /// two are the whole reason the rail is not merely a list of complaints.
    @ViewBuilder
    private var actions: some View {
        if isAnswered {
            Button {
                onResolve(nil)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(colorTheme.secondaryText)
            .help("Put this note back.")
        } else {
            ActionStamp(
                symbol: "checkmark",
                fill: CritiqueCard.doneGreen,
                theme: colorTheme,
                help: "I have fixed this. It will not be raised again."
            ) { onResolve(.completed) }

            ActionStamp(
                symbol: "xmark",
                fill: CritiqueCard.dismissRed,
                theme: colorTheme,
                help: "I am not doing this. It will not be raised again."
            ) { onResolve(.dismissed) }
        }
    }

    /// Deep enough to carry white, on any of the four papers.
    ///
    /// A tinted glyph on tinted paper is the version that does not work: a
    /// green tick on a pale yellow note is two washes of the same lightness,
    /// and at eleven points it disappears. A filled block with a white glyph
    /// reads the same on pink, yellow, blue and white, which is the whole
    /// requirement.
    static let doneGreen = Color(red: 0.11, green: 0.55, blue: 0.24)
    static let dismissRed = Color(red: 0.80, green: 0.15, blue: 0.13)

    var body: some View {
        StickyNote(
            colorTheme: colorTheme,
            paper: paper,
            angle: angle,
            nudge: PixelJitter.offset(for: item.id),
            tag: AnyView(severityTag),
            isSelected: isSelected,
            selectionColour: finding.severity.tint,
            dimmed: isAnswered
        ) {
            VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // The severity is the tag pinned to the top of the note, not
                // a word in this row — see `severityTag`.
                Text(finding.category)
                    .font(CritiqueTypography.hand(13))
                    .foregroundStyle(colorTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if finding.needsVerification {
                    Text("needs verification")
                        .font(CritiqueTypography.hand(11))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Rectangle().fill(colorTheme.secondaryText.opacity(0.18))
                        )
                        .foregroundStyle(colorTheme.secondaryText)
                }
            }

            // The passage is *not* repeated here. The highlight in the
            // document is already pointing at it, and a note that restates the
            // sentence it is about makes you read the same words twice to
            // learn nothing — which is not how a comment in a document behaves.
            //
            // The exception is a note nothing points at: when the quote could
            // not be found, there is no highlight, and without the words the
            // note has no subject at all.
            if !item.isAnchored, !finding.quote.isEmpty {
                // Deliberately not handwriting. This is the author's own
                // sentence quoted back at them, and it has to be recognisable
                // as theirs.
                Text(finding.quote)
                    .font(CritiqueTypography.hand(13))
                    .foregroundStyle(colorTheme.secondaryText)
                    .lineLimit(isSelected ? nil : 2)
                    .padding(.leading, 7)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(finding.severity.tint.opacity(0.55))
                            .frame(width: 2)
                    }
            }

            Text(finding.why)
                .font(CritiqueTypography.hand(15))
                .foregroundStyle(colorTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let advice = finding.advice {
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.adviceLabel.uppercased())
                        .font(CritiqueTypography.hand(12))
                        .tracking(0.4)
                        .foregroundStyle(colorTheme.secondaryText)
                    Text(advice)
                        .font(CritiqueTypography.hand(15))
                        .foregroundStyle(colorTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            HStack(spacing: 6) {
                if item.isAnchored {
                    if !finding.location.isEmpty {
                        Text(finding.location)
                            .font(CritiqueTypography.hand(12))
                            .foregroundStyle(colorTheme.secondaryText)
                    }
                } else {
                    Label("Not found in the document", systemImage: "questionmark.circle")
                        .font(CritiqueTypography.hand(12))
                        .foregroundStyle(colorTheme.secondaryText)
                }

                Spacer(minLength: 0)
                actions
            }
            .padding(.top, 3)
        }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(.easeOut(duration: 0.14), value: isSelected)
    }
}
