import Foundation

/// What changed in the rendered text when a block was rendered again.
///
/// Everything is expressed in *rendered* coordinates, because that is what the
/// text view stores: `renderedRange` is the stretch of the old rendered text
/// that no longer applies, and `fragment` is what now stands there. The spans
/// are rebased onto the fragment so the styler can build the replacement
/// without ever seeing the rest of the document.
public struct MarkdownRenderUpdate: Equatable {
    public let renderedRange: NSRange
    public let fragment: String
    public let spans: [MarkdownRenderSpan]
    /// How many blocks had to be parsed again. The locality tests assert on
    /// this rather than on a clock, which would only be flaky.
    public let reparsedBlockCount: Int

    public init(
        renderedRange: NSRange,
        fragment: String,
        spans: [MarkdownRenderSpan],
        reparsedBlockCount: Int
    ) {
        self.renderedRange = renderedRange
        self.fragment = fragment
        self.spans = spans
        self.reparsedBlockCount = reparsedBlockCount
    }
}

/// Renders a document a block at a time, keeping the blocks an edit did not
/// touch.
///
/// The requirement this exists for is that a keystroke costs what the keystroke
/// changed and nothing more, however long the document is. Rendering the whole
/// thing per character was three separate O(document) costs — parsing it,
/// building an attributed string for it, and handing that to TextKit, which
/// threw away every glyph it had laid out — and it allocated the document
/// several times over on the way.
///
/// The unit of reuse is a **block**, and the choice of block is not arbitrary:
/// the Markdown parser carries exactly one piece of state from line to line,
/// which is whether a fenced code block is open. So a block is one line, or one
/// fenced region from its opening fence to its closing one. At every boundary
/// between blocks the parser's state is empty, which means a block can be
/// parsed on its own and produce *precisely* what parsing the whole document
/// would have produced for it. `MarkdownIncrementalRenderTests` checks that
/// equality over the contract corpus and a fuzzed edit stream rather than
/// taking it on trust.
///
/// A block that alters the structure around it — typing the third backtick of
/// a fence, say — simply carries the re-parse forward until the parse rejoins
/// what was already there, so widening happens by construction and there is no
/// case that falls back to the whole document.
public final class MarkdownIncrementalRenderer {
    /// A block's rendered text, spans and offset mapping, and where it sits.
    ///
    /// The model is the cache: a block the edit did not reach keeps the very
    /// same `MarkdownRenderModel` it already had — not an equal copy, the same
    /// one — so an edit allocates for the blocks it touched and for nothing
    /// else.
    private struct Block {
        var sourceStart: Int
        var renderedStart: Int
        var model: MarkdownRenderModel
        /// Handed out when the block is parsed and never again, so a test can
        /// tell a block that was kept from one that happens to look the same.
        var identity: Int

        var sourceLength: Int { model.sourceLength }
        var renderedLength: Int { model.renderedLength }
        var sourceEnd: Int { sourceStart + sourceLength }
        var renderedEnd: Int { renderedStart + renderedLength }
    }

    private let source: NSMutableString
    private var blocks: [Block]
    private var totalRenderedLength: Int
    private var nextBlockIdentity = 0

    public init(source: String = "") {
        self.source = NSMutableString(string: source)
        blocks = []
        totalRenderedLength = 0
        rebuildAllBlocks()
    }

    // MARK: - Reading the document

    public var sourceLength: Int {
        source.length
    }

    public var renderedLength: Int {
        totalRenderedLength
    }

    public var blockCount: Int {
        blocks.count
    }

    /// One number per block, stable for as long as the block is kept. A block
    /// that shows a new number was parsed again; the locality tests use this
    /// to check that a keystroke reuses everything it did not touch.
    public func blockModelIdentitiesForTesting() -> [Int] {
        blocks.map(\.identity)
    }

    /// The two offset tables, opened up so the equivalence tests can compare
    /// them against a full render directly rather than through the mappings
    /// built on top of them.
    func upperSourceOffsetForTesting(at index: Int) -> Int {
        upperSourceOffset(at: index)
    }

    func lowerSourceOffsetForTesting(at index: Int) -> Int {
        lowerSourceOffset(at: index)
    }

    /// The whole rendered text. Only the paths that legitimately need the
    /// document end to end use this — a first render, a theme change, a test.
    /// Nothing on the typing path does.
    public func renderedText() -> String {
        let text = NSMutableString(capacity: totalRenderedLength)
        for block in blocks {
            text.append(block.model.text)
        }
        return text as String
    }

    /// The whole document as one model, for the paths that are allowed to be
    /// O(document): the contract fixtures, and the tests that check a rendered
    /// document against the one-shot renderer.
    public func model() -> MarkdownRenderModel {
        MarkdownRenderer.render(source as String)
    }

    /// Every span, in document coordinates. O(document), so off the typing
    /// path only.
    public func allSpans() -> [MarkdownRenderSpan] {
        var spans: [MarkdownRenderSpan] = []
        for block in blocks {
            spans.append(contentsOf: rebased(block.model.spans, in: block))
        }
        return spans
    }

    /// The spans touching a stretch of rendered text, in document coordinates.
    ///
    /// A span never crosses a block, so only the blocks the range lands on
    /// have to be looked at.
    public func spans(inRenderedRange range: NSRange) -> [MarkdownRenderSpan] {
        var spans: [MarkdownRenderSpan] = []
        for index in blockIndices(coveringRendered: range) {
            let block = blocks[index]
            for span in block.model.spans {
                let rendered = NSRange(
                    location: span.renderedRange.location
                        + block.renderedStart,
                    length: span.renderedRange.length
                )
                // A zero-length span sits *between* characters, so it counts
                // as touching a range it sits at either end of. The caret's
                // own block style — an empty quote line, a list item with
                // nothing typed into it yet — is exactly such a span at the
                // end of the document.
                guard NSIntersectionRange(rendered, range).length > 0
                    || (
                        rendered.length == 0
                            && rendered.location >= range.location
                            && rendered.location <= NSMaxRange(range)
                    )
                else { continue }
                spans.append(rebased(span, in: block))
            }
        }
        return spans
    }

    /// Whether a source offset sits in a fenced code block.
    ///
    /// Answered from the block it lands in, which is what a fence *is* here,
    /// rather than by walking every span in the document.
    public func isInsideCodeBlock(sourceOffset: Int) -> Bool {
        // The end of the document belongs to the last block. A caret there is
        // inside an unclosed fence as much as one a character earlier is, and
        // saying otherwise made Return at the end of a code block continue the
        // list the code happened to contain.
        guard let index = blockIndex(containingSource: sourceOffset)
            ?? (sourceOffset == source.length ? blocks.indices.last : nil)
        else {
            return false
        }
        let block = blocks[index]
        return block.model.spans.contains { span in
            guard case .codeBlock = span.style else { return false }
            let start = span.sourceRange.location + block.sourceStart
            return sourceOffset >= start
                && sourceOffset <= start + span.sourceRange.length
        }
    }

    // MARK: - Mapping between the source and what is shown

    public func sourceRange(
        for renderedRange: NSRange,
        includingMarkup: Bool = false
    ) -> NSRange {
        let location = min(max(0, renderedRange.location), totalRenderedLength)
        let length = min(
            max(0, renderedRange.length),
            totalRenderedLength - location
        )
        let clampedRange = NSRange(location: location, length: length)
        guard clampedRange.length > 0 else {
            return NSRange(location: upperSourceOffset(at: location), length: 0)
        }

        var sourceStart = upperSourceOffset(at: location)
        var sourceEnd = lowerSourceOffset(at: NSMaxRange(clampedRange))
        for index in blockIndices(coveringRendered: clampedRange) {
            let block = blocks[index]
            for span in block.model.spans {
                let rendered = NSRange(
                    location: span.renderedRange.location
                        + block.renderedStart,
                    length: span.renderedRange.length
                )
                let spanStart = span.sourceRange.location + block.sourceStart
                let spanEnd = spanStart + span.sourceRange.length
                if span.isAtomic,
                    NSIntersectionRange(clampedRange, rendered).length > 0
                {
                    sourceStart = min(sourceStart, spanStart)
                    sourceEnd = max(sourceEnd, spanEnd)
                } else if includingMarkup,
                    span.includesMarkup,
                    rendered.length > 0,
                    clampedRange.location <= rendered.location,
                    NSMaxRange(clampedRange) >= NSMaxRange(rendered)
                {
                    sourceStart = min(sourceStart, spanStart)
                    sourceEnd = max(sourceEnd, spanEnd)
                }
            }
        }

        return NSRange(
            location: sourceStart,
            length: max(0, sourceEnd - sourceStart)
        )
    }

    public func renderedRange(for sourceRange: NSRange) -> NSRange {
        let sourceStart = max(0, sourceRange.location)
        let sourceEnd = max(sourceStart, NSMaxRange(sourceRange))
        let renderedStart = renderedOffset(
            forSourceOffset: sourceStart,
            usingLowerEdge: false
        )
        guard sourceRange.length > 0 else {
            return NSRange(location: renderedStart, length: 0)
        }
        let renderedEnd = renderedOffset(
            forSourceOffset: sourceEnd,
            usingLowerEdge: true
        )
        return NSRange(
            location: renderedStart,
            length: max(0, renderedEnd - renderedStart)
        )
    }

    /// The source offset at the start of whatever produced rendered character
    /// `index`.
    ///
    /// A block that renders to nothing — an empty fence — appends no
    /// characters, so no rendered position belongs to it and the search steps
    /// over it to the block that does. That is exactly what the single table
    /// this replaces ended up holding.
    private func upperSourceOffset(at index: Int) -> Int {
        guard let blockIndex = blockIndex(containingRendered: index) else {
            return source.length
        }
        let block = blocks[blockIndex]
        return block.sourceStart
            + block.model.upperSourceOffset(at: index - block.renderedStart)
    }

    /// The source offset at the end of whatever produced rendered character
    /// `index - 1`.
    private func lowerSourceOffset(at index: Int) -> Int {
        guard index > 0,
            let blockIndex = blockIndex(containingRendered: index - 1)
        else {
            return 0
        }
        let block = blocks[blockIndex]
        return block.sourceStart
            + block.model.lowerSourceOffset(at: index - block.renderedStart)
    }

    /// The first rendered index whose source offset has reached
    /// `sourceOffset`, measured from either edge of the mapping.
    ///
    /// Deliberately a search over the whole document rather than a question
    /// put to the block the offset lands in. The two are not the same: a
    /// block's last run can stop short of the block's own end — a fence's
    /// closing line renders to nothing — and the answer for an offset in that
    /// gap belongs to the block *after* it. Both edges only ever move forwards
    /// through the source, so a binary search over them is exact, and each
    /// probe is two more binary searches rather than a walk.
    private func renderedOffset(
        forSourceOffset sourceOffset: Int,
        usingLowerEdge: Bool
    ) -> Int {
        var low = 0
        var high = totalRenderedLength
        while low < high {
            let middle = (low + high) / 2
            let mapped = usingLowerEdge
                ? lowerSourceOffset(at: middle)
                : upperSourceOffset(at: middle)
            if mapped >= sourceOffset {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    // MARK: - Editing

    /// Replaces a stretch of the Markdown and renders only the blocks that
    /// stretch reaches.
    @discardableResult
    public func replace(
        sourceRange: NSRange,
        with replacement: String
    ) -> MarkdownRenderUpdate {
        let range = clamped(sourceRange, to: source.length)
        let replacementLength = (replacement as NSString).length
        source.replaceCharacters(in: range, with: replacement)
        let delta = replacementLength - range.length

        guard !blocks.isEmpty else {
            let renderedBefore = totalRenderedLength
            rebuildAllBlocks()
            return MarkdownRenderUpdate(
                renderedRange: NSRange(location: 0, length: renderedBefore),
                fragment: renderedText(),
                spans: allSpans(),
                reparsedBlockCount: blocks.count
            )
        }

        // The first block the edit can have changed, and the first block after
        // it whose text the edit left alone. Everything between them is parsed
        // again; everything outside them keeps the model it already had.
        let firstIndex = blockIndex(containingSource: range.location)
            ?? (blocks.count - 1)
        let lastTouched = blockIndex(
            containingSource: max(range.location, NSMaxRange(range) - 1)
        ) ?? (blocks.count - 1)

        let sourceStart = blocks[firstIndex].sourceStart
        let renderedStart = blocks[firstIndex].renderedStart
        // Where the old blocks resume in the *new* source, so a re-parse can
        // recognise that it has caught up with them.
        var resumeIndex = max(firstIndex, lastTouched) + 1
        var parsed: [MarkdownRenderModel] = []
        var cursor = sourceStart

        while true {
            // A boundary the re-parse has reached that the edit did not move
            // means the rest of the document parses exactly as before, because
            // no fence is open at a block boundary.
            if resumeIndex < blocks.count,
                cursor == blocks[resumeIndex].sourceStart + delta
            {
                break
            }
            if cursor >= source.length {
                resumeIndex = blocks.count
                break
            }
            if resumeIndex < blocks.count,
                cursor > blocks[resumeIndex].sourceStart + delta
            {
                resumeIndex += 1
                continue
            }
            let blockRange = MarkdownBlockScanner.blockRange(
                startingAt: cursor,
                in: source
            )
            parsed.append(
                MarkdownRenderer.render(source.substring(with: blockRange))
            )
            cursor = NSMaxRange(blockRange)
        }

        let renderedEnd = resumeIndex < blocks.count
            ? blocks[resumeIndex].renderedStart
            : totalRenderedLength
        let replacedRendered = NSRange(
            location: renderedStart,
            length: renderedEnd - renderedStart
        )

        var newBlocks: [Block] = []
        newBlocks.reserveCapacity(parsed.count)
        var blockSource = sourceStart
        var blockRendered = renderedStart
        var fragment = ""
        var fragmentSpans: [MarkdownRenderSpan] = []
        for model in parsed {
            let block = Block(
                sourceStart: blockSource,
                renderedStart: blockRendered,
                model: model,
                identity: takeBlockIdentity()
            )
            fragment += model.text
            for span in model.spans {
                fragmentSpans.append(
                    MarkdownRenderSpan(
                        style: span.style,
                        renderedRange: NSRange(
                            location: span.renderedRange.location
                                + blockRendered - renderedStart,
                            length: span.renderedRange.length
                        ),
                        sourceRange: NSRange(
                            location: span.sourceRange.location + blockSource,
                            length: span.sourceRange.length
                        ),
                        includesMarkup: span.includesMarkup,
                        isAtomic: span.isAtomic
                    )
                )
            }
            newBlocks.append(block)
            blockSource += model.sourceLength
            blockRendered += model.renderedLength
        }

        let renderedDelta = blockRendered - renderedEnd
        blocks.replaceSubrange(firstIndex..<resumeIndex, with: newBlocks)
        // The blocks after the edit keep their models untouched; only where
        // they sit moves, which is two integers each and no allocation.
        if delta != 0 || renderedDelta != 0 {
            for index in (firstIndex + newBlocks.count)..<blocks.count {
                blocks[index].sourceStart += delta
                blocks[index].renderedStart += renderedDelta
            }
        }
        totalRenderedLength += renderedDelta

        return MarkdownRenderUpdate(
            renderedRange: replacedRendered,
            fragment: fragment,
            spans: fragmentSpans,
            reparsedBlockCount: newBlocks.count
        )
    }

    /// Adopts a document that arrived whole — a file reloaded from disk, an
    /// undo, a formatting command — by finding what actually changed and
    /// rendering only that.
    @discardableResult
    public func update(
        source newSource: String,
        editedSourceRange: NSRange? = nil
    ) -> MarkdownRenderUpdate {
        let difference = editedSourceRange.map {
            MarkdownTextDifference.replacement(
                from: source as String,
                to: newSource,
                replacing: $0
            )
        } ?? MarkdownTextDifference.minimalReplacement(
            from: source as String,
            to: newSource
        )
        return replace(
            sourceRange: difference.range,
            with: difference.replacement
        )
    }

    /// Throws the cache away and renders everything again. For a different
    /// document, not for an edit to this one.
    public func reset(source newSource: String) {
        source.setString(newSource)
        rebuildAllBlocks()
    }

    // MARK: - Building

    private func takeBlockIdentity() -> Int {
        nextBlockIdentity += 1
        return nextBlockIdentity
    }

    private func rebuildAllBlocks() {
        blocks.removeAll(keepingCapacity: true)
        var cursor = 0
        var rendered = 0
        while cursor < source.length {
            let blockRange = MarkdownBlockScanner.blockRange(
                startingAt: cursor,
                in: source
            )
            let model = MarkdownRenderer.render(
                source.substring(with: blockRange)
            )
            blocks.append(
                Block(
                    sourceStart: blockRange.location,
                    renderedStart: rendered,
                    model: model,
                    identity: takeBlockIdentity()
                )
            )
            rendered += model.renderedLength
            cursor = NSMaxRange(blockRange)
        }
        totalRenderedLength = rendered
    }

    // MARK: - Finding a block

    /// The block a source offset falls in, or nil past the end.
    private func blockIndex(containingSource offset: Int) -> Int? {
        guard offset >= 0, !blocks.isEmpty else { return nil }
        var low = 0
        var high = blocks.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if blocks[middle].sourceStart <= offset {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard let found, offset < blocks[found].sourceEnd else { return nil }
        return found
    }

    /// The block a rendered offset falls in.
    ///
    /// Blocks that render to nothing share a rendered start with the block
    /// after them; taking the *last* block that starts at or before the offset
    /// steps over them, which is right, because no rendered position belongs
    /// to a block that produced no characters.
    private func blockIndex(containingRendered offset: Int) -> Int? {
        guard offset >= 0, offset < totalRenderedLength else { return nil }
        var low = 0
        var high = blocks.count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if blocks[middle].renderedStart <= offset {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    private func blockIndices(coveringRendered range: NSRange) -> Range<Int> {
        guard !blocks.isEmpty else { return 0..<0 }
        let start = min(max(0, range.location), totalRenderedLength)
        let end = min(max(start, NSMaxRange(range)), totalRenderedLength)
        // A query that reaches the end of the document is asking about the
        // last block, which `blockIndex` declines to name because no rendered
        // character lives there.
        var first = blockIndex(containingRendered: start)
            ?? (blocks.count - 1)
        // Blocks that render to nothing sit on a boundary rather than across
        // it, so a query landing on that boundary covers them too.
        while first > 0,
            blocks[first - 1].renderedStart >= start,
            blocks[first - 1].renderedEnd >= start
        {
            first -= 1
        }
        var last = first
        while last + 1 < blocks.count,
            blocks[last + 1].renderedStart <= end
        {
            last += 1
        }
        return first..<(last + 1)
    }

    private func rebased(
        _ span: MarkdownRenderSpan,
        in block: Block
    ) -> MarkdownRenderSpan {
        MarkdownRenderSpan(
            style: span.style,
            renderedRange: NSRange(
                location: span.renderedRange.location + block.renderedStart,
                length: span.renderedRange.length
            ),
            sourceRange: NSRange(
                location: span.sourceRange.location + block.sourceStart,
                length: span.sourceRange.length
            ),
            includesMarkup: span.includesMarkup,
            isAtomic: span.isAtomic
        )
    }

    private func rebased(
        _ spans: [MarkdownRenderSpan],
        in block: Block
    ) -> [MarkdownRenderSpan] {
        spans.map { rebased($0, in: block) }
    }

    private func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(
            location: location,
            length: min(max(0, range.length), length - location)
        )
    }
}

/// Where one unit of parsing ends and the next begins.
///
/// The Markdown parser carries one thing from line to line — whether a fenced
/// code block is open — so a unit is a line, unless that line opens a fence, in
/// which case it is the fence and everything up to and including the line that
/// closes it. The consequence, and the whole reason this type exists, is that
/// no parser state ever crosses a boundary, so a block parses on its own into
/// exactly what the whole document would have given it.
public enum MarkdownBlockScanner {
    /// The source range of the block beginning at `location`.
    public static func blockRange(startingAt location: Int, in source: NSString) -> NSRange {
        var cursor = location
        var fence: MarkdownFence?

        while cursor < source.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )
            let next = max(lineEnd, cursor + 1)
            // Reading the line out costs an allocation, and all but a handful
            // of lines in any document cannot possibly be a fence. Looking at
            // the first few characters first is what keeps walking a long
            // document a character scan rather than a string-building
            // exercise.
            let couldBeFence = mightBeFence(
                in: source,
                from: lineStart,
                to: contentsEnd
            )

            if let openFence = fence {
                if couldBeFence,
                    MarkdownFence.isClosing(
                        line(in: source, from: lineStart, to: contentsEnd),
                        for: openFence
                    )
                {
                    return NSRange(
                        location: location,
                        length: next - location
                    )
                }
            } else if couldBeFence,
                let opened = MarkdownFence.opening(
                    in: line(in: source, from: lineStart, to: contentsEnd)
                )
            {
                fence = opened
            } else {
                return NSRange(location: location, length: next - location)
            }
            cursor = next
        }

        return NSRange(location: location, length: source.length - location)
    }

    /// The source range of the block a source offset falls in.
    ///
    /// Whether a line is inside a fence is the one thing that cannot be read
    /// off the line itself, so answering this in general means walking from the
    /// top of the document. A document with no fence marker before the offset
    /// can have no fence open at it, and that check is a single native string
    /// search — so the common case is the line the offset is on and nothing
    /// more.
    public static func blockRange(containing location: Int, in source: NSString) -> NSRange {
        guard source.length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        let offset = min(max(0, location), source.length)
        var cursor = 0
        if !hasFenceMarker(in: source, before: offset) {
            var lineStart = 0
            source.getLineStart(
                &lineStart,
                end: nil,
                contentsEnd: nil,
                for: NSRange(location: min(offset, source.length - 1), length: 0)
            )
            cursor = lineStart
        }

        while cursor < source.length {
            let range = blockRange(startingAt: cursor, in: source)
            if offset < NSMaxRange(range) || NSMaxRange(range) >= source.length {
                return range
            }
            cursor = NSMaxRange(range)
        }
        return NSRange(location: source.length, length: 0)
    }

    private static func hasFenceMarker(
        in source: NSString,
        before offset: Int
    ) -> Bool {
        let head = NSRange(location: 0, length: offset)
        guard head.length >= 3 else { return false }
        for marker in ["```", "~~~"] where source.range(
            of: marker,
            options: .literal,
            range: head
        ).location != NSNotFound {
            return true
        }
        return false
    }

    /// Whether a line could be a fence at all: three of the same marker
    /// character after nothing but blanks.
    private static func mightBeFence(
        in source: NSString,
        from lineStart: Int,
        to contentsEnd: Int
    ) -> Bool {
        var index = lineStart
        while index < contentsEnd {
            let character = source.character(at: index)
            guard isLeadingBlank(character) else { break }
            index += 1
        }
        guard index + 2 < contentsEnd + 1, contentsEnd - index >= 3 else {
            return false
        }
        let marker = source.character(at: index)
        guard marker == 0x60 || marker == 0x7E else { return false }
        return source.character(at: index + 1) == marker
            && source.character(at: index + 2) == marker
    }

    /// Exactly what `trimmingCharacters(in: .whitespaces)` would take off the
    /// front of the line, which is what `MarkdownFence.opening` does before it
    /// looks for the marker.
    ///
    /// Not just a space and a tab: the set includes the no-break space and the
    /// typographic spaces, and a line indented with one of those opened a fence
    /// for the parser while this said it could not — which is the one way the
    /// scanner and the parser were able to disagree about where a block ends.
    private static func isLeadingBlank(_ character: unichar) -> Bool {
        if character == 0x20 || character == 0x09 { return true }
        if character < 0x80 { return false }
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }

    private static func line(
        in source: NSString,
        from lineStart: Int,
        to contentsEnd: Int
    ) -> String {
        source.substring(
            with: NSRange(
                location: lineStart,
                length: contentsEnd - lineStart
            )
        )
    }
}

/// A fenced code block's opening marker, and the rules for matching it.
///
/// Shared by the parser and by `MarkdownBlockScanner` so the two cannot come to
/// different conclusions about where a fence starts and stops — which would
/// break the promise that a block renders the same alone as in context.
struct MarkdownFence {
    let marker: String
    let language: String?

    static func opening(in line: String) -> MarkdownFence? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else {
            return nil
        }
        guard let markerCharacter = trimmed.first else {
            return nil
        }
        let marker = String(trimmed.prefix { $0 == markerCharacter })
        guard marker.count >= 3 else {
            return nil
        }
        let language = trimmed.dropFirst(marker.count)
            .trimmingCharacters(in: .whitespaces)
        if markerCharacter == "`", language.contains("`") {
            return nil
        }
        return MarkdownFence(
            marker: marker,
            language: language.isEmpty ? nil : language
        )
    }

    static func isClosing(_ line: String, for fence: MarkdownFence) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let markerCharacter = fence.marker.first,
            trimmed.first == markerCharacter
        else {
            return false
        }
        let markerLength = trimmed.prefix { $0 == markerCharacter }.count
        guard markerLength >= fence.marker.count else {
            return false
        }
        return trimmed.dropFirst(markerLength)
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
    }
}
