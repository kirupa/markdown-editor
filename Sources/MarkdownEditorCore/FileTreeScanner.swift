import Foundation

public struct FileTreeEntry: Hashable, Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isPackage: Bool

    public var id: URL {
        url
    }

    public var isExpandable: Bool {
        isDirectory && !isSymbolicLink && !isPackage
    }

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        isPackage: Bool
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isPackage = isPackage
    }
}

public enum FileTreeScannerError: Error, LocalizedError {
    case rootIsNotDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .rootIsNotDirectory(let url):
            "The explorer location is not a folder: \(url.lastPathComponent)"
        }
    }
}

public struct FileTreeScanner {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func contents(of directoryURL: URL) throws -> [FileTreeEntry] {
        let rootValues = try directoryURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true,
            rootValues.isSymbolicLink != true
        else {
            throw FileTreeScannerError.rootIsNotDirectory(directoryURL)
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .nameKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        let entries = try urls.map { url in
            let values = try url.resourceValues(forKeys: keys)
            return FileTreeEntry(
                url: url.standardizedFileURL,
                name: values.name ?? url.lastPathComponent,
                isDirectory: values.isDirectory == true,
                isSymbolicLink: values.isSymbolicLink == true,
                isPackage: values.isPackage == true
            )
        }

        return entries.sorted { left, right in
            if left.isExpandable != right.isExpandable {
                return left.isExpandable
            }
            return left.name.localizedStandardCompare(right.name)
                == .orderedAscending
        }
    }

    public static func isMarkdownDocument(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    public static func ancestorDirectories(startingAt url: URL) -> [URL] {
        var ancestors: [URL] = []
        var currentURL = url.standardizedFileURL

        while true {
            ancestors.append(currentURL)
            let parentURL = currentURL.deletingLastPathComponent()
                .standardizedFileURL
            guard parentURL.path != currentURL.path else {
                return Array(ancestors.reversed())
            }
            currentURL = parentURL
        }
    }
}
