import AppKit
import MarkdownEditorCore
import SwiftUI

struct FileExplorerAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String?
}

@MainActor
final class FileExplorerModel: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var generation = 0
    @Published var presentedAlert: FileExplorerAlert?

    private let scanner: FileTreeScanner
    private var cachedChildren: [URL: [FileTreeEntry]] = [:]
    private var followsDocumentDirectory: Bool

    init(
        documentURL: URL?,
        scanner: FileTreeScanner = FileTreeScanner()
    ) {
        self.scanner = scanner
        rootURL = documentURL?.deletingLastPathComponent()
            .standardizedFileURL
        followsDocumentDirectory = documentURL != nil
    }

    var displayedPath: String {
        rootURL?.path ?? "No Folder"
    }

    var ancestorURLs: [URL] {
        rootURL.map(FileTreeScanner.ancestorDirectories(startingAt:)) ?? []
    }

    func followDocument(_ documentURL: URL?) {
        guard followsDocumentDirectory || rootURL == nil,
            let documentURL
        else {
            return
        }
        setRoot(
            documentURL.deletingLastPathComponent(),
            followsDocumentDirectory: true
        )
    }

    func setUserSelectedRoot(_ url: URL) {
        setRoot(url, followsDocumentDirectory: false)
    }

    func children(of directoryURL: URL) -> [FileTreeEntry] {
        let key = directoryURL.standardizedFileURL
        if let cached = cachedChildren[key] {
            return cached
        }

        do {
            let children = try scanner.contents(of: key)
            cachedChildren[key] = children
            return children
        } catch {
            cachedChildren[key] = []
            report(error)
            return []
        }
    }

    func refresh() {
        cachedChildren.removeAll()
        generation &+= 1
    }

    func openExternally(_ entry: FileTreeEntry) {
        guard !entry.isExpandable else {
            return
        }

        guard NSWorkspace.shared.open(entry.url) else {
            report(
                FileExplorerError.couldNotOpen(entry.url.lastPathComponent)
            )
            return
        }
    }

    func report(_ error: Error) {
        let localizedError = error as? LocalizedError
        presentedAlert = FileExplorerAlert(
            title: error.localizedDescription,
            message: localizedError?.recoverySuggestion
        )
    }

    private func setRoot(
        _ url: URL,
        followsDocumentDirectory: Bool
    ) {
        let standardizedURL = url.standardizedFileURL
        self.followsDocumentDirectory = followsDocumentDirectory
        guard rootURL != standardizedURL else {
            return
        }
        rootURL = standardizedURL
        refresh()
    }
}

private enum FileExplorerError: Error, LocalizedError {
    case couldNotOpen(String)

    var errorDescription: String? {
        switch self {
        case .couldNotOpen(let name):
            "The file could not be opened: \(name)"
        }
    }

    var recoverySuggestion: String? {
        "Check that an application is available for this file type."
    }
}
