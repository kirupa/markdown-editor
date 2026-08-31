import Foundation
import MarkdownEditorCore

/// Where a document's answered findings are kept between runs.
///
/// In user defaults rather than beside the document, because a critique is not
/// part of the draft. Writing a dotfile next to somebody's Markdown — or worse,
/// into it — would put an editor's bookkeeping into a folder they sync, share,
/// and commit.
///
/// The cost is that the decisions are per-machine, and that moving the file
/// loses them. Both are the right trade for a record of "I already read that
/// one": losing it costs a dismissal, and the alternative costs the tidiness of
/// somebody's project.
enum CritiqueResolutionStore {
    private static let key = "critiqueResolutions"
    /// How many documents are remembered, most recently used first.
    ///
    /// Without a cap this grows for the life of the install. A hundred
    /// documents is far more than anyone has open in a working week, and the
    /// entry that falls off the end costs a dismissal on a file untouched for
    /// months.
    private static let documentLimit = 100

    static func load(
        for url: URL?,
        defaults: UserDefaults = .standard
    ) -> CritiqueResolutions {
        guard let url else { return CritiqueResolutions() }
        let all = defaults.dictionary(forKey: key) as? [String: [String: String]]
        return CritiqueResolutions(storage: all?[url.path] ?? [:])
    }

    static func save(
        _ resolutions: CritiqueResolutions,
        for url: URL?,
        defaults: UserDefaults = .standard
    ) {
        guard let url else { return }
        var all = defaults.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        if resolutions.isEmpty {
            all.removeValue(forKey: url.path)
        } else {
            all[url.path] = resolutions.storage
        }
        defaults.set(trimmed(all, keeping: url.path), forKey: key)
    }

    /// Keeps the store bounded, never dropping the document in hand.
    static func trimmed(
        _ all: [String: [String: String]],
        keeping current: String,
        limit: Int = documentLimit
    ) -> [String: [String: String]] {
        guard all.count > limit else { return all }
        // Nothing here records when a document was last touched, so the
        // honest rule is "keep the one being used and an arbitrary rest"
        // rather than pretending to an order that was never recorded.
        var kept: [String: [String: String]] = [:]
        if let mine = all[current] { kept[current] = mine }
        for (path, entries) in all where path != current {
            guard kept.count < limit else { break }
            kept[path] = entries
        }
        return kept
    }
}
