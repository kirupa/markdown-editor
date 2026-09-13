import MarkdownEditorCore
import MarkdownEditorUI
import SwiftUI

/// One place for everything the critique needs: who writes it, with what key,
/// using which model, and in which face.
///
/// Combined rather than split between a settings window and the rail's own
/// menu. There were two places to change the handwriting and none to enter a
/// key, and a reader who has just been asked for a key should not have to find
/// a different window to change the model it will be spent on.
struct CritiqueSettingsView: View {
    @AppStorage(CritiqueProvider.storageKey) private var providerRaw =
        CritiqueProvider.openAI.rawValue
    @AppStorage(CritiqueHand.storageKey) private var handRaw =
        CritiqueHand.initial.rawValue

    /// Held here rather than read from the Keychain on every redraw: a
    /// Keychain lookup per keystroke is both slow and pointless.
    @State private var key = ""
    @State private var model = ""
    @State private var savedKeyExists = false
    @State private var justSaved = false
    @StateObject private var skill = KonvoSkillModel()

    private var provider: CritiqueProvider {
        CritiqueProvider(rawValue: providerRaw) ?? .openAI
    }

    private var hand: CritiqueHand {
        CritiqueHand(rawValue: handRaw) ?? .sans
    }

    var body: some View {
        Form {
            Section("AI Assisted Critique") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(CritiqueProvider.allCases) { candidate in
                        Text(candidate.title).tag(candidate.rawValue)
                    }
                }
                .onChange(of: providerRaw) { _ in load() }

                if provider.needsAPIKey {
                    // Secure, so a key does not sit in plain sight on a screen
                    // somebody might be sharing.
                    SecureField("API key", text: $key)
                        .onSubmit(save)
                    HStack {
                        if let origin = provider.keyOrigin {
                            Text("Keys come from \(origin)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if justSaved {
                            Label("Saved", systemImage: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else if savedKeyExists {
                            Text("A key is stored")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Save Key", action: save)
                            .disabled(key.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty)
                        Button("Remove") {
                            CritiqueCredentials.remove(for: provider)
                            key = ""
                            savedKeyExists = false
                            justSaved = false
                        }
                        .disabled(!savedKeyExists)
                    }

                    Picker("Model", selection: $model) {
                        ForEach(provider.models, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .onChange(of: model) { chosen in
                        CritiqueCredentials.setModel(chosen, for: provider)
                    }
                    Text(
                        "The first model in the list is the inexpensive one, "
                            + "and is enough for a critique: it reads a draft "
                            + "and returns a page of findings."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Uses the GitHub Copilot CLI already signed in on this "
                            + "Mac. No key is stored and nothing is billed to "
                            + "an API account."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Appearance") {
                Picker("Comments are written in", selection: $handRaw) {
                    // `available`, not `allCases`: macOS makes several of the
                    // system faces optional downloads and any face can be
                    // switched off in Font Book. Offering one that is not there
                    // means picking it silently draws something else, which
                    // looks like the app ignoring you.
                    //
                    // Shown in its own face, because the names mean nothing:
                    // nobody knows what "Caveat" looks like.
                    Text(CritiqueHand.sans.title)
                        .font(CritiqueTypography.named(.sans, size: 13))
                        .tag(CritiqueHand.sans.rawValue)
                    Divider()
                    Section("Bundled") {
                        ForEach(CritiqueHand.available.filter(\.isBundled)) { candidate in
                            Text(candidate.title)
                                .font(CritiqueTypography.named(candidate, size: 13))
                                .tag(candidate.rawValue)
                        }
                    }
                    let system = CritiqueHand.available.filter {
                        !$0.isBundled && $0 != .sans
                    }
                    if !system.isEmpty {
                        Section("From your Mac") {
                            ForEach(system) { candidate in
                                Text(candidate.title)
                                    .font(CritiqueTypography.named(candidate, size: 13))
                                    .tag(candidate.rawValue)
                            }
                        }
                    }
                }
                Text(
                    hand == .sans
                        ? "The system face, which is the most legible at length."
                        : "A hand. Slower to read than the system face, and it "
                            + "makes the rail feel written rather than generated."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            konvoSkillSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
    }

    /// Which copy of the skill the critique is actually running against.
    ///
    /// The critique's whole shape — the severities, the categories, the rule
    /// that quotes come back character for character, which every highlight in
    /// the document depends on — comes from the skill rather than from this
    /// app. When a critique starts returning something the rail cannot draw,
    /// this is the first thing worth knowing, and there was nowhere to look.
    @ViewBuilder
    private var konvoSkillSection: some View {
        Section("KONVO Skill") {
            switch skill.state {
            case .unread, .reading:
                Text("Reading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .installed(let installed):
                LabeledContent("Version") {
                    Text(KonvoSkill.summary(for: installed))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                if !installed.subject.isEmpty {
                    Text(installed.subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if installed.isModified {
                    // Said plainly, because an update will refuse rather than
                    // discard the edits — and "the button did nothing" is a
                    // worse answer than knowing why.
                    Text(
                        "This checkout has local edits. An update will stop "
                            + "rather than overwrite them."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

            case .missing(let absence):
                Text(absence.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Update") { skill.update() }
                    .disabled(skill.isUpdating || !canUpdateSkill)
                if skill.isUpdating {
                    ProgressView().controlSize(.small)
                }
                if let outcome = skill.lastUpdate {
                    Text(outcome.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(
                "Pulls the latest konvo skill from its git remote into "
                    + "~/\(KonvoSkill.relativePath)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Only when there is a checkout to pull into. Offering the button
    /// otherwise is offering something that cannot work.
    private var canUpdateSkill: Bool {
        if case .installed = skill.state { return true }
        return false
    }

    private func load() {
        skill.read()
        // The picker has to show the provider the critique will actually use.
        //
        // `@AppStorage` cannot express this default because it is not a
        // constant — with nothing chosen it is the Copilot CLI when the CLI is
        // installed, and OpenAI when it is not. Left to the literal above, the
        // picker said "OpenAI" while every critique went through the CLI, which
        // is the same bug the hand picker had: a control describing a state the
        // app is not in.
        if UserDefaults.standard.string(forKey: CritiqueProvider.storageKey) == nil {
            providerRaw = CritiqueCredentials.provider.rawValue
        }
        savedKeyExists = CritiqueCredentials.key(for: provider) != nil
        // Never read back into the field: showing a stored secret buys nothing
        // and puts it on screen. The line beside it says one is held.
        key = ""
        justSaved = false
        model = CritiqueCredentials.model(for: provider)
    }

    private func save() {
        guard CritiqueCredentials.store(key, for: provider) else { return }
        savedKeyExists = true
        justSaved = true
        key = ""
    }
}
