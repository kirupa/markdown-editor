import Foundation
import FirebaseCore
import FirebaseFirestore

/// The Firebase project the native apps talk to — the same one the web build
/// uses, so a document written on a Mac opens on the web and the other way
/// round.
///
/// Configured in code rather than from a `GoogleService-Info.plist`. The plist
/// is only a container for these same values, and there would have to be two of
/// them, one per app target, kept in step by hand. This is one copy, next to
/// the code that reads it, and it can be compared against
/// `Web/public/app/cloud/config.js` at a glance.
///
/// Yes, the API key is here in a public repository, and that is fine: a Firebase
/// API key names a project, it does not grant access to one. Every client that
/// ever runs the app must have it. What decides who may read or write anything
/// is the Security Rules in `Web/firebase/`. Google says as much:
/// https://firebase.google.com/docs/projects/api-keys
public enum FirebaseConfiguration {
    public static let projectID = "kirupa-markdown"
    public static let apiKey = "AIzaSyDpnMoGkLQ0hHa5y71kJ36A-ROlCU2oXZk"
    public static let authDomain = "kirupa-markdown.firebaseapp.com"
    public static let storageBucket = "kirupa-markdown.firebasestorage.app"
    public static let messagingSenderID = "777425511524"

    /// A Firebase app ID is per platform, so this is not the web build's ID.
    /// Both point at the same project and therefore the same Firestore data.
    public static let appID = "1:777425511524:ios:1bb6b0d961ab673031ab71"

    /// The collection layout, matching `config.js`: a subcollection per user, so
    /// the rules are a path match and cannot be got wrong for one document.
    public static let usersCollection = "users"
    public static let nodesCollection = "nodes"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var isConfigured = false

    /// Starts Firebase once, whichever entry point gets there first.
    public static func start() {
        lock.withLock {
            guard !isConfigured else { return }
            isConfigured = true

            if FirebaseApp.app() == nil {
                let options = FirebaseOptions(googleAppID: appID, gcmSenderID: messagingSenderID)
                options.projectID = projectID
                options.apiKey = apiKey
                options.storageBucket = storageBucket
                FirebaseApp.configure(options: options)
            }

            configureFirestore()
        }
    }

    /// Turns on the on-disk cache before anything touches Firestore.
    ///
    /// This is the whole reason the apps use the SDK instead of the REST API.
    /// With it, documents already opened on this device open again with no
    /// network, edits made offline are queued and sent when there is one, and
    /// the app is not a blank window on a train. It has to be set before the
    /// first Firestore call or the SDK throws.
    ///
    /// The cache holds what this device has opened, not the whole account — the
    /// same limit the web build has, and worth saying out loud because
    /// "available offline" is easy to over-promise.
    private static func configureFirestore() {
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings()
        Firestore.firestore().settings = settings
    }
}
