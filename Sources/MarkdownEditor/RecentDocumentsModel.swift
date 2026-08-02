import AppKit
import MarkdownEditorCore
import SwiftUI

/// Tracks the Markdown files this app has opened so the welcome window can
/// offer them again.
///
/// AppKit already keeps `NSDocumentController.recentDocumentURLs` for the
/// File > Open Recent menu, but that list cannot have individual entries
/// removed. So the store seeds itself from AppKit once and is authoritative
/// afterwards, while still feeding AppKit's list to keep both menus in sync.
@MainActor
final class RecentDocumentsModel: ObservableObject {
    static let shared = RecentDocumentsModel()

    @Published private(set) var documents: [RecentDocument] = []

    private let defaults: UserDefaults
    private let storageKey = "recentDocumentPaths"
    private let seedKey = "recentDocumentsSeededFromDocumentController"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seedFromDocumentControllerIfNeeded()
        refresh()
    }

    var hasDocuments: Bool {
        !documents.isEmpty
    }

    /// Re-reads the stored paths and drops anything that has been deleted,
    /// renamed, or moved to an unmounted volume.
    func refresh() {
        let storedURLs = RecentDocumentsCatalog.merged(preferred: storedURLs())
        let survivingURLs = RecentDocumentsCatalog.existing(storedURLs)
        if survivingURLs.count != storedURLs.count {
            store(survivingURLs)
        }
        documents = RecentDocumentsCatalog.entries(for: survivingURLs)
    }

    /// Records a document that was opened or saved, moving it to the top.
    func record(_ url: URL) {
        guard FileTreeScanner.isMarkdownDocument(url) else {
            return
        }

        let updatedURLs = RecentDocumentsCatalog.promoting(url, in: storedURLs())
        guard updatedURLs.map(\.path) != storedURLs().map(\.path) else {
            return
        }

        store(updatedURLs)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        documents = RecentDocumentsCatalog.entries(
            for: RecentDocumentsCatalog.existing(updatedURLs)
        )
    }

    func remove(_ url: URL) {
        let remainingURLs = RecentDocumentsCatalog.removing(url, from: storedURLs())
        store(remainingURLs)
        documents = RecentDocumentsCatalog.entries(
            for: RecentDocumentsCatalog.existing(remainingURLs)
        )
    }

    func clear() {
        store([])
        NSDocumentController.shared.clearRecentDocuments(nil)
        documents = []
    }

    private func seedFromDocumentControllerIfNeeded() {
        guard !defaults.bool(forKey: seedKey) else {
            return
        }
        defaults.set(true, forKey: seedKey)

        let seededURLs = RecentDocumentsCatalog.merged(
            preferred: storedURLs(),
            additional: NSDocumentController.shared.recentDocumentURLs
        )
        store(seededURLs)
    }

    private func storedURLs() -> [URL] {
        let paths = defaults.stringArray(forKey: storageKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    private func store(_ urls: [URL]) {
        defaults.set(urls.map(\.standardizedFileURL.path), forKey: storageKey)
    }
}
