import Foundation

/// What a node in the cloud workspace is.
///
/// Firestore has no folders, so the tree is a reading of a `path` field on a
/// flat collection. A folder is a real stored node rather than an inference
/// from the paths beneath it, because an empty folder has to be able to exist.
public enum CloudNodeKind: String, Sendable, CaseIterable {
    case folder
    case file
    case asset
}

/// One node: a folder, a document, or an image.
///
/// The field names are not an implementation detail. The web build writes into
/// the same collection, and `Web/firebase/firestore.rules` validates specific
/// keys, so these spellings are interop and are asserted by test.
public struct CloudNode: Sendable, Equatable {
    public var kind: CloudNodeKind
    public var path: String
    public var parent: String
    public var name: String
    public var modified: Date

    // Documents
    public var text: String?
    public var hasByteOrderMark: Bool?
    public var size: Int?

    // Images
    public var storagePath: String?
    public var url: String?
    public var contentType: String?

    public init(
        kind: CloudNodeKind,
        path: String,
        modified: Date = Date(),
        text: String? = nil,
        hasByteOrderMark: Bool? = nil,
        size: Int? = nil,
        storagePath: String? = nil,
        url: String? = nil,
        contentType: String? = nil
    ) {
        self.kind = kind
        self.path = CloudPath.normalized(path)
        self.parent = CloudPath.parent(of: path)
        self.name = CloudPath.name(of: path)
        self.modified = modified
        self.text = text
        self.hasByteOrderMark = hasByteOrderMark
        self.size = size
        self.storagePath = storagePath
        self.url = url
        self.contentType = contentType
    }

    public var isDirectory: Bool { kind == .folder }
    public var isMarkdown: Bool { kind == .file && CloudPath.isMarkdown(name) }
}

// MARK: - Firestore representation

/// The dictionary form, kept here rather than in the Firebase adapter on
/// purpose: this mapping is the interop surface with the web build, it is the
/// thing most likely to break silently, and here it can be tested without a
/// network or an SDK.
extension CloudNode {
    public enum Field {
        public static let type = "type"
        public static let path = "path"
        public static let parent = "parent"
        public static let name = "name"
        public static let modified = "modified"
        public static let text = "text"
        public static let hasByteOrderMark = "hasByteOrderMark"
        public static let size = "size"
        public static let storagePath = "storagePath"
        public static let url = "url"
        public static let contentType = "contentType"
    }

    /// Milliseconds since the epoch, because that is what `Date.now()` writes
    /// on the web side and both builds read each other's nodes.
    public var fields: [String: Any] {
        var fields: [String: Any] = [
            Field.type: kind.rawValue,
            Field.path: path,
            Field.parent: parent,
            Field.name: name,
            Field.modified: Int(modified.timeIntervalSince1970 * 1000),
        ]
        if let text { fields[Field.text] = text }
        if let hasByteOrderMark { fields[Field.hasByteOrderMark] = hasByteOrderMark }
        if let size { fields[Field.size] = size }
        if let storagePath { fields[Field.storagePath] = storagePath }
        if let url { fields[Field.url] = url }
        if let contentType { fields[Field.contentType] = contentType }
        return fields
    }

    public init?(fields: [String: Any]) {
        guard
            let rawType = fields[Field.type] as? String,
            let kind = CloudNodeKind(rawValue: rawType),
            let path = fields[Field.path] as? String,
            !path.isEmpty
        else { return nil }

        // `modified` arrives as a number from either build, but JavaScript
        // numbers are doubles and Firestore may hand back either, so both are
        // accepted rather than trusting one spelling.
        let milliseconds = (fields[Field.modified] as? Double)
            ?? (fields[Field.modified] as? Int).map(Double.init)
            ?? 0

        self.init(
            kind: kind,
            path: path,
            modified: Date(timeIntervalSince1970: milliseconds / 1000),
            text: fields[Field.text] as? String,
            hasByteOrderMark: fields[Field.hasByteOrderMark] as? Bool,
            size: fields[Field.size] as? Int,
            storagePath: fields[Field.storagePath] as? String,
            url: fields[Field.url] as? String,
            contentType: fields[Field.contentType] as? String
        )
    }
}

/// One row in a listing, which is all the UI needs to draw a tree.
public struct CloudEntry: Sendable, Equatable, Identifiable {
    public var name: String
    public var path: String
    public var parent: String
    public var isDirectory: Bool
    public var isMarkdown: Bool
    public var modified: Date

    public var id: String { path }

    public init(node: CloudNode) {
        self.name = node.name
        self.path = node.path
        self.parent = node.parent
        self.isDirectory = node.isDirectory
        self.isMarkdown = node.isMarkdown
        self.modified = node.modified
    }
}

/// A document read out of the workspace.
public struct CloudDocument: Sendable, Equatable {
    public var path: String
    public var text: String
    public var hasByteOrderMark: Bool
    public var modified: Date
    /// Download URLs for the images this document refers to, by workspace path.
    /// Filled in on read, because the renderer resolves image sources while it
    /// builds its output and cannot wait for a fetch.
    public var imageURLs: [String: String]

    public init(
        path: String,
        text: String,
        hasByteOrderMark: Bool = false,
        modified: Date = Date(),
        imageURLs: [String: String] = [:]
    ) {
        self.path = path
        self.text = text
        self.hasByteOrderMark = hasByteOrderMark
        self.modified = modified
        self.imageURLs = imageURLs
    }
}
