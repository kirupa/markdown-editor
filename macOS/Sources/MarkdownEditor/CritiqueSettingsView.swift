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
        CritiqueHand.sans.rawValue

    /// Held here rather than read from the Keychain on every redraw: a
    /// Keychain lookup per keystroke is both slow and pointless.
    @State private var key = ""
    @State private var model = ""
    @State private var savedKeyExists = false
    @State private var justSaved = false

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
                    ForEach(CritiqueHand.allCases) { candidate in
                        // Shown in its own face, because the names mean
                        // nothing: nobody knows what "Caveat" looks like.
                        Text(candidate.title)
                            .font(CritiqueTypography.named(candidate, size: 13))
                            .tag(candidate.rawValue)
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
    }

    private func load() {
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
