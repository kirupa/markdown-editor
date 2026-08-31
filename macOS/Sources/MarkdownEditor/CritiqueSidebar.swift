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
        "BradleyHandITCTT-Bold", "Noteworthy-Light", "SegoeMarker",
        "ChalkboardSE-Light",
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
            guard let found = NSFont(name: name, size: size) else { continue }
            let face = bold
                ? NSFontManager.shared.convert(found, toHaveTrait: .boldFontMask)
                : found
            return Font(face)
        }
        return .system(size: size, weight: bold ? .semibold : .regular)
    }

    /// Whether the hand is available at all, so the rail can space itself for
    /// whichever face it actually gets.
    static var hasHand: Bool {
        familyChain.contains { NSFont(name: $0, size: 12) != nil }
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
        .background(colorTheme.canvasBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(colorTheme.accent)
            Text("Critique")
                .font(CritiqueTypography.hand(16, bold: true))
                .foregroundStyle(colorTheme.primaryText)

            Spacer()

            if critique.isRunning {
                Button("Stop") { critique.cancel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
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
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Reading the whole draft…")
                .font(CritiqueTypography.hand(14))
                .foregroundStyle(colorTheme.secondaryText)
            // Honest about the wait. A critique reads the piece twice before
            // it says anything, and a spinner with no expectation attached
            // reads as a hang after about ten seconds.
            Text("This usually takes half a minute.")
                .font(CritiqueTypography.hand(13))
                .foregroundStyle(colorTheme.secondaryText.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .multilineTextAlignment(.center)
    }

    private func failure(_ failure: CritiqueService.Failure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(failure.errorDescription ?? "Something went wrong.")
                .font(CritiqueTypography.hand(15, bold: true))
                .foregroundStyle(colorTheme.primaryText)
            if let suggestion = failure.recoverySuggestion {
                Text(suggestion)
                    .font(CritiqueTypography.hand(14))
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
                .font(CritiqueTypography.hand(14))
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
                            .font(CritiqueTypography.hand(14))
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
                                        .font(CritiqueTypography.hand(14))
                                    if !pattern.locations.isEmpty {
                                        Text(pattern.locations.joined(separator: " · "))
                                            .font(.system(size: 11))
                                            .foregroundStyle(colorTheme.secondaryText)
                                    }
                                }
                            }
                        }
                    }

                    if !report.keep.isEmpty {
                        section("Keep") {
                            ForEach(Array(report.keep.enumerated()), id: \.offset) { _, note in
                                Text(note).font(CritiqueTypography.hand(14))
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
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(score)")
                .font(CritiqueTypography.hand(32, bold: true))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Awesomeness")
                    .font(CritiqueTypography.hand(13))
                    .foregroundStyle(colorTheme.secondaryText)
                Text(critique.verdict)
                    .font(CritiqueTypography.hand(14, bold: true))
                    .foregroundStyle(colorTheme.primaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12))
        )
        .padding(.horizontal, 12)
        .animation(.easeOut(duration: 0.25), value: score)
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
                .font(.system(size: 10, weight: .semibold))
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
        Label(
            "The document has changed since this critique. Passages may no longer line up.",
            systemImage: "exclamationmark.triangle"
        )
        .font(CritiqueTypography.hand(13))
        .foregroundStyle(colorTheme.secondaryText)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(colorTheme.secondaryText.opacity(0.10))
        )
        .padding(.horizontal, 12)
    }

    private func summary(_ report: CritiqueReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !report.jobRead.isEmpty {
                Text(report.jobRead)
                    .font(CritiqueTypography.hand(13))
                    .foregroundStyle(colorTheme.secondaryText)
            }
            if !report.overall.isEmpty {
                Text(report.overall)
                    .font(CritiqueTypography.hand(14))
                    .foregroundStyle(colorTheme.primaryText)
            }
            if !critique.severityCounts.isEmpty {
                HStack(spacing: 10) {
                    ForEach(critique.severityCounts, id: \.severity) { entry in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(entry.severity.tint)
                                .frame(width: 6, height: 6)
                            Text("\(entry.count) \(entry.severity.label.lowercased())")
                                .font(.system(size: 11))
                                .foregroundStyle(colorTheme.secondaryText)
                        }
                    }
                }
                .padding(.top, 2)
            }
            let unanchored = critique.items.count - critique.anchoredCount
            if unanchored > 0 {
                // Said plainly rather than hidden: a card with no highlight is
                // otherwise just a comment that does nothing when clicked.
                Text(
                    "\(unanchored) of \(critique.items.count) could not be matched to a passage."
                )
                .font(CritiqueTypography.hand(13))
                .foregroundStyle(colorTheme.secondaryText)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }

    private func section(
        _ title: String,
        @ViewBuilder body: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
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

    /// Done, Dismiss, or — once answered — a way back.
    ///
    /// Always present rather than revealed on hover: a control that appears
    /// only when the pointer is over it is a control nobody finds, and these
    /// two are the whole reason the rail is not merely a list of complaints.
    @ViewBuilder
    private var actions: some View {
        if isAnswered {
            Button("Undo") { onResolve(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(colorTheme.accent)
        } else {
            Button {
                onResolve(.completed)
            } label: {
                Label("Done", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(colorTheme.accent)
            .help("I have fixed this. It will not be raised again.")

            Button("Dismiss") { onResolve(.dismissed) }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(colorTheme.secondaryText)
                .help("I am not doing this. It will not be raised again.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isAnswered ? colorTheme.secondaryText : finding.severity.tint)
                    .frame(width: 7, height: 7)
                Text(
                    item.resolution.map(\.label) ?? finding.severity.label
                )
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    isAnswered ? colorTheme.secondaryText : finding.severity.tint
                )
                Text(finding.category)
                    .font(.system(size: 10))
                    .foregroundStyle(colorTheme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if finding.needsVerification {
                    Text("needs verification")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(colorTheme.secondaryText.opacity(0.15))
                        )
                        .foregroundStyle(colorTheme.secondaryText)
                }
            }

            if !finding.quote.isEmpty {
                // Deliberately *not* handwriting. This is the author's own
                // sentence quoted back at them, and it has to be recognisable
                // as theirs — re-lettering it in the reviewer's hand makes the
                // draft look like it already says something it does not.
                Text(finding.quote)
                    .font(.system(size: 11.5))
                    .italic()
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
                .font(CritiqueTypography.hand(14))
                .foregroundStyle(colorTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let advice = finding.advice {
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.adviceLabel.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(colorTheme.secondaryText)
                    Text(advice)
                        .font(CritiqueTypography.hand(14))
                        .foregroundStyle(colorTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            HStack(spacing: 6) {
                if item.isAnchored {
                    if !finding.location.isEmpty {
                        Text(finding.location)
                            .font(.system(size: 10))
                            .foregroundStyle(colorTheme.secondaryText)
                    }
                } else {
                    Label("Not found in the document", systemImage: "questionmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(colorTheme.secondaryText)
                }

                Spacer(minLength: 0)
                actions
            }
            .padding(.top, 3)
        }
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isAnswered ? 0.62 : 1)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(colorTheme.cardBackground)
                .shadow(
                    color: .black.opacity(isSelected ? 0.16 : 0.06),
                    radius: isSelected ? 5 : 2,
                    y: isSelected ? 2 : 1
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected
                        ? finding.severity.tint.opacity(0.85)
                        : colorTheme.separator.opacity(0.6),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(.easeOut(duration: 0.14), value: isSelected)
    }
}
