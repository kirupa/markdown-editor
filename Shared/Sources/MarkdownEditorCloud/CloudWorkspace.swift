import Foundation

/// The cloud workspace: everything a filesystem would have done for free.
///
/// Firestore gives back documents matching a query and nothing else. Listing a
/// folder, refusing to overwrite, renaming a subtree, keeping a document's
/// images with it — all of that is written out here, on top of `CloudPath`.
///
/// It talks only to `CloudNodeStore` and `CloudAssetStore`, so every decision in
/// this file runs under test against in-memory doubles. That split is the same
/// one `Web/public/app/backends/firestore.js` makes, and for the same reason:
/// the part with the decisions in it is the part worth testing, and the part
/// that cannot be tested without a network is small enough to read.
public struct CloudWorkspace: Sendable {
    /// Firestore caps a document at 1 MiB. Refusing earlier turns a confusing
    /// write failure into a clear one, and matches the ceiling in
    /// `Web/firebase/firestore.rules` so the client and the rules agree.
    public static let maximumDocumentBytes = 900_000

    /// Storage imposes no useful limit of its own, so this is the one that
    /// counts. Also enforced in `Web/firebase/storage.rules`, where a client
    /// cannot talk its way around it.
    public static let maximumImageBytes = 10 * 1024 * 1024

    /// The formats every build accepts, so the same file can be inserted
    /// wherever the document is opened.
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "svg",
    ]

    public let nodes: CloudNodeStore
    public let assets: CloudAssetStore
    public let workspaceName: String

    public init(nodes: CloudNodeStore, assets: CloudAssetStore, workspaceName: String = "kirupaMarkdown") {
        self.nodes = nodes
        self.assets = assets
        self.workspaceName = workspaceName
    }

    // MARK: - Reading

    /// One level of the tree, folders first then natural order — the same
    /// ordering the other builds use.
    public func list(_ folder: String = "") async throws -> [CloudEntry] {
        let parent = try CloudPath.normalize(folder)
        let children = try await nodes.children(of: parent)
        return children
            .filter { $0.kind != .asset }
            .map(CloudEntry.init(node:))
            .sorted(by: CloudPath.compare)
    }

    /// Every Markdown document in the account, newest first. The native apps
    /// have no folder explorer yet, so this is what they open documents from.
    public func allDocuments() async throws -> [CloudEntry] {
        try await nodes.subtree(of: "")
            .filter { $0.kind == .file && $0.isMarkdown }
            .map(CloudEntry.init(node:))
            .sorted { $0.modified > $1.modified }
    }

    public func readDocument(at path: String) async throws -> CloudDocument {
        let node = try await requireNode(path)
        guard node.kind == .file else { throw CloudError.notADocument(path) }

        return CloudDocument(
            path: node.path,
            text: node.text ?? "",
            hasByteOrderMark: node.hasByteOrderMark ?? false,
            modified: node.modified,
            imageURLs: try await imageURLs(forDocumentAt: node.path)
        )
    }

    /// The download URLs for a document's own images, keyed by workspace path.
    ///
    /// Read up front rather than on demand because rendering resolves image
    /// sources as it goes and cannot await a fetch part-way through.
    public func imageURLs(forDocumentAt path: String) async throws -> [String: String] {
        let folder = assetsFolder(for: path)
        guard let folder else { return [:] }

        var urls: [String: String] = [:]
        for node in try await nodes.subtree(of: folder) where node.kind == .asset {
            if let url = node.url { urls[node.path] = url }
        }
        return urls
    }

    // MARK: - Writing

    @discardableResult
    public func saveDocument(_ text: String, to path: String, hasByteOrderMark: Bool = false) async throws -> CloudNode {
        let target = try CloudPath.normalize(path)
        guard !target.isEmpty else { throw CloudError.rootIsNotADocument }

        let bytes = text.utf8.count
        guard bytes < Self.maximumDocumentBytes else {
            throw CloudError.documentTooLarge(bytes: bytes, limit: Self.maximumDocumentBytes)
        }

        let node = CloudNode(
            kind: .file,
            path: target,
            text: text,
            hasByteOrderMark: hasByteOrderMark,
            size: bytes
        )

        try await nodes.commit(missingAncestors(of: target, alreadyKnown: []) + [.put(node)])
        return node
    }

    /// Creates a document, refusing to overwrite one that is already there.
    ///
    /// A name with no Markdown extension gets `.md`, and a name already taken
    /// gets a numbered suffix, both exactly as `newDocument` does in
    /// `Web/public/app/backends/firestore.js`. Typing a name that already
    /// exists is the ordinary case, not an error worth interrupting anyone for.
    @discardableResult
    public func createDocument(named name: String, in parent: String = "", text: String = "") async throws -> String {
        let path = try await uniquePath(named: name, in: parent, addingMarkdownExtension: true)
        try await saveDocument(text, to: path)
        return path
    }

    @discardableResult
    public func createFolder(named name: String, in parent: String = "") async throws -> String {
        let path = try await uniquePath(named: name, in: parent, addingMarkdownExtension: false)
        let folder = CloudNode(kind: .folder, path: path)
        try await nodes.commit(missingAncestors(of: path, alreadyKnown: []) + [.put(folder)])
        return path
    }

    /// Renames in place. A document takes its `<stem>.assets` folder with it and
    /// its own image references are rewritten to match, which is what keeps the
    /// images from going missing the moment a document is renamed.
    @discardableResult
    public func rename(_ path: String, to newName: String) async throws -> String {
        let source = try CloudPath.normalize(path)
        guard !source.isEmpty else { throw CloudError.cannotModifyRoot }
        let name = try CloudPath.normalize(newName)
        guard !name.isEmpty, !name.contains("/") else { throw CloudError.invalidPath(newName) }

        return try await move(source, to: CloudPath.parent(of: source), named: name)
    }

    /// Moves into another folder, keeping the name.
    @discardableResult
    public func move(_ path: String, into folder: String) async throws -> String {
        let source = try CloudPath.normalize(path)
        guard !source.isEmpty else { throw CloudError.cannotModifyRoot }
        return try await move(source, to: try CloudPath.normalize(folder), named: CloudPath.name(of: source))
    }

    private func move(_ source: String, to parent: String, named name: String) async throws -> String {
        let destination = CloudPath.join(parent, name)
        if destination == source { return source }

        let node = try await requireNode(source)

        // A folder moved inside itself would detach the whole subtree, and the
        // range query would happily return the nodes it is about to rewrite.
        if node.kind == .folder, CloudPath.isDescendant(destination, of: source) {
            throw CloudError.cannotMoveIntoItself(source)
        }
        if try await nodes.read(destination) != nil {
            throw CloudError.alreadyExists(name)
        }

        var writes: [CloudWrite] = []
        var moved = node
        moved.path = destination
        moved.parent = CloudPath.parent(of: destination)
        moved.name = CloudPath.name(of: destination)
        moved.modified = Date()

        // A document's images move with it, and the references inside the
        // document are rewritten so they still resolve.
        if node.kind == .file,
           let oldFolder = assetsFolder(for: source),
           let newFolder = assetsFolder(for: destination),
           oldFolder != newFolder {
            let assetNodes = try await nodes.subtree(of: oldFolder)
            for assetNode in assetNodes {
                var relocated = assetNode
                relocated.path = CloudPath.rewrite(assetNode.path, from: oldFolder, to: newFolder)
                relocated.parent = CloudPath.parent(of: relocated.path)
                relocated.name = CloudPath.name(of: relocated.path)
                writes.append(.put(relocated))
                writes.append(.remove(assetNode.path))
            }
            if let text = moved.text {
                moved.text = Self.rewriteImageReferences(
                    in: text,
                    from: CloudPath.name(of: oldFolder),
                    to: CloudPath.name(of: newFolder)
                )
            }
        }

        // Descendants of a folder are repointed one by one; Firestore has no
        // server-side rename, so the subtree really is rewritten.
        if node.kind == .folder {
            for descendant in try await nodes.subtree(of: source) where descendant.path != source {
                var relocated = descendant
                relocated.path = CloudPath.rewrite(descendant.path, from: source, to: destination)
                relocated.parent = CloudPath.parent(of: relocated.path)
                relocated.name = CloudPath.name(of: relocated.path)
                writes.append(.put(relocated))
                writes.append(.remove(descendant.path))
            }
        }

        // Every create is ordered before the delete it replaces, so an
        // interruption part-way leaves nodes duplicated rather than lost.
        writes.insert(.put(moved), at: 0)
        writes.append(.remove(source))
        try await nodes.commit(missingAncestors(of: destination, alreadyKnown: []) + writes)
        return destination
    }

    /// Deletes a node and everything under it.
    ///
    /// A document's assets folder is deliberately left behind, as every other
    /// build does: it holds originals that may exist nowhere else.
    public func delete(_ path: String) async throws {
        let target = try CloudPath.normalize(path)
        guard !target.isEmpty else { throw CloudError.cannotModifyRoot }
        let node = try await requireNode(target)

        var writes: [CloudWrite] = [.remove(target)]
        var orphanedObjects: [String] = []

        if node.kind == .folder {
            for descendant in try await nodes.subtree(of: target) where descendant.path != target {
                writes.append(.remove(descendant.path))
                if descendant.kind == .asset, let storagePath = descendant.storagePath {
                    orphanedObjects.append(storagePath)
                }
            }
        }

        try await nodes.commit(writes)

        // After the nodes are gone, so a Storage failure cannot report a
        // delete that actually succeeded as a failure.
        if !orphanedObjects.isEmpty {
            try? await assets.removeAll(orphanedObjects)
        }
    }

    // MARK: - Images

    /// Copies an image into the document's `<stem>.assets` folder and returns
    /// the Markdown reference to insert at the cursor.
    ///
    /// The reference is relative and percent-encoded, exactly as the local
    /// builds write it, so a document carries the same text whichever build
    /// inserted the image.
    public func importImage(
        _ data: Data,
        named filename: String,
        intoDocumentAt documentPath: String,
        contentType: String? = nil
    ) async throws -> CloudImageImport {
        let name = CloudPath.name(of: filename)
        let extensionName = CloudPath.fileExtension(of: name)
        guard Self.imageExtensions.contains(extensionName) else {
            throw CloudError.unsupportedImageType(name)
        }
        guard data.count < Self.maximumImageBytes else {
            throw CloudError.imageTooLarge(bytes: data.count, limit: Self.maximumImageBytes)
        }
        guard let folder = assetsFolder(for: documentPath) else {
            throw CloudError.reservedAssetsFolder
        }

        let taken = Set(try await nodes.children(of: folder).map(\.name))
        let finalName = taken.contains(name)
            ? try CloudPath.nextAvailableName(taken: taken, for: name)
            : name
        let path = CloudPath.join(folder, finalName)

        // The timestamp keeps a re-uploaded image from being served from the
        // CDN's copy of the previous one at the same object path.
        let storagePath = "\(path)#\(Int(Date().timeIntervalSince1970 * 1000))"
        let url = try await assets.upload(data, to: storagePath, contentType: contentType)

        let asset = CloudNode(
            kind: .asset,
            path: path,
            size: data.count,
            storagePath: storagePath,
            url: url,
            contentType: contentType
        )
        var writes = missingAncestors(of: path, alreadyKnown: [])
        writes.append(.put(asset))
        try await nodes.commit(writes)

        return CloudImageImport(
            path: path,
            url: url,
            relativePath: Self.relativeReference(folder: CloudPath.name(of: folder), name: finalName),
            markdown: Self.markdownImageReference(
                altText: CloudPath.stem(of: finalName),
                relativePath: Self.relativeReference(folder: CloudPath.name(of: folder), name: finalName)
            )
        )
    }

    // MARK: - Watching

    /// Live updates for one document. The listener is detached when the
    /// returned subscription is released.
    public func watchDocument(at path: String, onChange: @escaping @Sendable (CloudNode?) -> Void) -> CloudSubscription {
        nodes.watchNode(at: CloudPath.normalized(path), onChange: onChange)
    }

    public func watchFolder(_ folder: String = "", onChange: @escaping @Sendable ([CloudEntry]) -> Void) -> CloudSubscription {
        nodes.watchChildren(of: CloudPath.normalized(folder)) { children in
            onChange(
                children
                    .filter { $0.kind != .asset }
                    .map(CloudEntry.init(node:))
                    .sorted(by: CloudPath.compare)
            )
        }
    }

    // MARK: - Helpers

    private func requireNode(_ path: String) async throws -> CloudNode {
        let normalized = try CloudPath.normalize(path)
        guard let node = try await nodes.read(normalized) else {
            throw CloudError.notFound(normalized)
        }
        return node
    }

    private func uniquePath(
        named name: String,
        in parent: String,
        addingMarkdownExtension: Bool
    ) async throws -> String {
        let folder = try CloudPath.normalize(parent)
        var cleanName = try CloudPath.normalize(name)
        guard !cleanName.isEmpty, !cleanName.contains("/") else { throw CloudError.invalidPath(name) }
        if addingMarkdownExtension, !CloudPath.isMarkdown(cleanName) {
            cleanName += ".md"
        }

        // Only this level: a name is a collision if a sibling has it, and two
        // documents in different folders may share one.
        let taken = Set(try await nodes.children(of: folder).map(\.name))
        let chosen = taken.contains(cleanName)
            ? try CloudPath.nextAvailableName(taken: taken, for: cleanName)
            : cleanName
        return CloudPath.join(folder, chosen)
    }

    /// A document whose stem is empty — `.gitignore` — would produce a bare
    /// `.assets` folder, which every build reserves. Returning nil rather than
    /// that folder is what refuses the operation.
    private func assetsFolder(for documentPath: String) -> String? {
        let folderName = CloudPath.assetsFolderName(for: documentPath)
        guard folderName != ".assets" else { return nil }
        return CloudPath.join(CloudPath.parent(of: documentPath), folderName)
    }

    /// Folders are real nodes, so a document written into a folder that has
    /// never been created needs those folders brought into existence first.
    private func missingAncestors(of path: String, alreadyKnown: Set<String>) -> [CloudWrite] {
        CloudPath.ancestorFolders(of: path)
            .filter { !alreadyKnown.contains($0) }
            .map { .put(CloudNode(kind: .folder, path: $0)) }
    }

    /// Swaps `old.assets/` for `new.assets/` in a document's own text.
    static func rewriteImageReferences(in text: String, from oldFolder: String, to newFolder: String) -> String {
        guard oldFolder != newFolder else { return text }
        let encodedOld = encodeComponent(oldFolder)
        let encodedNew = encodeComponent(newFolder)
        return text
            .replacingOccurrences(of: "\(encodedOld)/", with: "\(encodedNew)/")
            .replacingOccurrences(of: "\(oldFolder)/", with: "\(newFolder)/")
    }

    static func relativeReference(folder: String, name: String) -> String {
        "\(encodeComponent(folder))/\(encodeComponent(name))"
    }

    /// Percent-encodes one path component the way every other build does, so
    /// the reference text is identical wherever the image was inserted.
    static func encodeComponent(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreservedPathCharacters) ?? component
    }

    /// `A-Z a-z 0-9 - . _ ~`, the RFC 3986 unreserved set, matching
    /// `MarkdownImageImporter` and PHP's `ImageImporter::encodeComponent`.
    static let unreservedPathCharacters: CharacterSet = {
        let ascii = CharacterSet(charactersIn: UnicodeScalar(0)...UnicodeScalar(127))
        var allowed = CharacterSet.alphanumerics.intersection(ascii)
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    /// `![alt](path)` with the alt text escaped so a filename cannot break out
    /// of the reference.
    public static func markdownImageReference(altText: String, relativePath: String) -> String {
        let escaped = altText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "![\(escaped)](\(relativePath))"
    }
}

/// What an image import produced: where it went, how to reach it, and the text
/// to insert.
public struct CloudImageImport: Sendable, Equatable {
    public var path: String
    public var url: String
    public var relativePath: String
    public var markdown: String
}
