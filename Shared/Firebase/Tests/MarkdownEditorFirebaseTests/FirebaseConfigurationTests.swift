import Testing
@testable import MarkdownEditorFirebase

// The Firebase adapter is mostly a translation layer with no decisions in it —
// the decisions live next door in MarkdownEditorCloud, which is tested there
// without any of this. What is worth testing here is the configuration, because
// a wrong value produces a runtime failure that names the wrong cause.
//
// Run with: swift test --package-path Shared/Firebase
@Suite("Firebase configuration")
struct FirebaseConfigurationTests {
    @Test("The app ID in the repository is reported as not yet real")
    func placeholderIsReported() {
        // Deliberately asserting the *current* state. When an Apple app is
        // registered and its real ID pasted in, this test fails and is the
        // reminder to delete it along with the placeholder.
        let problem = FirebaseConfiguration.unresolvedConfiguration
        #expect(problem != nil)
        #expect(problem?.contains("com.kirupa.markdown-editor") == true)
    }

    @Test("The web app's ID is refused, however its platform is spelled")
    func webIdIsRefused() {
        // The failure this guards against: making the placeholder "real" by
        // copying the web app's ID out of config.js. It is well-formed, it
        // names the right project, and it is still not an Apple app.
        for id in [
            "1:777425511524:web:1bb6b0d961ab673031ab71",
            "1:777425511524:ios:1bb6b0d961ab673031ab71",
            "1:777425511524:macos:1bb6b0d961ab673031ab71",
        ] {
            #expect(FirebaseConfiguration.unresolvedConfiguration(for: id) != nil, "\(id)")
        }
    }

    @Test("An app ID with its own hash is accepted")
    func registeredIdIsAccepted() {
        #expect(FirebaseConfiguration.unresolvedConfiguration(
            for: "1:777425511524:ios:7c41e0f2a9b34d5e6f8a01"
        ) == nil)
    }

    @Test("The callback scheme is derived from the app ID")
    @MainActor
    func callbackSchemeFollowsTheAppID() {
        // It has to match CFBundleURLSchemes exactly or the system never hands
        // the OAuth callback back to the app, so it is worth pinning the shape.
        let scheme = GoogleSignInFlow.callbackScheme
        #expect(scheme.hasPrefix("app-"))
        #expect(!scheme.contains(":"))
        #expect(
            scheme == "app-" + FirebaseConfiguration.appID.replacingOccurrences(of: ":", with: "-")
        )
    }

    @Test("The project the native apps use is the one the web build uses")
    func projectMatchesTheWebBuild() {
        // Same project, or a document written on a Mac does not open on the
        // web. These are the values in Web/public/app/cloud/config.js.
        #expect(FirebaseConfiguration.projectID == "kirupa-markdown")
        #expect(FirebaseConfiguration.apiKey == "AIzaSyDpnMoGkLQ0hHa5y71kJ36A-ROlCU2oXZk")
        #expect(FirebaseConfiguration.authDomain == "kirupa-markdown.firebaseapp.com")
        #expect(FirebaseConfiguration.storageBucket == "kirupa-markdown.firebasestorage.app")
        #expect(FirebaseConfiguration.messagingSenderID == "777425511524")
    }
}
