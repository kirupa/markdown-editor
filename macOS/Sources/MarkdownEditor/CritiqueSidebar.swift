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
        .frame(width: 300)
        .background(colorTheme.canvasBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(colorTheme.accent)
            Text("Critique")
                .font(.system(size: 13, weight: .semibold))
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
                .font(.system(size: 12))
                .foregroundStyle(colorTheme.secondaryText)
            // Honest about the wait. A critique reads the piece twice before
            // it says anything, and a spinner with no expectation attached
            // reads as a hang after about ten seconds.
            Text("This usually takes half a minute.")
                .font(.system(size: 11))
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colorTheme.primaryText)
            if let suggestion = failure.recoverySuggestion {
                Text(suggestion)
                    .font(.system(size: 12))
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
                .font(.system(size: 12))
                .foregroundStyle(colorTheme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func findings(in report: CritiqueReport) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if isStale { staleNotice }
                    summary(report)

                    if critique.items.isEmpty {
                        Text("No high or medium problems found.")
                            .font(.system(size: 12))
                            .foregroundStyle(colorTheme.secondaryText)
                            .padding(.horizontal, 12)
                    }

                    ForEach(critique.items) { item in
                        CritiqueCard(
                            item: item,
                            colorTheme: colorTheme,
                            isSelected: critique.selectedFindingID == item.id
                        ) {
                            critique.selectedFindingID =
                                critique.selectedFindingID == item.id ? nil : item.id
                        }
                        .id(item.id)
                    }

                    if !report.repeatedPatterns.isEmpty {
                        section("Repeated patterns") {
                            ForEach(report.repeatedPatterns) { pattern in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pattern.pattern)
                                        .font(.system(size: 12))
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
                                Text(note).font(.system(size: 12))
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

    private var staleNotice: some View {
        // A critique describes the draft at the moment it was asked for. Once
        // the words move, the offsets it was anchored to are pointing at
        // whatever now sits there — so this says so rather than letting the
        // highlights drift quietly out of true.
        Label(
            "The document has changed since this critique. Passages may no longer line up.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.system(size: 11))
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
                    .font(.system(size: 11))
                    .foregroundStyle(colorTheme.secondaryText)
            }
            if !report.overall.isEmpty {
                Text(report.overall)
                    .font(.system(size: 12))
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
                .font(.system(size: 11))
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

    private var finding: CritiqueFinding { item.finding }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(finding.severity.tint)
                    .frame(width: 7, height: 7)
                Text(finding.severity.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(finding.severity.tint)
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
                .font(.system(size: 12))
                .foregroundStyle(colorTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let advice = finding.advice {
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.adviceLabel.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(colorTheme.secondaryText)
                    Text(advice)
                        .font(.system(size: 12))
                        .foregroundStyle(colorTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            HStack(spacing: 4) {
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
            }
            .padding(.top, 1)
        }
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
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
