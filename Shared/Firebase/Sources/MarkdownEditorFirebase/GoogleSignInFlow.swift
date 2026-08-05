import Foundation
import AuthenticationServices
import FirebaseAuth
import MarkdownEditorCloud

/// Google sign-in, on both platforms, using only public API.
///
/// Firebase ships a web sign-in flow of its own — `OAuthProvider.credential(with:)`
/// — but it is declared `@available(macOS, unavailable)`, and the credential it
/// builds internally uses an initializer that is not public. So on the Mac
/// there is no supported way to call it, and the alternative that most apps
/// reach for, the separate GoogleSignIn SDK, is another dependency to add to
/// the one this project already argued itself into.
///
/// What is public is the rest of the same flow. `ASWebAuthenticationSession` is
/// the system's OAuth browser, Firebase Hosting already serves the handler page
/// at `https://<authDomain>/__/auth/handler` that the web build signs in
/// through, and `GoogleAuthProvider.credential(withIDToken:accessToken:)` turns
/// the tokens that come back into a Firebase credential. This runs that.
///
/// The callback scheme is `app-` plus the Firebase app ID with its colons
/// swapped for hyphens, which is exactly what the iOS SDK derives for itself.
/// It is worth knowing that it comes from the app ID and not from an OAuth
/// client ID, because it means signing in needs nothing registered in the
/// Google Cloud console — only the app's own URL scheme, which is in this repo.
@MainActor
public enum GoogleSignInFlow {
    /// The custom URL scheme the handler redirects back to. Must also appear in
    /// each app's Info.plist under `CFBundleURLSchemes`, or the system will not
    /// hand the callback back to us.
    public static var callbackScheme: String {
        "app-" + FirebaseConfiguration.appID.replacingOccurrences(of: ":", with: "-")
    }

    /// Runs the browser flow and returns a Firebase credential.
    public static func credential(
        presentingFrom anchor: ASPresentationAnchor?
    ) async throws -> AuthCredential {
        let url = try handlerURL()
        let callback = try await present(url, anchor: anchor)
        let tokens = try tokens(fromCallback: callback)
        return GoogleAuthProvider.credential(
            withIDToken: tokens.idToken,
            accessToken: tokens.accessToken ?? ""
        )
    }

    // MARK: - The request

    /// The same query the iOS SDK sends, so the handler behaves identically for
    /// both apps and there is one flow to reason about rather than two.
    static func handlerURL(
        bundleID: String? = Bundle.main.bundleIdentifier,
        eventID: String = UUID().uuidString
    ) throws -> URL {
        var components = URLComponents(
            string: "https://\(FirebaseConfiguration.authDomain)/__/auth/handler"
        )
        components?.queryItems = [
            URLQueryItem(name: "apiKey", value: FirebaseConfiguration.apiKey),
            URLQueryItem(name: "authType", value: "signInWithRedirect"),
            URLQueryItem(name: "providerId", value: "google.com"),
            URLQueryItem(name: "appId", value: FirebaseConfiguration.appID),
            URLQueryItem(name: "ibi", value: bundleID ?? ""),
            URLQueryItem(name: "eventId", value: eventID),
            URLQueryItem(name: "scopes", value: "profile,email"),
            URLQueryItem(name: "v", value: "MarkdownEditor-native"),
        ]
        guard let url = components?.url else {
            throw CloudError.signInFailed("The sign-in address could not be built.")
        }
        return url
    }

    // MARK: - The response

    struct Tokens: Equatable {
        var idToken: String
        var accessToken: String?
    }

    /// Pulls the tokens out of whichever part of the callback carries them.
    ///
    /// The handler has used more than one shape over the years: sometimes the
    /// tokens are query items on the callback itself, sometimes they are on a
    /// nested `link`, and an implicit OAuth response conventionally puts them in
    /// the fragment. Rather than depend on one of those, this looks in all of
    /// them — it is a handful of lines, and it means a change at Google's end
    /// that moves the tokens does not lock everyone out.
    static func tokens(fromCallback url: URL) throws -> Tokens {
        var items = parameters(of: url)

        if let nested = items["link"] ?? items["deep_link_id"],
           let nestedURL = URL(string: nested) {
            // A nested link is the authoritative one when it is present.
            items = parameters(of: nestedURL).merging(items) { nestedValue, _ in nestedValue }
        }

        if let failure = items["firebaseError"] {
            throw CloudError.signInFailed(Self.message(fromFirebaseError: failure))
        }
        guard let idToken = items["id_token"] ?? items["idToken"] else {
            throw CloudError.signInFailed(
                "Google did not return an identity token. Check that Google is enabled as a sign-in provider for the kirupa-markdown project."
            )
        }
        return Tokens(idToken: idToken, accessToken: items["access_token"] ?? items["accessToken"])
    }

    /// Query items and fragment items together, fragment winning, because an
    /// implicit OAuth response puts the useful half after the `#`.
    private static func parameters(of url: URL) -> [String: String] {
        var found: [String: String] = [:]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        for item in components?.queryItems ?? [] {
            if let value = item.value { found[item.name] = value }
        }
        if let fragment = components?.fragment {
            var fragmentComponents = URLComponents()
            fragmentComponents.percentEncodedQuery = fragment
            for item in fragmentComponents.queryItems ?? [] {
                if let value = item.value { found[item.name] = value }
            }
        }
        return found
    }

    /// The handler reports failures as a JSON blob; show the message, not the JSON.
    private static func message(fromFirebaseError raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? String else {
            return raw
        }
        return message
    }

    // MARK: - The browser

    private static func present(_ url: URL, anchor: ASPresentationAnchor?) async throws -> URL {
        let presenter = AnchorPresenter(anchor: anchor)
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: CloudError.signInCancelled)
                } else {
                    continuation.resume(
                        throwing: CloudError.signInFailed(error?.localizedDescription ?? "The sign-in window closed.")
                    )
                }
            }
            session.presentationContextProvider = presenter
            // Not ephemeral: reusing the browser's existing Google session is
            // what makes this one tap for someone already signed in to Google.
            session.prefersEphemeralWebBrowserSession = false
            presenter.keepAlive(session)

            if !session.start() {
                continuation.resume(
                    throwing: CloudError.signInFailed("The sign-in window could not be opened.")
                )
            }
        }
    }

    /// Holds the window the sheet hangs from, and the session itself — the
    /// system keeps only a weak reference and a deallocated session cancels.
    private final class AnchorPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
        private let anchor: ASPresentationAnchor?
        private var session: ASWebAuthenticationSession?

        init(anchor: ASPresentationAnchor?) {
            self.anchor = anchor
        }

        func keepAlive(_ session: ASWebAuthenticationSession) {
            self.session = session
        }

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            anchor ?? ASPresentationAnchor()
        }
    }
}
