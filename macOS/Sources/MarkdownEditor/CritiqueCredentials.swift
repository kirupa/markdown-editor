import Foundation
import MarkdownEditorCore
import Security

/// Where a provider's API key is kept.
///
/// The Keychain, not user defaults. A key is a credential that can be used to
/// spend somebody's money, and defaults is a plist in the user's Library that
/// any process running as them can read, that gets copied into backups, and
/// that shows up in a diff if the folder is ever synced. The Keychain is the
/// one place on the system built for this.
///
/// One item per provider, so switching between them does not overwrite a key
/// you will want again.
enum CritiqueCredentials {
    private static let service = "com.kirupa.markdown-editor.critique"

    private static func query(for provider: CritiqueProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }

    static func key(for provider: CritiqueProvider) -> String? {
        var lookup = query(for: provider)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    static func hasKey(for provider: CritiqueProvider) -> Bool {
        !provider.needsAPIKey || key(for: provider) != nil
    }

    /// Stores a key, replacing whatever was there.
    ///
    /// An empty string removes it rather than storing nothing, so clearing the
    /// field in the settings window means what it looks like it means.
    @discardableResult
    static func store(_ key: String, for provider: CritiqueProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(for: provider) }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            // Available without unlocking again after first unlock, and never
            // carried to another machine: a key belongs to the Mac it was
            // entered on.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let existing = query(for: provider)
        let updated = SecItemUpdate(
            existing as CFDictionary, attributes as CFDictionary
        )
        if updated == errSecSuccess { return true }
        var insert = existing
        insert.merge(attributes) { current, _ in current }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(for provider: CritiqueProvider) -> Bool {
        let status = SecItemDelete(query(for: provider) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - The rest of the choice

    static var provider: CritiqueProvider {
        get {
            UserDefaults.standard.string(forKey: CritiqueProvider.storageKey)
                .flatMap(CritiqueProvider.init(rawValue:)) ?? .openAI
        }
        set {
            UserDefaults.standard.set(
                newValue.rawValue, forKey: CritiqueProvider.storageKey
            )
        }
    }

    static func model(for provider: CritiqueProvider) -> String {
        UserDefaults.standard.string(forKey: provider.modelStorageKey)
            ?? provider.defaultModel
    }

    static func setModel(_ model: String, for provider: CritiqueProvider) {
        UserDefaults.standard.set(model, forKey: provider.modelStorageKey)
    }

    /// Whether the feature is ready to run at all.
    ///
    /// What the rail asks before offering to critique anything, so that the
    /// first thing somebody sees is the one action that gets them going rather
    /// than a failure after a wait.
    static var isConfigured: Bool { hasKey(for: provider) }
}
