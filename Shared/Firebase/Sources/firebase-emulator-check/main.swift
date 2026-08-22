// Runs the native Firestore adapter against a real Firestore.
//
// `MarkdownEditorCloudTests` covers the decisions — path arithmetic, subtree
// moves, collisions — against an in-memory double, which is what keeps that
// suite fast and offline. What it cannot cover is the adapter itself: whether
// `FirestoreNodeStore` writes the field names the rules validate, whether the
// range query in `subtree` needs its filter, whether a batch is atomic, and
// whether a listener fires. Those are properties of Firestore, so they need
// one.
//
// The emulator supplies it.
//
// It runs *unauthenticated*, against permissive rules, and that is deliberate
// rather than a shortcut. Two reasons.
//
// The first is forced: FirebaseAuth persists its session to the Keychain, and
// on macOS it asks for the data-protection keychain, which requires the
// `keychain-access-groups` entitlement. That entitlement is restricted — it
// needs a provisioning profile, so ad-hoc signing cannot grant it, and a
// binary that claims it anyway is SIGKILLed at exec. A SwiftPM executable
// therefore cannot sign in at all; `signInAnonymously()` fails with
// `SecItemAdd (-34018)`. Nothing about that is Firestore's behaviour, so
// working around it would buy nothing.
//
// The second is that it should have been this way regardless. The rules are
// one artifact shared by every client, and they are already verified — by
// `Web/firebase/check-rules.mjs`, which drives the real rules engine and
// covers the cross-account refusals. Asserting them again here would test
// Google's rules evaluator twice and this adapter zero times. What is *not*
// covered anywhere else, and is covered here, is whether `FirestoreNodeStore`
// speaks Firestore correctly: the field names it writes, whether the range
// query in `subtree` needs its filter, whether a batch is atomic, and whether
// a listener fires.
//
// `FirestoreNodeStore` takes a uid as a plain string and puts it in the
// document path, so the collection paths exercised here are the shipped ones
// even with no one signed in.
//
// What this deliberately does not cover: the Google sign-in flow, and
// `FirebaseConfiguration.appID`, which is still a placeholder because no Apple
// app has been registered. See the root README.
//
// Run it with `Shared/Firebase/run-emulator-checks.sh`, which owns the
// emulator lifecycle. Running it against the live project is not possible: it
// refuses to start unless the emulator host variable is set.

import Foundation
import FirebaseCore
import FirebaseFirestore
import MarkdownEditorCloud
import MarkdownEditorFirebase

// MARK: - Reporting

final class Report: @unchecked Sendable {
    private var passed = 0
    private var failed: [String] = []
    private var suite = ""

    func begin(_ name: String) {
        suite = name
        print("\n\(name)")
    }

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok {
            passed += 1
            print("  ok   \(name)")
        } else {
            let extra = detail()
            failed.append("\(suite): \(name)")
            print("  FAIL \(name)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    func equal<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        check(name, actual == expected, "expected \(expected), got \(actual)")
    }

    func finish() -> Int32 {
        print("\n\(passed) passed, \(failed.count) failed")
        for name in failed { print("  · \(name)") }
        return failed.isEmpty ? 0 : 1
    }
}

let report = Report()

// MARK: - Environment

guard let firestoreHost = ProcessInfo.processInfo.environment["MDE_FIRESTORE_EMULATOR"] else {
    FileHandle.standardError.write(Data(
        "error: MDE_FIRESTORE_EMULATOR must be set.\n".utf8))
    FileHandle.standardError.write(Data(
        "Run this through Shared/Firebase/run-emulator-checks.sh.\n".utf8))
    exit(2)
}

/// Points the SDK at the emulator *before* anything touches Firestore.
///
/// `FirebaseConfiguration.start()` is deliberately not used: it configures the
/// persistent on-disk cache, which would carry state between runs and make a
/// second run pass on data the first one left behind. Everything else — the
/// project, the key, the collection names — comes from the same file the apps
/// use, so the paths and field names under test are the shipped ones.
func connectToEmulator() {
    let options = FirebaseOptions(
        googleAppID: FirebaseConfiguration.appID,
        gcmSenderID: FirebaseConfiguration.messagingSenderID
    )
    options.projectID = FirebaseConfiguration.projectID
    options.apiKey = FirebaseConfiguration.apiKey
    options.storageBucket = FirebaseConfiguration.storageBucket
    FirebaseApp.configure(options: options)

    let settings = Firestore.firestore().settings
    settings.host = firestoreHost
    settings.isSSLEnabled = false
    settings.cacheSettings = MemoryCacheSettings()
    Firestore.firestore().settings = settings
}

func node(_ path: String, text: String? = nil, kind: CloudNodeKind = .file) -> CloudNode {
    CloudNode(kind: kind, path: path, text: text, size: text?.utf8.count)
}

/// A second Firestore client against the same emulator, standing in for
/// another device.
///
/// Needed rather than convenient. `watchNode` drops any snapshot with
/// `hasPendingWrites` — the local-echo guard — and a listener without
/// `includeMetadataChanges` gets no further snapshot when the server
/// acknowledges a write whose data has not changed. So a client cannot observe
/// its own write at all, and a listener check that writes through the same
/// store is testing nothing. That is also the behaviour the sync policy is
/// built on, so it is asserted here rather than assumed.
///
/// `FirestoreNodeStore` uses the default app, so the stand-in writes through a
/// raw reference. It builds that reference from `CloudPath.documentId`, the
/// same function the store uses, because the point here is the listener, not
/// the ID encoding.
func otherDeviceWrites(_ node: CloudNode, forUid uid: String) async throws {
    let name = "other-device"
    if FirebaseApp.app(name: name) == nil {
        let options = FirebaseOptions(
            googleAppID: FirebaseConfiguration.appID,
            gcmSenderID: FirebaseConfiguration.messagingSenderID
        )
        options.projectID = FirebaseConfiguration.projectID
        options.apiKey = FirebaseConfiguration.apiKey
        options.storageBucket = FirebaseConfiguration.storageBucket
        FirebaseApp.configure(name: name, options: options)
    }
    guard let app = FirebaseApp.app(name: name) else {
        throw NSError(domain: "check", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "could not create the second client",
        ])
    }
    let other = Firestore.firestore(app: app)
    let settings = other.settings
    settings.host = firestoreHost
    settings.isSSLEnabled = false
    settings.cacheSettings = MemoryCacheSettings()
    other.settings = settings

    try await other
        .collection(FirebaseConfiguration.usersCollection)
        .document(uid)
        .collection(FirebaseConfiguration.nodesCollection)
        .document(try CloudPath.documentId(for: node.path))
        .setData(node.fields)
}

/// Waits for a listener to deliver a node the caller accepts, or times out.
///
/// Specific to `watchNode` rather than generic: a generic version has to hold
/// `CloudNode?` and hand back `CloudNode??`, and the extra layer is only ever
/// noise at the call site.
func awaitNode(
    _ store: FirestoreNodeStore,
    at path: String,
    timeout: TimeInterval = 10,
    matching: @escaping @Sendable (CloudNode?) -> Bool
) async -> CloudNode? {
    let box = Box<CloudNode?>()
    let subscription = store.watchNode(at: path) { node in
        if matching(node) { box.resolve(node) }
    }
    defer { subscription.cancel() }
    return await box.wait(timeout: timeout) ?? nil
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var continuation: CheckedContinuation<T?, Never>?

    func resolve(_ next: T) {
        let waiting: CheckedContinuation<T?, Never>? = lock.withLock {
            guard value == nil else { return nil }
            value = next
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: next)
    }

    func wait(timeout: TimeInterval) async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let ready: T? = lock.withLock {
                if let value { return value }
                continuation = c
                return nil
            }
            if let ready {
                c.resume(returning: ready)
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                let waiting: CheckedContinuation<T?, Never>? = self.lock.withLock {
                    defer { self.continuation = nil }
                    return self.continuation
                }
                waiting?.resume(returning: nil)
            }
        }
    }
}

// MARK: - Checks

func run() async -> Int32 {
    connectToEmulator()

    // A fresh uid per run rather than a fixed one, so a run cannot pass on
    // data an earlier run left behind even if the emulator is not restarted.
    let uid = "check-\(UUID().uuidString)"

    let store = FirestoreNodeStore(uid: uid)

    report.begin("A document survives the round trip")
    do {
        try await store.commit([.put(node("Notes/Ideas.md", text: "# Ideas\n\nOne\n"))])
        let read = try await store.read("Notes/Ideas.md")
        report.check("the document reads back", read != nil)
        report.equal("its text is unchanged", read?.text, "# Ideas\n\nOne\n")
        report.equal("its parent is derived, not stored by hand", read?.parent, "Notes")
        report.equal("its name is the last component", read?.name, "Ideas.md")
        report.equal("its kind survives", read?.kind, .file)
    } catch {
        report.check("the round trip completed", false, "\(error)")
    }

    report.begin("The field names are the ones the rules validate")
    do {
        // Read the raw document rather than the decoded one: a rename of any
        // of these breaks the web build, which writes into this collection
        // too, and the rules refuse a document whose keys they do not know.
        //
        // Found by query rather than by document ID, so this does not depend
        // on how the adapter encodes a path into an ID.
        let matches = try await Firestore.firestore()
            .collection(FirebaseConfiguration.usersCollection)
            .document(uid)
            .collection(FirebaseConfiguration.nodesCollection)
            .whereField("path", isEqualTo: "Notes/Ideas.md")
            .getDocuments()
        let data = matches.documents.first?.data() ?? [:]
        report.check("the node was found by its path field", !data.isEmpty)
        // `type`, not `kind`: the Swift property is `kind`, but the stored
        // field is `type`, because that is the name firestore.rules validates
        // and the name the web build writes.
        for key in ["type", "path", "parent", "name", "modified", "text"] {
            report.check("`\(key)` is stored under that name", data[key] != nil)
        }
        report.equal("`type` is one of the strings the rules list",
                     data["type"] as? String, "file")
    } catch {
        report.check("the stored shape could be read", false, "\(error)")
    }

    report.begin("The subtree query needs its filter")
    do {
        try await store.commit([
            .put(node("Notes", kind: .folder)),
            .put(node("Notes 2", kind: .folder)),
            .put(node("Notes 2/Out.md", text: "out")),
            .put(node("Notes.md", text: "sibling")),
            .put(node("Notes/In.md", text: "in")),
        ])
        let subtree = try await store.subtree(of: "Notes")
        let paths = Set(subtree.map(\.path))
        report.check("the folder's own descendants are returned", paths.contains("Notes/In.md"))
        report.check("a sibling folder that shares the prefix is excluded",
                     !paths.contains("Notes 2/Out.md"), "got \(paths.sorted())")
        report.check("a sibling file that shares the prefix is excluded",
                     !paths.contains("Notes.md"), "got \(paths.sorted())")

        // The same range without the separator filter, to show the filter is
        // load-bearing rather than decoration.
        let unfiltered = try await Firestore.firestore()
            .collection(FirebaseConfiguration.usersCollection)
            .document(uid)
            .collection(FirebaseConfiguration.nodesCollection)
            .whereField("path", isGreaterThanOrEqualTo: "Notes")
            .whereField("path", isLessThan: "Notes\u{f8ff}")
            .getDocuments()
        let overmatched = Set(unfiltered.documents.compactMap { $0.data()["path"] as? String })
        report.check("the raw range really does over-match, so the filter is load-bearing",
                     overmatched.contains("Notes 2/Out.md") && overmatched.contains("Notes.md"),
                     "got \(overmatched.sorted())")
    } catch {
        report.check("the subtree checks ran", false, "\(error)")
    }

    report.begin("Children are the direct ones only")
    do {
        let children = try await store.children(of: "Notes")
        let paths = Set(children.map(\.path))
        report.check("a direct child is listed", paths.contains("Notes/In.md"))
        report.check("the folder itself is not its own child", !paths.contains("Notes"))
        report.check("a same-prefix sibling is not listed", !paths.contains("Notes.md"),
                     "got \(paths.sorted())")
    } catch {
        report.check("the children checks ran", false, "\(error)")
    }

    report.begin("A batch is refused whole or not at all")
    do {
        // The create-before-delete ordering in CloudWorkspace rests on this:
        // if a batch were partial, an interrupted move would lose a document
        // rather than duplicate it.
        let before = try await store.read("Notes/In.md")
        do {
            try await store.commit([
                .put(node("Notes/Fine.md", text: "fine")),
                // Refused by Firestore itself, not by the rules: a single
                // property cannot exceed 1,048,487 bytes. That limit is the
                // right lever here precisely because it holds whatever the
                // rules say, so this check keeps working under the shipped
                // rules and under the permissive ones this runs against.
                .put(CloudNode(kind: .file, path: "Notes/TooBig.md",
                               text: String(repeating: "x", count: 1_100_000))),
            ])
            report.check("a batch containing a refused write fails", false, "it was accepted")
        } catch {
            report.check("a batch containing a refused write fails", true)
        }
        let after = try await store.read("Notes/Fine.md")
        report.check("the acceptable write in that batch did not land either", after == nil,
                     "\(String(describing: after?.path))")
        report.check("the untouched document is still there", before != nil)
    } catch {
        report.check("the atomicity checks ran", false, "\(error)")
    }

    report.begin("A listener sees another device's change")
    do {
        // Nothing has written it yet, so the attach snapshot must not match.
        let seen = await awaitNode(store, at: "Notes/Live.md", timeout: 3) {
            $0?.text == "from elsewhere"
        }
        report.check("a document that does not exist does not deliver a match", seen == nil)

        async let delivery = awaitNode(store, at: "Notes/Live.md") {
            $0?.text == "from elsewhere"
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await otherDeviceWrites(
            node("Notes/Live.md", text: "from elsewhere"), forUid: uid)
        let arrived = await delivery
        report.check("a write is delivered to a watching listener", arrived != nil)
        report.equal("with the text that was written", arrived?.text, "from elsewhere")

        // The other half of the same guarantee, and the reason the check above
        // needs a second client at all. If a client saw its own writes, every
        // keystroke would race its own echo — which is exactly the bug the web
        // build hit when `save()` re-read the text after awaiting.
        async let echo = awaitNode(store, at: "Notes/Echo.md", timeout: 3) { $0 != nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await store.commit([.put(node("Notes/Echo.md", text: "mine"))])
        let echoed = await echo
        report.check("a client is not delivered its own write", echoed == nil,
                     "got \(String(describing: echoed?.text))")
        let stored = try await store.read("Notes/Echo.md")
        report.equal("even though the write did land", stored?.text, "mine")
    } catch {
        report.check("the listener checks ran", false, "\(error)")
    }

    report.begin("Two accounts are two collections")
    do {
        // Not a rules assertion — rules are verified by
        // Web/firebase/check-rules.mjs against the real engine. This is the
        // adapter's own half of the same guarantee: that the uid reaches the
        // document path, so one account's store cannot even name another's
        // documents. If the uid were dropped from the path, the rules would
        // be the only thing left separating two people's files.
        let other = FirestoreNodeStore(uid: uid + "-someone-else")
        let mine = try await store.read("Notes/Ideas.md")
        let theirs = try await other.read("Notes/Ideas.md")
        report.check("this account still reads its own document", mine != nil)
        report.check("another account reads nothing at the same path", theirs == nil,
                     "got \(String(describing: theirs?.text))")

        try await other.commit([.put(node("Notes/Ideas.md", text: "theirs"))])
        let unchanged = try await store.read("Notes/Ideas.md")
        report.equal("and writing there does not touch this one",
                     unchanged?.text, mine?.text)
    } catch {
        report.check("the isolation checks ran", false, "\(error)")
    }

    return report.finish()
}

exit(await run())
