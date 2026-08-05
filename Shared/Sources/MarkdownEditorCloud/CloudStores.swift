import Foundation

/// One write in a batch: either a node to put, or a path to remove.
public struct CloudWrite: Sendable {
    public var path: String
    public var node: CloudNode?

    public static func put(_ node: CloudNode) -> CloudWrite {
        CloudWrite(path: node.path, node: node)
    }

    public static func remove(_ path: String) -> CloudWrite {
        CloudWrite(path: path, node: nil)
    }

    public var isRemoval: Bool { node == nil }
}

/// The database, four reads and one write wide.
///
/// This protocol is the whole point of the split. `CloudWorkspace` holds the
/// decisions — what a collision is, what counts as a descendant, what a move
/// does to a subtree — and talks only to this. The Firestore implementation is
/// small enough to read in one sitting and needs a network; the decisions are
/// the part with bugs in them and run against an in-memory double under test.
/// The web build is arranged the same way and for the same reason.
public protocol CloudNodeStore: Sendable {
    func read(_ path: String) async throws -> CloudNode?
    /// One level. Sorting is the caller's job, deliberately: ordering in the
    /// query would make it a composite index Firestore refuses to serve until
    /// one is built by hand.
    func children(of parent: String) async throws -> [CloudNode]
    /// A folder and everything beneath it, at any depth.
    func subtree(of folder: String) async throws -> [CloudNode]
    func commit(_ writes: [CloudWrite]) async throws

    /// Calls back with one level whenever it changes. The returned handle stops
    /// delivery when it is released or cancelled.
    func watchChildren(of parent: String, onChange: @escaping @Sendable ([CloudNode]) -> Void) -> CloudSubscription
    /// Calls back with one node, or `nil` once it is gone.
    func watchNode(at path: String, onChange: @escaping @Sendable (CloudNode?) -> Void) -> CloudSubscription
}

/// Where image bytes live. Separate from the node store because they are in a
/// different service — Cloud Storage, not Firestore — for reasons written up in
/// `Web/README.md` §11b.
public protocol CloudAssetStore: Sendable {
    /// Returns a download URL.
    func upload(_ data: Data, to storagePath: String, contentType: String?) async throws -> String
    /// Returns the new download URL. Copied through the client, because Storage
    /// has no server-side copy.
    func copy(from: String, to: String) async throws -> String
    func removeAll(_ storagePaths: [String]) async throws
}

/// A live listener. Releasing it, or calling `cancel`, stops delivery.
///
/// A class rather than a closure so that dropping the last reference detaches
/// the listener on its own — a listener that outlives the view watching it is
/// the easiest way to leak reads in Firestore, and it is billed per read.
public final class CloudSubscription: @unchecked Sendable {
    private var onCancel: (@Sendable () -> Void)?
    private let lock = NSLock()

    public init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public static var inert: CloudSubscription { CloudSubscription {} }

    public func cancel() {
        lock.lock()
        let cancellation = onCancel
        onCancel = nil
        lock.unlock()
        cancellation?()
    }

    deinit { cancel() }
}
