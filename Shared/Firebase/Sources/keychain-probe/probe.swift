// Asks one question: can an ad-hoc-signed .app sign in with FirebaseAuth?
//
// It matters because `firebase-emulator-check` cannot — FirebaseAuth persists
// to the macOS data-protection keychain, and a plain SwiftPM executable has no
// entitlement for it, so `signInAnonymously()` fails with `SecItemAdd
// (-34018)`. That is a property of an unbundled binary, not necessarily of the
// app, and the difference decides whether a cloud sign-in screen is worth
// building for a build signed the way `Scripts/build-app.sh` signs it.
//
// So this is the same call, from inside a bundle, signed the same way.
//
// Not part of any suite: it is a one-off answer to a one-off question, kept
// because the answer is load-bearing and re-deriving it is slow.
//
//     Shared/Firebase/Scripts/check-keychain.sh

import Foundation
import FirebaseAuth
import FirebaseCore
import MarkdownEditorFirebase

@main
enum Probe {
    // `@main` with an async `main`, rather than a semaphore. FirebaseAuth
    // delivers its completion on the main queue, so blocking the main thread
    // to wait for it deadlocks — which looks exactly like a hung network call.
    static func main() async {
        let host = ProcessInfo.processInfo.environment["MDE_AUTH_EMULATOR"] ?? "127.0.0.1:9481"

        let options = FirebaseOptions(
            googleAppID: FirebaseConfiguration.appID,
            gcmSenderID: FirebaseConfiguration.messagingSenderID
        )
        options.projectID = FirebaseConfiguration.projectID
        options.apiKey = FirebaseConfiguration.apiKey
        FirebaseApp.configure(options: options)

        let parts = host.split(separator: ":")
        Auth.auth().useEmulator(
            withHost: String(parts[0]),
            port: Int(parts.count > 1 ? parts[1] : "9481") ?? 9481
        )

        do {
            let result = try await Auth.auth().signInAnonymously()
            print("OK signed in, uid=\(result.user.uid)")

            // Signing in is only half of it. The session has to survive a
            // relaunch, or every launch would ask the user to sign in again —
            // and that is the part that actually touches the keychain.
            guard let current = Auth.auth().currentUser else {
                print("FAIL signed in, but no current user was retained")
                exit(1)
            }
            let token = try await current.getIDToken()
            print("OK a token was issued, \(token.count) characters")
            try Auth.auth().signOut()
            print("OK signed out again")
            exit(0)
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }
}
