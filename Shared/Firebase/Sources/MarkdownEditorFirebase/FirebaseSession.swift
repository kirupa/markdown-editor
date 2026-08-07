import Foundation
import AuthenticationServices
import FirebaseAuth
import MarkdownEditorCloud

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Who is signed in, and the workspace that follows from it.
///
/// Observable so the interface can bind to it: the whole app is either signed
/// out or looking at one account's documents, and that is the only state worth
/// broadcasting.
@MainActor
public final class FirebaseSession: ObservableObject {
    @Published public private(set) var user: FirebaseUser?
    @Published public private(set) var isWorking = false
    @Published public private(set) var failure: CloudError?

    /// The cloud workspace for the signed-in account, or `nil` when signed out.
    /// Rebuilt on every sign-in so a second account cannot inherit the first's
    /// stores.
    @Published public private(set) var workspace: CloudWorkspace?

    /// Boxed so `deinit`, which is not isolated, can still detach it.
    private let listener = UncheckedBox<AuthStateDidChangeListenerHandle?>(nil)

    public init() {
        FirebaseConfiguration.start()
        listener.value = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.adopt(user) }
        }
    }

    deinit {
        if let handle = listener.value { Auth.auth().removeStateDidChangeListener(handle) }
    }

    public var isSignedIn: Bool { user != nil }

    private func adopt(_ user: User?) {
        guard let user else {
            self.user = nil
            self.workspace = nil
            return
        }
        self.user = FirebaseUser(
            uid: user.uid,
            displayName: user.displayName,
            email: user.email,
            photoURL: user.photoURL
        )
        self.workspace = CloudWorkspace(
            nodes: FirestoreNodeStore(uid: user.uid),
            assets: FirebaseAssetStore(uid: user.uid)
        )
    }

    /// Signs in with Google. See `GoogleSignInFlow` for why it is done by hand
    /// rather than through `OAuthProvider`.
    public func signIn(presentingFrom anchor: ASPresentationAnchor? = nil) async {
        isWorking = true
        failure = nil
        defer { isWorking = false }

        // Checked before the browser opens. Without this the flow fails only
        // once the user has picked a Google account, with a message about the
        // OAuth request rather than about the app ID that caused it.
        if let problem = FirebaseConfiguration.unresolvedConfiguration {
            failure = .signInFailed(problem)
            return
        }

        do {
            let credential = try await GoogleSignInFlow.credential(presentingFrom: anchor)
            _ = try await Auth.auth().signIn(with: credential)
        } catch {
            failure = Self.translate(error)
        }
    }

    public func signOut() {
        do {
            try Auth.auth().signOut()
        } catch {
            failure = .underlying("Could not sign out. \(error.localizedDescription)")
        }
    }

    public func dismissFailure() {
        failure = nil
    }

    static func translate(_ error: Error) -> CloudError {
        if let cloudError = error as? CloudError { return cloudError }
        switch AuthErrorCode(rawValue: (error as NSError).code) {
        case .webContextCancelled:
            return .signInCancelled
        case .networkError:
            return .offline("sign in")
        case .operationNotAllowed:
            // The most likely failure on a fresh project, and one nobody
            // guesses from a generic message.
            return .signInFailed("Google sign-in is not enabled for this Firebase project.")
        default:
            return .signInFailed(error.localizedDescription)
        }
    }
}

/// The parts of a Firebase user the interface actually shows.
public struct FirebaseUser: Sendable, Equatable {
    public var uid: String
    public var displayName: String?
    public var email: String?
    public var photoURL: URL?

    /// What to put next to the sign-out button, falling back rather than
    /// showing an empty space.
    public var label: String {
        displayName ?? email ?? "Signed in"
    }
}
