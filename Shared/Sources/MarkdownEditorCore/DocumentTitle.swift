import Foundation

/// The name a draft that has never been saved goes by: its own title, as the
/// writer typed it.
///
/// macOS 26 and later name an untitled document themselves, a few seconds
/// after its first autosave, and mark the name "Suggested". The name is
/// generated from the text rather than read from it: on macOS 27.2 two drafts
/// that both opened `# Field notes on speed` were offered as "Field Notes on
/// Speed" and "Draft Speed and Latency Notes", and Save proposed whichever it
/// was. A writer who has already typed their title should not have to retype
/// it in the save sheet, letter case and all.
///
/// The title is the line the critique calls the title (`CritiquePlace.Kind`
/// `.title`): a Heading 1 on the draft's first written line, front matter
/// aside. A draft that opens any other way has no title, and is left to
/// whatever the system would call it.
public enum DocumentTitle {
    /// The longest name a title becomes, in characters. A window's title is
    /// cut in the middle well before this; the limit is for the file, whose
    /// name the title also proposes.
    public static let longestName = 80

    /// The title's words without their Markdown, or `nil` when the draft has
    /// no title or its title has no words — `# ` on its own, as every new
    /// document begins.
    public static func title(of text: String) -> String? {
        let source = text as NSString
        var location = CritiqueOutline.Scan.endOfFrontMatter(in: source)
        while location < source.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                &lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            location = max(lineEnd, location + 1)
            let line = source.substring(
                with: NSRange(location: lineStart, length: contentsEnd - lineStart)
            )
            switch CritiqueOutline.Scan.kind(of: line) {
            case .blank:
                continue
            case .heading(level: 1):
                let words = CritiqueOutline.Scan.headingText(line)
                return words.isEmpty ? nil : words
            default:
                return nil
            }
        }
        return nil
    }

    /// The draft's title as the name of the file it would be saved as, or
    /// `nil` when it has no title that makes one.
    public static func draftName(of text: String) -> String? {
        title(of: text).flatMap(fileName(for:))
    }

    /// A title made safe to be a file's name, and otherwise left alone.
    ///
    /// Finder will not take a colon in a name, and stores a slash on disk as
    /// a colon, so both become a dash: "Speed: a field guide" is saved as
    /// "Speed - a field guide". A leading dot would hide the file, and a
    /// trailing one would put two before the extension. The letter case is
    /// the writer's, which is the point of all this.
    public static func fileName(for title: String) -> String? {
        var name = title
            .replacingOccurrences(of: ": ", with: " - ")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        name = String(name.drop { $0 == "." || $0 == " " })
        if name.count > longestName {
            let cut = name.prefix(longestName)
            if name.dropFirst(longestName).first != " ",
               let space = cut.lastIndex(of: " "),
               cut.distance(from: cut.startIndex, to: space) >= longestName / 2 {
                name = String(cut[..<space])
            } else {
                name = String(cut)
            }
        }
        // 255 bytes is the most a file name can be, with its extension. An
        // emoji is four of them, so 80 characters is not always under it.
        while name.utf8.count > 240 {
            name.removeLast()
        }
        while let last = name.last, last == "." || last == " " || last == "-" || last == "," {
            name.removeLast()
        }
        return name.isEmpty ? nil : name
    }
}
