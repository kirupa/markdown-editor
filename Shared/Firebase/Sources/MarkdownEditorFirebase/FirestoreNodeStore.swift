import Foundation
import FirebaseCore
import FirebaseFirestore
import MarkdownEditorCloud

/// Firestore, behind the four reads and one write `CloudNodeStore` asks for.
///
/// Deliberately thin, for the same reason `Web/public/app/cloud/firestore-store.js`
/// is thin: this is the part that cannot run without a network, so there is as
/// little of it as possible and each piece maps onto one SDK call. Everything
/// with a decision in it is in `MarkdownEditorCloud`, under test.
public struct FirestoreNodeStore: CloudNodeStore {
    /// Firestore refuses a batch of more than 500 writes, and a subtree can
    /// exceed that.
    private static let batchLimit = 500

    /// The last code point Firestore sorts below, for a prefix range query.
    private static let highSentinel = "\u{f8ff}"

    /// Only the account ID is stored. The Firestore handles are fetched per
    /// call because they are not `Sendable` — the SDK documents them as
    /// thread-safe but does not annotate them, and holding one here would mean
    /// vouching for that with `@unchecked`. `Firestore.firestore()` returns the
    /// same cached instance every time, so this costs nothing.
    private let uid: String

    public init(uid: String) {
        self.uid = uid
    }

    private var collection: CollectionReference {
        Firestore.firestore()
            .collection(FirebaseConfiguration.usersCollection)
            .document(uid)
            .collection(FirebaseConfiguration.nodesCollection)
    }

    private func reference(for path: String) throws -> DocumentReference {
        collection.document(try CloudPath.documentId(for: path))
    }

    public func read(_ path: String) async throws -> CloudNode? {
        do {
            let snapshot = try await reference(for: path).getDocument()
            guard let data = snapshot.data() else { return nil }
            return CloudNode(fields: data)
        } catch {
            throw Self.translate(error, doing: "open \(CloudPath.name(of: path))")
        }
    }

    /// Equality on one field, sorted by the caller afterwards.
    ///
    /// Adding an `order(by:)` here would make it a composite query, which
    /// Firestore will not serve until someone clicks through a console link to
    /// build an index. A folder holds few enough entries to sort in the app, so
    /// this works the moment it ships rather than after a manual step.
    public func children(of parent: String) async throws -> [CloudNode] {
        try await run(
            collection.whereField(CloudNode.Field.parent, isEqualTo: parent),
            doing: "list that folder"
        )
    }

    /// A range over `path`, then narrowed.
    ///
    /// The narrowing is not belt-and-braces. `path >= "Notes"` and
    /// `path < "Notes\u{f8ff}"` also matches `Notes 2/Out.md` and `Notes.md`,
    /// because a range over strings knows nothing about separators. Without it,
    /// renaming a folder drags its similarly named neighbours along and deleting
    /// one takes them with it. `CloudPath.descendants` is the shared, tested
    /// version of that filter, so this file has no decision left in it.
    public func subtree(of folder: String) async throws -> [CloudNode] {
        if folder.isEmpty {
            return try await run(collection, doing: "read your workspace")
        }
        let rows = try await run(
            collection
                .whereField(CloudNode.Field.path, isGreaterThanOrEqualTo: folder)
                .whereField(CloudNode.Field.path, isLessThan: folder + Self.highSentinel),
            doing: "read that folder"
        )
        return CloudPath.descendants(of: folder, in: rows, path: \.path)
    }

    /// Writes in chunks, applied in order.
    ///
    /// One batch is atomic; several are not. `CloudWorkspace` orders its writes
    /// so every create precedes the delete it replaces, which means an
    /// interruption between chunks leaves nodes duplicated rather than lost.
    /// Losing nothing is the property worth having.
    public func commit(_ writes: [CloudWrite]) async throws {
        for group in stride(from: 0, to: writes.count, by: Self.batchLimit) {
            let slice = writes[group..<min(group + Self.batchLimit, writes.count)]
            let batch = collection.firestore.batch()
            for write in slice {
                let reference = try reference(for: write.path)
                if let node = write.node {
                    batch.setData(node.fields, forDocument: reference)
                } else {
                    batch.deleteDocument(reference)
                }
            }
            do {
                try await batch.commit()
            } catch {
                throw Self.translate(error, doing: "save that change")
            }
        }
    }

    public func watchChildren(
        of parent: String,
        onChange: @escaping @Sendable ([CloudNode]) -> Void
    ) -> CloudSubscription {
        watch(
            collection.whereField(CloudNode.Field.parent, isEqualTo: parent),
            describing: "folder"
        ) { onChange($0) }
    }

    public func watchNode(
        at path: String,
        onChange: @escaping @Sendable (CloudNode?) -> Void
    ) -> CloudSubscription {
        guard let reference = try? reference(for: path) else { return .inert }
        let registration = reference.addSnapshotListener { snapshot, error in
            if let error {
                print("Live document updates stopped: \(error.localizedDescription)")
                return
            }
            guard let snapshot else { return }
            // See `isLocalEcho` below.
            if snapshot.metadata.hasPendingWrites { return }
            onChange(snapshot.data().flatMap(CloudNode.init(fields:)))
        }
        return CloudSubscription.detaching(registration)
    }

    // MARK: - Plumbing

    private func run(_ query: Query, doing: String) async throws -> [CloudNode] {
        do {
            return try await query.getDocuments().documents.compactMap { CloudNode(fields: $0.data()) }
        } catch {
            throw Self.translate(error, doing: doing)
        }
    }

    /// A snapshot this device caused, which the caller has already applied.
    ///
    /// Firestore answers a write from the local cache before the server has
    /// acknowledged it, so every save comes back through every listener within
    /// milliseconds. The editor already has that text — it is what it just sent
    /// — and treating it as an incoming change would re-render the pane out from
    /// under whoever is typing. `hasPendingWrites` means exactly "this snapshot
    /// contains a local write the server has not confirmed", so it is the
    /// precise signal to skip.
    ///
    /// The server's later echo of the same write arrives with the flag cleared.
    /// That one is not skipped here: it is indistinguishable from another device
    /// sending identical text, and is compared by content upstream where the
    /// current text is known.
    private func watch(
        _ query: Query,
        describing what: String,
        onChange: @escaping @Sendable ([CloudNode]) -> Void
    ) -> CloudSubscription {
        let registration = query.addSnapshotListener { snapshot, error in
            if let error {
                // Not thrown: there is no caller standing underneath a callback
                // to catch it. Firestore retries a dropped listener by itself
                // and the app keeps working from what it already has.
                print("Live \(what) updates stopped: \(error.localizedDescription)")
                return
            }
            guard let snapshot, !snapshot.metadata.hasPendingWrites else { return }
            onChange(snapshot.documents.compactMap { CloudNode(fields: $0.data()) })
        }
        return CloudSubscription.detaching(registration)
    }

    /// Turns a Firestore error code into something worth showing someone.
    ///
    /// `permissionDenied` in particular has a specific, actionable cause here:
    /// the rules in `Web/firebase/firestore.rules` have not been published to
    /// the project. Saying so beats "an internal error occurred".
    static func translate(_ error: Error, doing: String) -> CloudError {
        let code = FirestoreErrorCode.Code(rawValue: (error as NSError).code)
        switch code {
        case .permissionDenied:
            return .permissionDenied(doing)
        case .unavailable, .failedPrecondition:
            return .offline(doing)
        case .unauthenticated:
            return .notSignedIn
        default:
            return .underlying("Could not \(doing). \(error.localizedDescription)")
        }
    }
}

extension CloudSubscription {
    /// Wraps a Firestore listener handle so releasing the subscription detaches
    /// it.
    ///
    /// The box is needed only because `ListenerRegistration` is not annotated
    /// `Sendable` while `CloudSubscription`'s cancel closure is. The SDK
    /// documents `remove()` as safe to call from any thread, so the annotation
    /// is the thing that is missing, not the guarantee. Detaching matters:
    /// Firestore bills per document read and a listener nobody is holding goes
    /// on reading.
    static func detaching(_ registration: ListenerRegistration) -> CloudSubscription {
        let box = UncheckedBox(registration)
        return CloudSubscription { box.value.remove() }
    }
}
