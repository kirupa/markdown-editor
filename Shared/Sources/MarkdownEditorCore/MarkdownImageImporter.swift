import Foundation

public struct ImportedMarkdownImage: Equatable {
    public let destinationURL: URL
    public let relativePath: String
    public let markdownReference: String

    public init(
        destinationURL: URL,
        relativePath: String,
        markdownReference: String
    ) {
        self.destinationURL = destinationURL
        self.relativePath = relativePath
        self.markdownReference = markdownReference
    }
}

public enum MarkdownImageImportError: Error, LocalizedError {
    case documentHasNoFileLocation
    case invalidDocumentLocation(URL)
    case sourceDoesNotExist(URL)
    case sourceIsDirectory(URL)
    case unsupportedImageType(String)
    case unsafeAssetsDirectory(URL)
    case cannotEncodeRelativePath(String)

    public var errorDescription: String? {
        switch self {
        case .documentHasNoFileLocation:
            "Save the Markdown document before adding an image."
        case .invalidDocumentLocation:
            "Images can only be added to Markdown documents stored on this Mac."
        case .sourceDoesNotExist(let url):
            "The selected image does not exist: \(url.lastPathComponent)"
        case .sourceIsDirectory(let url):
            "The selected item is a folder, not an image: \(url.lastPathComponent)"
        case .unsupportedImageType(let filenameExtension):
            filenameExtension.isEmpty
                ? "The selected file has no supported image extension."
                : "The selected .\(filenameExtension) file is not a supported image."
        case .unsafeAssetsDirectory(let url):
            "The assets location is not a regular folder beside the document: \(url.lastPathComponent)"
        case .cannotEncodeRelativePath(let path):
            "The relative image path could not be encoded: \(path)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .documentHasNoFileLocation:
            "Choose File > Save, then add the image again."
        case .unsupportedImageType:
            "Choose a PNG, JPEG, GIF, WebP, TIFF, BMP, HEIC, HEIF, or SVG file."
        case .unsafeAssetsDirectory:
            "Remove or rename the existing assets link, then try again."
        default:
            nil
        }
    }
}

public struct MarkdownImageImporter {
    public static let supportedFilenameExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tif",
        "tiff", "webp"
    ]

    private static let pathComponentCharacters: CharacterSet = {
        var characters = CharacterSet.alphanumerics
        characters.insert(charactersIn: "-._~")
        return characters
    }()

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func importImage(
        at sourceURL: URL,
        forDocumentAt documentURL: URL?
    ) throws -> ImportedMarkdownImage {
        guard let documentURL else {
            throw MarkdownImageImportError.documentHasNoFileLocation
        }

        guard documentURL.isFileURL else {
            throw MarkdownImageImportError.invalidDocumentLocation(documentURL)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: sourceURL.path,
            isDirectory: &isDirectory
        ) else {
            throw MarkdownImageImportError.sourceDoesNotExist(sourceURL)
        }

        guard !isDirectory.boolValue else {
            throw MarkdownImageImportError.sourceIsDirectory(sourceURL)
        }

        let filenameExtension = sourceURL.pathExtension.lowercased()
        guard Self.supportedFilenameExtensions.contains(filenameExtension) else {
            throw MarkdownImageImportError.unsupportedImageType(filenameExtension)
        }

        let assetsDirectory = try assetsDirectoryURL(
            forDocumentAt: documentURL
        )
        try prepareAssetsDirectory(
            assetsDirectory,
            documentDirectory: documentURL.deletingLastPathComponent()
        )

        let destinationURL = nextAvailableDestination(
            for: sourceURL,
            in: assetsDirectory
        )
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let relativePath = try encodedRelativePath(
            assetsDirectoryName: assetsDirectory.lastPathComponent,
            filename: destinationURL.lastPathComponent
        )
        let altText = sourceURL.deletingPathExtension().lastPathComponent

        return ImportedMarkdownImage(
            destinationURL: destinationURL,
            relativePath: relativePath,
            markdownReference: Self.markdownImageReference(
                altText: altText,
                relativePath: relativePath
            )
        )
    }

    public func assetsDirectoryURL(
        forDocumentAt documentURL: URL
    ) throws -> URL {
        guard documentURL.isFileURL else {
            throw MarkdownImageImportError.invalidDocumentLocation(documentURL)
        }

        let documentStem = documentURL
            .deletingPathExtension()
            .lastPathComponent
        guard !documentStem.isEmpty else {
            throw MarkdownImageImportError.invalidDocumentLocation(documentURL)
        }

        return documentURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(documentStem).assets", isDirectory: true)
    }

    public static func markdownImageReference(
        altText: String,
        relativePath: String
    ) -> String {
        let escapedAltText = altText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "![\(escapedAltText)](\(relativePath))"
    }

    private func nextAvailableDestination(
        for sourceURL: URL,
        in directoryURL: URL
    ) -> URL {
        let filename = sourceURL.lastPathComponent
        var candidate = directoryURL.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let filenameExtension = sourceURL.pathExtension
        var suffix = 2

        while true {
            let candidateName = filenameExtension.isEmpty
                ? "\(stem)-\(suffix)"
                : "\(stem)-\(suffix).\(filenameExtension)"
            candidate = directoryURL.appendingPathComponent(candidateName)

            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }

            suffix += 1
        }
    }

    private func prepareAssetsDirectory(
        _ assetsDirectory: URL,
        documentDirectory: URL
    ) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: assetsDirectory.path,
            isDirectory: &isDirectory
        ) {
            let values = try assetsDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true
            else {
                throw MarkdownImageImportError.unsafeAssetsDirectory(
                    assetsDirectory
                )
            }
        } else {
            try fileManager.createDirectory(
                at: assetsDirectory,
                withIntermediateDirectories: true
            )
        }

        let resolvedDocumentDirectory = documentDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedAssetsDirectory = assetsDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let expectedAssetsDirectory = resolvedDocumentDirectory
            .appendingPathComponent(
                assetsDirectory.lastPathComponent,
                isDirectory: true
            )
            .standardizedFileURL

        guard resolvedAssetsDirectory.path == expectedAssetsDirectory.path else {
            throw MarkdownImageImportError.unsafeAssetsDirectory(
                assetsDirectory
            )
        }
    }

    private func encodedRelativePath(
        assetsDirectoryName: String,
        filename: String
    ) throws -> String {
        let components = [assetsDirectoryName, filename]
        let encodedComponents = try components.map { component in
            guard let encoded = component.addingPercentEncoding(
                withAllowedCharacters: Self.pathComponentCharacters
            ) else {
                throw MarkdownImageImportError.cannotEncodeRelativePath(
                    components.joined(separator: "/")
                )
            }
            return encoded
        }

        return encodedComponents.joined(separator: "/")
    }
}
