import Foundation

/// Path arithmetic for the cloud workspace.
///
/// A document in Firestore has no directory to live in. Its place in the tree
/// is a string field, so listing a folder, renaming a subtree, and deciding
/// what counts as a name collision all become string work — and it has to reach
/// the *same* answers the other builds reach, or one account would disagree
/// with itself about where a document is depending on which app opened it.
///
/// This is a port of `Web/public/app/cloud/paths.js`, deliberately kept
/// function-for-function so the two can be read side by side. Everything here
/// is pure, which is most of why it lives apart from the store that calls it.
public enum CloudPath {
    public static let markdownExtensions = ["md", "markdown"]

    /// A workspace-relative path with no leading, trailing, or doubled separators.
    ///
    /// Refuses `..` rather than resolving it. There is no directory to escape
    /// from in Firestore, but a stored path containing `..` would still let two
    /// different strings name one document, and every uniqueness guarantee here
    /// rests on the path being the identity.
    public static func normalize(_ path: String) throws -> String {
        let parts = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }

        if parts.contains("..") {
            throw CloudError.invalidPath(path)
        }
        return parts.joined(separator: "/")
    }

    /// `normalize` for callers working from a path the store already accepted,
    /// where a failure would mean the stored data is corrupt rather than that
    /// the caller made a mistake.
    static func normalized(_ path: String) -> String {
        (try? normalize(path)) ?? ""
    }

    public static func name(of path: String) -> String {
        let normalized = normalized(path)
        guard let cut = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: cut)...])
    }

    public static func parent(of path: String) -> String {
        let normalized = normalized(path)
        guard let cut = normalized.lastIndex(of: "/") else { return "" }
        return String(normalized[..<cut])
    }

    public static func join(_ parent: String, _ name: String) -> String {
        let left = normalized(parent)
        let right = normalized(name)
        if right.isEmpty { return left }
        return left.isEmpty ? right : "\(left)/\(right)"
    }

    /// The part before the final dot, matching PHP's `PATHINFO_FILENAME`.
    ///
    /// PHP splits on the last dot wherever it is, so the stem of `.gitignore`
    /// is empty and its extension is `gitignore`. That looks wrong and is kept
    /// anyway: `assetsFolderName` depends on it, and every build already
    /// refuses the bare `.assets` folder that falls out of it.
    public static func stem(of path: String) -> String {
        let base = name(of: path)
        guard let cut = base.lastIndex(of: ".") else { return base }
        return String(base[..<cut])
    }

    /// The part after the final dot, lowercased. Empty when there is no dot.
    public static func fileExtension(of path: String) -> String {
        let base = name(of: path)
        guard let cut = base.lastIndex(of: ".") else { return "" }
        return String(base[base.index(after: cut)...]).lowercased()
    }

    public static func isMarkdown(_ path: String) -> Bool {
        markdownExtensions.contains(fileExtension(of: path))
    }

    /// `<document-stem>.assets`, the convention every build writes.
    public static func assetsFolderName(for documentPath: String) -> String {
        "\(stem(of: documentPath)).assets"
    }

    /// Whether `path` is inside `folder`.
    ///
    /// The `/` matters: without it `Notes` would claim `Notes archive.md`, and
    /// deleting a folder would take a similarly named sibling with it.
    public static func isDescendant(_ path: String, of folder: String) -> Bool {
        let child = normalized(path)
        let parent = normalized(folder)
        if parent.isEmpty { return !child.isEmpty }
        return child.hasPrefix("\(parent)/")
    }

    /// Narrows the rows a prefix range query returns down to the ones actually
    /// inside `folder`, plus `folder` itself.
    ///
    /// This exists because Firestore cannot express "inside this folder". The
    /// closest it offers is a range over the `path` field, and a range that
    /// starts at `Notes` also returns `Notes 2/Out.md` and `Notes.md` — the
    /// string sorts between `Notes` and the end of the range whatever
    /// terminator is used. So the query over-fetches by design and the caller
    /// has to discard the extras. Forgetting to is how a folder rename quietly
    /// renames its neighbours, and how a folder delete quietly deletes them.
    ///
    /// It lives here rather than in the Firestore store so that the one piece
    /// of that store with a decision in it is under test. `CloudNodeStore`
    /// promises filtered results, so every implementation calls this — the real
    /// one and the in-memory double alike.
    public static func descendants<Row>(
        of folder: String,
        in rows: [Row],
        path pathOf: (Row) -> String
    ) -> [Row] {
        let parent = normalized(folder)
        if parent.isEmpty { return rows }
        return rows.filter { row in
            let path = normalized(pathOf(row))
            return path == parent || isDescendant(path, of: parent)
        }
    }

    /// Repoints `path` from under `from` to under `to`, including `path == from`.
    public static func rewrite(_ path: String, from source: String, to destination: String) -> String {
        let target = normalized(path)
        let origin = normalized(source)
        if target == origin { return normalized(destination) }
        guard isDescendant(target, of: origin) else { return target }
        let tail = origin.isEmpty
            ? target
            : String(target.dropFirst(origin.count + 1))
        return join(destination, tail)
    }

    /// Explorer order: folders first, then natural case-insensitive order so
    /// "Folder 2" precedes "Folder 10".
    ///
    /// `localizedStandardCompare` is Foundation's spelling of what PHP's
    /// `strnatcasecmp` and JavaScript's numeric `Intl.Collator` do, which is
    /// what the other two builds sort with.
    public static func compare(_ left: CloudEntry, _ right: CloudEntry) -> Bool {
        if left.isDirectory != right.isDirectory { return left.isDirectory }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }

    /// The first free name of the form `stem-2.ext`, matching what the other
    /// builds do so a duplicate is named identically wherever it is made.
    public static func nextAvailableName(taken: Set<String>, for name: String) throws -> String {
        let base = Self.name(of: name)
        let stem = Self.stem(of: base)
        let suffix = String(base.dropFirst(stem.count)) // keeps the dot, and its case

        for index in 2..<10_000 {
            let candidate = "\(stem)-\(index)\(suffix)"
            if !taken.contains(candidate) { return candidate }
        }
        throw CloudError.tooManyCopies(base)
    }

    /// A Firestore document ID for a workspace path.
    ///
    /// The path is the identity of a node, so making it the ID means the
    /// database enforces uniqueness rather than a query the client has to
    /// remember to run, and every read by path is a single get. Firestore IDs
    /// cannot contain a slash, and percent-encoding both removes it and leaves
    /// the ID readable in the console — which matters, because eyeballing it is
    /// the only way to inspect this data.
    ///
    /// Matches JavaScript's `encodeURIComponent`, because the web build writes
    /// into the same collection and the two must agree exactly.
    public static func documentId(for path: String) throws -> String {
        let normalized = try normalize(path)
        guard !normalized.isEmpty else { throw CloudError.rootIsNotADocument }
        guard let encoded = normalized.addingPercentEncoding(
            withAllowedCharacters: encodeURIComponentUnreserved
        ) else {
            throw CloudError.invalidPath(path)
        }
        return encoded
    }

    public static func path(fromDocumentId id: String) -> String {
        id.removingPercentEncoding ?? id
    }

    /// Every ancestor folder of `path`, outermost first, so they can be created
    /// before a document that assumes they exist.
    public static func ancestorFolders(of path: String) -> [String] {
        var parts = normalized(path).split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return [] }
        parts.removeLast()

        var folders: [String] = []
        var accumulated = ""
        for part in parts {
            accumulated = accumulated.isEmpty ? part : "\(accumulated)/\(part)"
            folders.append(accumulated)
        }
        return folders
    }

    /// Exactly the characters `encodeURIComponent` leaves alone:
    /// `A-Z a-z 0-9 - _ . ! ~ * ' ( )`.
    ///
    /// Built by hand because Foundation has no set that matches. The nearest,
    /// `urlPathAllowed`, permits `/`, which would produce an ID Firestore
    /// rejects outright. `alphanumerics` is intersected with ASCII because it
    /// otherwise includes every Unicode letter and digit, which
    /// `encodeURIComponent` percent-encodes.
    static let encodeURIComponentUnreserved: CharacterSet = {
        let ascii = CharacterSet(charactersIn: UnicodeScalar(0)...UnicodeScalar(127))
        var allowed = CharacterSet.alphanumerics.intersection(ascii)
        allowed.insert(charactersIn: "-_.!~*'()")
        return allowed
    }()
}
