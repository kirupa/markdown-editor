import Foundation

public struct RecentDocument: Hashable, Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let folderDisplayPath: String
    public let modificationDate: Date?

    public var id: URL {
        url
    }

    public init(
        url: URL,
        name: String,
        folderDisplayPath: String,
        modificationDate: Date?
    ) {
        self.url = url
        self.name = name
        self.folderDisplayPath = folderDisplayPath
        self.modificationDate = modificationDate
    }
}

/// Pure list arithmetic behind the welcome window's recent documents.
///
/// The catalog never touches AppKit so that its ordering, filtering, and
/// path-shortening rules can be tested directly.
public enum RecentDocumentsCatalog {
    /// How many paths are persisted between launches.
    public static let storedLimit = 40

    /// How many entries the welcome window shows.
    public static let displayLimit = 12

    /// Concatenates two most-recent-first lists, keeps the first occurrence of
    /// each standardized path, drops anything that is not a Markdown file, and
    /// caps the result.
    public static func merged(
        preferred: [URL],
        additional: [URL] = [],
        limit: Int = storedLimit
    ) -> [URL] {
        guard limit > 0 else {
            return []
        }

        var seenPaths: Set<String> = []
        var merged: [URL] = []

        for url in preferred + additional {
            let standardizedURL = url.standardizedFileURL
            guard FileTreeScanner.isMarkdownDocument(standardizedURL),
                seenPaths.insert(standardizedURL.path).inserted
            else {
                continue
            }

            merged.append(standardizedURL)
            if merged.count == limit {
                break
            }
        }

        return merged
    }

    /// Moves `url` to the front of `urls`, removing any earlier occurrence.
    public static func promoting(
        _ url: URL,
        in urls: [URL],
        limit: Int = storedLimit
    ) -> [URL] {
        merged(preferred: [url], additional: urls, limit: limit)
    }

    /// Removes every occurrence of `url`, comparing standardized paths.
    public static func removing(_ url: URL, from urls: [URL]) -> [URL] {
        let removedPath = url.standardizedFileURL.path
        return urls.filter { $0.standardizedFileURL.path != removedPath }
    }

    /// Resolves display metadata, skipping paths that no longer resolve to a
    /// readable file so the welcome window never offers a dead row.
    public static func entries(
        for urls: [URL],
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        limit: Int = displayLimit
    ) -> [RecentDocument] {
        var entries: [RecentDocument] = []

        for url in urls where entries.count < limit {
            let standardizedURL = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: standardizedURL.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue
            else {
                continue
            }

            let resourceValues = try? standardizedURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            )
            entries.append(
                RecentDocument(
                    url: standardizedURL,
                    name: standardizedURL.lastPathComponent,
                    folderDisplayPath: displayPath(
                        for: standardizedURL.deletingLastPathComponent(),
                        homeDirectoryPath: homeDirectoryPath
                    ),
                    modificationDate: resourceValues?.contentModificationDate
                )
            )
        }

        return entries
    }

    /// Keeps only the paths that still resolve to a file on disk.
    public static func existing(
        _ urls: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        urls.filter { url in
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(
                atPath: url.standardizedFileURL.path,
                isDirectory: &isDirectory
            )
            return exists && !isDirectory.boolValue
        }
    }

    /// Abbreviates the user's home directory to `~` the way Finder does.
    public static func displayPath(
        for directoryURL: URL,
        homeDirectoryPath: String = NSHomeDirectory()
    ) -> String {
        let path = directoryURL.standardizedFileURL.path
        let homePath = URL(fileURLWithPath: homeDirectoryPath)
            .standardizedFileURL
            .path

        guard !homePath.isEmpty, homePath != "/" else {
            return path
        }

        if path == homePath {
            return "~"
        }

        let homePrefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard path.hasPrefix(homePrefix) else {
            return path
        }

        return "~/" + path.dropFirst(homePrefix.count)
    }
}
