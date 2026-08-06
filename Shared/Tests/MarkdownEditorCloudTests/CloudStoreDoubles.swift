import Foundation
@testable import MarkdownEditorCloud

/// An in-memory stand-in for Firestore.
///
/// It is not a convenience. The whole reason `CloudWorkspace` talks to a
/// protocol is so the decisions can run without a network, and that is only
/// worth anything if the double reproduces the query semantics the decisions
/// are written against. Two in particular:
///
/// - `children(of:)` is an equality match on `parent`, not a prefix match, so a
///   grandchild never appears in a listing.
/// - `subtree(of:)` is a **range** query on `path`, exactly as the real one is,
///   and so the query itself also matches `Notes 2/Out.md` and `Notes.md` when
///   asked for `Notes`. It then narrows the result through
///   `CloudPath.descendants(of:in:path:)` — the same call the Firestore store
///   makes, for the same reason. Doing the over-fetch first and discarding
///   after is not busywork here: it is what makes the double wrong in exactly
///   the way the real thing is wrong, so the shared filter is what both depend
///   on and a test can delete it and watch this go red.
final class InMemoryNodeStore: CloudNodeStore, @unchecked Sendable {
    private var storage: [String: CloudNode] = [:]
    private let lock = NSLock()
    private var childWatchers: [(parent: String, id: UUID, deliver: @Sendable ([CloudNode]) -> Void)] = []
    private var nodeWatchers: [(path: String, id: UUID, deliver: @Sendable (CloudNode?) -> Void)] = []

    /// Every batch committed, so a test can assert on ordering — creates must
    /// precede the deletes they replace.
    private(set) var commits: [[CloudWrite]] = []

    init(_ nodes: [CloudNode] = []) {
        for node in nodes { storage[node.path] = node }
    }

    var allPaths: [String] {
        lock.withLock { storage.keys.sorted() }
    }

    func node(at path: String) -> CloudNode? {
        lock.withLock { storage[path] }
    }

    func read(_ path: String) async throws -> CloudNode? {
        lock.withLock { storage[path] }
    }

    func children(of parent: String) async throws -> [CloudNode] {
        lock.withLock { storage.values.filter { $0.parent == parent } }
    }

    /// The range query, over-fetch and all, then the shared narrowing.
    func subtree(of folder: String) async throws -> [CloudNode] {
        lock.withLock {
            if folder.isEmpty { return Array(storage.values) }
            let overFetched = storage.values.filter { $0.path.hasPrefix(folder) }
            return CloudPath.descendants(of: folder, in: Array(overFetched), path: \.path)
        }
    }

    func commit(_ writes: [CloudWrite]) async throws {
        let (children, single, snapshot) = lock.withLock {
            commits.append(writes)
            for write in writes {
                if let node = write.node {
                    storage[node.path] = node
                } else {
                    storage.removeValue(forKey: write.path)
                }
            }
            return (childWatchers, nodeWatchers, storage)
        }

        for watcher in children {
            watcher.deliver(snapshot.values.filter { $0.parent == watcher.parent })
        }
        for watcher in single {
            watcher.deliver(snapshot[watcher.path])
        }
    }

    /// Delivers the current contents the moment a listener attaches, which is
    /// what the real `onSnapshot` does and is where the interesting hazards
    /// live — a double that skipped the attach snapshot would hide them.
    func watchChildren(of parent: String, onChange: @escaping @Sendable ([CloudNode]) -> Void) -> CloudSubscription {
        let id = UUID()
        let current = lock.withLock { () -> [CloudNode] in
            childWatchers.append((parent, id, onChange))
            return storage.values.filter { $0.parent == parent }
        }
        onChange(current)
        return CloudSubscription { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.childWatchers.removeAll { $0.id == id } }
        }
    }

    func watchNode(at path: String, onChange: @escaping @Sendable (CloudNode?) -> Void) -> CloudSubscription {
        let id = UUID()
        let current = lock.withLock { () -> CloudNode? in
            nodeWatchers.append((path, id, onChange))
            return storage[path]
        }
        onChange(current)
        return CloudSubscription { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.nodeWatchers.removeAll { $0.id == id } }
        }
    }

    var watcherCount: Int {
        lock.withLock { childWatchers.count + nodeWatchers.count }
    }
}

/// An in-memory Cloud Storage.
final class InMemoryAssetStore: CloudAssetStore, @unchecked Sendable {
    private var objects: [String: Data] = [:]
    private var types: [String: String?] = [:]
    private let lock = NSLock()
    private(set) var removed: [String] = []
    var failNextUpload: CloudError?

    func upload(_ data: Data, to storagePath: String, contentType: String?) async throws -> String {
        if let failure = failNextUpload {
            failNextUpload = nil
            throw failure
        }
        return lock.withLock {
            objects[storagePath] = data
            // Recorded because the Storage rules accept only `image/*`: an
            // upload that loses its type is refused by the server, not here.
            types[storagePath] = contentType
            return "https://storage.test/\(storagePath)"
        }
    }

    func copy(from: String, to: String) async throws -> String {
        return lock.withLock {
            objects[to] = objects[from] ?? Data()
            return "https://storage.test/\(to)"
        }
    }

    func removeAll(_ storagePaths: [String]) async throws {
        lock.withLock {
            for path in storagePaths {
                objects.removeValue(forKey: path)
                removed.append(path)
            }
        }
    }

    var storedPaths: [String] {
        lock.withLock { objects.keys.sorted() }
    }

    func contentType(at storagePath: String) -> String? {
        lock.withLock { types[storagePath] ?? nil }
    }

    var storedTypes: [String] {
        lock.withLock { types.values.compactMap { $0 }.sorted() }
    }
}

func makeWorkspace(_ nodes: [CloudNode] = []) -> (CloudWorkspace, InMemoryNodeStore, InMemoryAssetStore) {
    let store = InMemoryNodeStore(nodes)
    let assets = InMemoryAssetStore()
    return (CloudWorkspace(nodes: store, assets: assets), store, assets)
}

func document(_ path: String, text: String = "") -> CloudNode {
    CloudNode(kind: .file, path: path, text: text, size: text.utf8.count)
}

func folder(_ path: String) -> CloudNode {
    CloudNode(kind: .folder, path: path)
}
