// Which keychain is refusing us, and is it the signature or the keychain?
//
// `keychain-probe` establishes that FirebaseAuth cannot sign in from any build
// this repository can produce: `SecItemAdd (-34018)`, however the bundle is
// ad-hoc signed. That says something is missing, but not *what*, and the two
// candidate causes suggest very different fixes:
//
//   - if an ad-hoc signature cannot write to the keychain at all, the fix is
//     an Apple account, and nothing else will do;
//   - if only the *data-protection* keychain refuses us, the fix might be as
//     small as asking for the other one, and would need no account at all.
//
// macOS has two keychains. The legacy file-based one is what `security(1)`
// shows and has no entitlement requirement. The data-protection keychain is
// the iOS-style one, opted into per query with `kSecUseDataProtectionKeychain`,
// and it is the one that requires a keychain access group — which comes from a
// provisioning profile.
//
// So: write the same item to each, from the same process, and print both. One
// process and one difference between the two calls, which is what makes the
// comparison mean anything.
//
// Deliberately has no Firebase in it. It needs no emulator and no network, so
// it can be run against any signature in a second.
//
//     Shared/Firebase/Scripts/check-keychain.sh

import Foundation
import Security

@main
enum KeychainKind {
    private static let service = "com.kirupa.markdown-editor.keychain-kind-probe"

    static func main() {
        let dataProtection = attempt(dataProtection: true)
        let fileBased = attempt(dataProtection: false)

        report("data-protection keychain (what FirebaseAuth uses)", dataProtection)
        report("file-based keychain (no entitlement required)", fileBased)

        // Say what the pair means, so a reader does not have to remember which
        // combination implies what.
        switch (dataProtection, fileBased) {
        case (nil, nil):
            print("=> this signature can use either keychain.")
        case (.some, nil):
            print("=> the signature is fine; the data-protection keychain is the blocker.")
            print("   FirebaseAuth asks for it unconditionally, so this is not avoidable.")
        case (nil, .some):
            print("=> unexpected: the entitled keychain works and the open one does not.")
        case (.some, .some):
            print("=> no keychain is reachable at all; the signature itself is the problem.")
        }
    }

    /// Writes, reads back and removes one item. Returns `nil` on success, or
    /// the `OSStatus` of whichever step failed first.
    private static func attempt(dataProtection: Bool) -> OSStatus? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: dataProtection ? "data-protection" : "file-based"
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        // Leave nothing behind on a previous run, so a stale item cannot make
        // a failing write look like a passing one.
        SecItemDelete(query as CFDictionary)
        defer { SecItemDelete(query as CFDictionary) }

        var write = query
        write[kSecValueData as String] = Data("probe".utf8)
        let added = SecItemAdd(write as CFDictionary, nil)
        guard added == errSecSuccess else { return added }

        // Reading it back matters: a write that cannot be retrieved is not a
        // usable session, which is the thing being tested.
        var read = query
        read[kSecReturnData as String] = true
        var item: CFTypeRef?
        let found = SecItemCopyMatching(read as CFDictionary, &item)
        guard found == errSecSuccess else { return found }
        guard let data = item as? Data, String(decoding: data, as: UTF8.self) == "probe" else {
            return errSecDecode
        }
        return nil
    }

    private static func report(_ label: String, _ status: OSStatus?) {
        guard let status else {
            print("OK   \(label): wrote and read back")
            return
        }
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        print("FAIL \(label): OSStatus \(status) — \(detail)")
    }
}
