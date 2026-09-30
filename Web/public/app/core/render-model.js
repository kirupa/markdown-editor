import {
    makeRange,
    maxRange,
    intersectionRange,
    substringWithRange,
    lineBounds,
} from './range.js';
import { parseImageTag } from './image-tag.js';

// ─── Style constructors ───────────────────────────────────────────────────────
// Each style is a tagged plain object whose `kind` matches the Swift enum case
// name exactly (camelCase).  Simple styles are frozen singletons; parameterised
// styles are factory functions.

export function heading(level)              { return { kind: 'heading', level }; }
export const bold           = Object.freeze({ kind: 'bold' });
export const italic         = Object.freeze({ kind: 'italic' });
export const underline      = Object.freeze({ kind: 'underline' });
export const strikethrough  = Object.freeze({ kind: 'strikethrough' });
export const inlineCode     = Object.freeze({ kind: 'inlineCode' });
export function codeBlock(language)         { return { kind: 'codeBlock', language: language ?? null }; }
export const quote          = Object.freeze({ kind: 'quote' });
export const bulletedList   = Object.freeze({ kind: 'bulletedList' });
export const numberedList   = Object.freeze({ kind: 'numberedList' });
export function taskList(checked)           { return { kind: 'taskList', checked }; }
export function link(destination)           { return { kind: 'link', destination }; }
/**
 * `width` and `height` are pixel counts, or null when the image carries no size.
 * Markdown's own `![alt](src)` can never carry one; only the HTML form can.
 */
export function image(altText, destination, width = null, height = null) {
    return { kind: 'image', altText, destination, width, height };
}
export const horizontalRule = Object.freeze({ kind: 'horizontalRule' });
export const escaped        = Object.freeze({ kind: 'escaped' });

// ─── MarkdownRenderModel ──────────────────────────────────────────────────────

/**
 * One source line's contribution to the model, in the line's own coordinates.
 *
 * Nothing here is absolute, which is the whole point: a line that was not
 * edited renders the same wherever the text above it pushes it to, so its
 * parse survives every edit that happens elsewhere (E-7).
 *
 * `lower` and `upper` hold one entry per rendered code unit the line produced,
 * for rendered positions 1…length. Position 0 is the boundary this line shares
 * with the one above, and only its upper bound belongs to this line —
 * `upperAtStart` — because that is the offset the parser records when it skips
 * markup before emitting anything.
 */
class LineRender {
    constructor(sourceLength, text, spans, lower, upper, upperAtStart, enterFence, exitFence) {
        this.sourceLength = sourceLength;
        this.text         = text;
        this.spans        = spans;
        this.lower        = lower;
        this.upper        = upper;
        this.upperAtStart = upperAtStart;
        this.enterFence   = enterFence;
        this.exitFence    = exitFence;
    }
}

/** Two fence states are interchangeable when a line cannot tell them apart. */
function sameFence(a, b) {
    if (a === b) return true;
    if (a === null || b === null) return false;
    return a.marker === b.marker && a.language === b.language;
}

/** Index of the last entry in the sorted `starts` that is <= `value`. */
function lastAtOrBefore(starts, count, value) {
    let low = 0;
    let high = count - 1;
    let found = 0;
    while (low <= high) {
        const middle = (low + high) >> 1;
        if (starts[middle] <= value) { found = middle; low = middle + 1; }
        else high = middle - 1;
    }
    return found;
}

/** Index of the last entry in the sorted `starts` that is strictly below. */
function lastBefore(starts, count, value) {
    let low = 0;
    let high = count - 1;
    let found = 0;
    while (low <= high) {
        const middle = (low + high) >> 1;
        if (starts[middle] < value) { found = middle; low = middle + 1; }
        else high = middle - 1;
    }
    return found;
}

export class MarkdownRenderModel {
    #lines         = [];   // LineRender[], one per source line
    #sourceStart   = [];   // absolute source offset of each line
    #renderedStart = [];   // absolute rendered offset of each line
    // Lengths and fence transitions live beside the lines rather than inside
    // them. Restating where the lines below an edit begin is the one thing
    // still proportional to the document, so it reads plain numbers packed
    // together instead of chasing a pointer per line.
    #sourceSpan    = [];   // source characters each line consumes
    #renderedSpan  = [];   // rendered characters each line produces
    #fenceMark     = [];   // 0 nothing, 1 opens a fence, 2 closes one
    #fenceOpen     = [];   // line indices where a fence opens, ascending
    #fenceClose    = [];   // the matching closing line, or -1 when unclosed
    // Rendered blocks are the lines that produce text — a fence's own marker
    // lines render nothing — plus the empty block a trailing newline leaves
    // behind. The editor's DOM is one element per block, so the two indexes
    // are what let an edit be turned into a handful of element rebuilds.
    #blockLine     = [];   // line each block came from, or -1 for the last empty one
    #blockOfLine   = [];   // line-backed blocks produced above a line; one entry past the end
    #dirtyFrom     = -1;   // first block an update disturbed, or -1 when nothing did
    #dirtySuffix   = 0;    // blocks at the end that both old and new agree on
    #text          = null; // materialised on demand
    #spans         = null;

    /**
     * The source the model describes.
     *
     * Held as a reference, not a copy — JavaScript strings are immutable and
     * shared, so this is a pointer to the same text the document already owns.
     * It is what lets an update that arrives without a change description work
     * out for itself what moved.
     */
    source = '';

    constructor(source = '') {
        this.#reparseAll(source);
    }

    get text() {
        if (this.#text === null) {
            let text = '';
            for (const line of this.#lines) text += line.text;
            this.#text = text;
        }
        return this.#text;
    }

    get spans() {
        if (this.#spans === null) this.#spans = this.#materialiseSpans();
        return this.#spans;
    }

    get lineCount() {
        return this.#lines.length;
    }

    /** Rendered text of one source line, including any line terminator. */
    lineText(index) {
        return this.#lines[index].text;
    }

    lineRenderedStart(index) {
        return index < this.#lines.length ? this.#renderedStart[index] : this.renderedLength;
    }

    lineSourceStart(index) {
        return index < this.#lines.length ? this.#sourceStart[index] : this.source.length;
    }

    get renderedLength() {
        const count = this.#lines.length;
        if (count === 0) return 0;
        return this.#renderedStart[count - 1] + this.#lines[count - 1].text.length;
    }

    /** Spans a line owns, rebased onto absolute offsets. */
    spansForLine(index) {
        const line = this.#lines[index];
        if (line.spans.length === 0) return line.spans;
        return line.spans.map((span) => this.#rebase(span, index));
    }

    /** Spans belonging to the line `offset` falls on. */
    spansForSourceLine(offset) {
        const count = this.#lines.length;
        if (count === 0) return [];
        return this.spansForLine(lastAtOrBefore(this.#sourceStart, count, offset));
    }

    /**
     * Every span whose source range can cover `offset`.
     *
     * Only two lines can: the one the offset falls in, and the one above,
     * because a span may end exactly where its line does and the caret sitting
     * there is still inside it.
     */
    spansAtSourceOffset(offset) {
        const count = this.#lines.length;
        if (count === 0) return [];
        const index = lastAtOrBefore(this.#sourceStart, count, offset);
        const spans = [];
        for (let at = Math.max(0, index - 1); at <= index; at += 1) {
            for (const span of this.spansForLine(at)) spans.push(span);
        }
        const fence = this.#firstFenceEndingAtOrAfter(index);
        if (fence < this.#fenceOpen.length && this.#fenceOpen[fence] <= index) {
            spans.push(this.#fenceSpan(fence));
        }
        return spans;
    }

    // ─── Rendered blocks ─────────────────────────────────────────────────────

    get blockCount() {
        return this.#blockLine.length;
    }

    /** The source line a block came from, or -1 for the trailing empty one. */
    blockLine(index) {
        return this.#blockLine[index];
    }

    blockRenderedStart(index) {
        const line = this.#blockLine[index];
        return line === -1 ? this.renderedLength : this.#renderedStart[line];
    }

    /**
     * Where a block's text ends.
     *
     * Blocks are separated by exactly one newline, so the end of one is the
     * start of the next less that character — no need to ask the line whether
     * it was terminated.
     */
    blockRenderedEnd(index) {
        return index + 1 < this.#blockLine.length
            ? this.blockRenderedStart(index + 1) - 1
            : this.renderedLength;
    }

    /** Text of one block, without its terminator. */
    blockText(index) {
        const line = this.#blockLine[index];
        if (line === -1) return '';
        const text = this.#lines[line].text;
        return text.charCodeAt(text.length - 1) === 0x0a ? text.slice(0, -1) : text;
    }

    /**
     * Every span that styles a block: the ones its line owns, plus the fence
     * it may sit inside, which is the only span that outlives a single line.
     */
    blockSpans(index) {
        const line = this.#blockLine[index];
        if (line === -1) return [];
        const spans = this.spansForLine(line);
        if (this.#lines[line].enterFence === null) return spans;
        const fence = this.#firstFenceEndingAtOrAfter(line);
        if (fence < this.#fenceOpen.length && this.#fenceOpen[fence] <= line) {
            return [...spans, this.#fenceSpan(fence)];
        }
        return spans;
    }

    /**
     * What an update disturbed, as a block range, taken once.
     *
     * The renderer owns this: it is the only thing that needs to know, and
     * reading it is what says the DOM has caught up.
     */
    consumeDirty() {
        if (this.#dirtyFrom === -1) return null;
        const dirty = { from: this.#dirtyFrom, suffix: this.#dirtySuffix };
        this.#dirtyFrom = -1;
        return dirty;
    }

    #rebase(span, index) {
        const renderedBase = this.#renderedStart[index];
        const sourceBase   = this.#sourceStart[index];
        return {
            style:          span.style,
            renderedRange:  makeRange(span.renderedRange.location + renderedBase, span.renderedRange.length),
            sourceRange:    makeRange(span.sourceRange.location + sourceBase, span.sourceRange.length),
            includesMarkup: span.includesMarkup,
            isAtomic:       span.isAtomic,
        };
    }

    /**
     * The fence span a closed or unclosed run of fenced code contributes.
     *
     * Built here rather than cached on a line because it is the one span that
     * spans lines, so its extent changes whenever anything between its ends
     * does (Y-5).
     */
    #fenceSpan(which) {
        const openLine  = this.#fenceOpen[which];
        const closeLine = this.#fenceClose[which];
        const language  = this.#lines[openLine].exitFence?.language ?? null;
        // The opening line renders nothing, so the run starts where the line
        // after it starts.
        const renderedStart = this.lineRenderedStart(openLine + 1);
        const renderedEnd   = closeLine === -1
            ? this.renderedLength
            : this.lineRenderedStart(closeLine);
        const sourceStart = this.#sourceStart[openLine];
        const sourceEnd   = closeLine === -1
            ? this.source.length
            : this.#sourceStart[closeLine] + this.#lines[closeLine].sourceLength;
        return {
            style:          codeBlock(language),
            renderedRange:  makeRange(renderedStart, renderedEnd - renderedStart),
            sourceRange:    makeRange(sourceStart, sourceEnd - sourceStart),
            includesMarkup: true,
            isAtomic:       false,
        };
    }

    #materialiseSpans() {
        const spans = [];
        let fence = 0;
        for (let index = 0; index < this.#lines.length; index += 1) {
            for (const span of this.#lines[index].spans) spans.push(this.#rebase(span, index));
            while (fence < this.#fenceOpen.length && this.#fenceClose[fence] === index) {
                spans.push(this.#fenceSpan(fence));
                fence += 1;
            }
        }
        // An unclosed fence runs to the end of the document, so its span is the
        // last thing the parser emits.
        for (; fence < this.#fenceOpen.length; fence += 1) {
            if (this.#fenceClose[fence] === -1) spans.push(this.#fenceSpan(fence));
        }
        return spans;
    }

    /**
     * Every span that could cover a rendered range, without walking the rest.
     *
     * Only lines the range touches can own a span that overlaps it, because
     * every span but the fence is confined to its own line — and a fence only
     * matters to `sourceRange` when the range reaches its opening line.
     */
    #spansOverlapping(range) {
        const count = this.#lines.length;
        if (count === 0) return [];
        const first = lastAtOrBefore(this.#renderedStart, count, range.location);
        const last  = lastAtOrBefore(this.#renderedStart, count, maxRange(range));
        const spans = [];
        for (let index = first; index <= last; index += 1) {
            for (const span of this.#lines[index].spans) spans.push(this.#rebase(span, index));
        }
        // A fence covers `openLine … closeLine`, so the ones that can matter
        // are those whose run of lines meets the window. Both ends are sorted,
        // because fences cannot nest.
        const fences = this.#fenceOpen.length;
        for (let fence = this.#firstFenceEndingAtOrAfter(first); fence < fences; fence += 1) {
            if (this.#fenceOpen[fence] > last) break;
            spans.push(this.#fenceSpan(fence));
        }
        return spans;
    }

    #firstFenceEndingAtOrAfter(line) {
        let low = 0;
        let high = this.#fenceOpen.length - 1;
        let found = this.#fenceOpen.length;
        while (low <= high) {
            const middle = (low + high) >> 1;
            const close = this.#fenceClose[middle];
            if (close === -1 || close >= line) { found = middle; high = middle - 1; }
            else low = middle + 1;
        }
        return found;
    }

    /** The source offset a rendered position maps to through `upper`. */
    #upperAt(position) {
        const count = this.#lines.length;
        if (count === 0) return 0;
        // The parser's last act is to record the end of the source, so the
        // final boundary always maps past everything.
        if (position >= this.renderedLength) return this.source.length;
        const index  = lastAtOrBefore(this.#renderedStart, count, position);
        const line   = this.#lines[index];
        const offset = position - this.#renderedStart[index];
        const relative = offset === 0 ? line.upperAtStart : line.upper[offset - 1];
        return this.#sourceStart[index] + relative;
    }

    /** The source offset a rendered position maps to through `lower`. */
    #lowerAt(position) {
        if (position <= 0) return 0;
        const count = this.#lines.length;
        if (count === 0) return 0;
        const index  = lastBefore(this.#renderedStart, count, position);
        const line   = this.#lines[index];
        const offset = position - this.#renderedStart[index];
        return this.#sourceStart[index] + line.lower[offset - 1];
    }

    /**
     * Maps a rendered range back to the corresponding source range.
     *
     * For a zero-length (caret) range the source position is read from
     * upperSourceOffsets so it lands after any hidden markup that was skipped.
     * Atomic spans widen the result to cover their full source extent.
     * When includingMarkup is true, non-atomic spans whose markup was hidden
     * also widen the result if the rendered selection completely covers them.
     *
     * @param {{ location: number, length: number }} renderedRange
     * @param {boolean} [includingMarkup=false]
     * @returns {{ location: number, length: number }}
     */
    sourceRange(renderedRange, includingMarkup = false) {
        const renderedLength = this.renderedLength;
        const location = Math.min(Math.max(0, renderedRange.location), renderedLength);
        const length   = Math.min(Math.max(0, renderedRange.length), renderedLength - location);
        const clamped  = makeRange(location, length);

        if (clamped.length === 0) {
            return makeRange(this.#upperAt(location), 0);
        }

        let sourceStart = this.#upperAt(location);
        let sourceEnd   = this.#lowerAt(maxRange(clamped));

        for (const span of this.#spansOverlapping(clamped)) {
            if (span.isAtomic &&
                intersectionRange(clamped, span.renderedRange).length > 0
            ) {
                sourceStart = Math.min(sourceStart, span.sourceRange.location);
                sourceEnd   = Math.max(sourceEnd, maxRange(span.sourceRange));
            } else if (
                includingMarkup &&
                span.includesMarkup &&
                span.renderedRange.length > 0 &&
                clamped.location <= span.renderedRange.location &&
                maxRange(clamped) >= maxRange(span.renderedRange)
            ) {
                sourceStart = Math.min(sourceStart, span.sourceRange.location);
                sourceEnd   = Math.max(sourceEnd, maxRange(span.sourceRange));
            }
        }

        return makeRange(sourceStart, Math.max(0, sourceEnd - sourceStart));
    }

    /**
     * Maps a source range to the corresponding rendered range.
     *
     * Uses upperSourceOffsets for the start (finds the earliest rendered
     * position whose mapped source offset is >= sourceStart) and
     * lowerSourceOffsets for the end.
     *
     * @param {{ location: number, length: number }} sourceRange
     * @returns {{ location: number, length: number }}
     */
    renderedRange(sourceRange) {
        const sourceStart   = Math.max(0, sourceRange.location);
        const sourceEnd     = Math.max(sourceStart, maxRange(sourceRange));
        const renderedStart = this.#renderedOffset(sourceStart, true);
        if (sourceRange.length === 0) {
            return makeRange(renderedStart, 0);
        }
        const renderedEnd = this.#renderedOffset(sourceEnd, false);
        return makeRange(renderedStart, Math.max(0, renderedEnd - renderedStart));
    }

    /**
     * First rendered position whose mapped source offset is at least `target`.
     *
     * Both mappings rise with the rendered position, so this is a binary
     * search rather than the forward scan the first port used — the difference
     * between a lookup and a walk of the whole document on every caret move.
     */
    #renderedOffset(target, useUpper) {
        let low  = 0;
        let high = this.renderedLength;
        while (low < high) {
            const middle = (low + high) >> 1;
            const offset = useUpper ? this.#upperAt(middle) : this.#lowerAt(middle);
            if (offset >= target) high = middle;
            else low = middle + 1;
        }
        return low;
    }

    // ─── Keeping up with the document ────────────────────────────────────────

    /**
     * Brings the model up to date with `source`, parsing only what moved.
     *
     * The reparse starts at the line the edit begins on and runs forward until
     * it lands on a line boundary the previous parse also had, entered in the
     * same fence state. From there down every line renders exactly as it
     * already did, however far the edit pushed it — so typing a character into
     * a long document costs what typing a character into a short one costs.
     *
     * `change` is the edit as the caller made it. It is only ever a shortcut:
     * without one, or with one that does not describe the text that arrived,
     * the difference is measured here instead.
     */
    update(source, change = null) {
        if (source === this.source) return this;

        const edit  = this.#editFor(source, change);
        const lines = this.#lines;
        const count = lines.length;

        // An edit belongs to the line it starts on, because a line is the
        // smallest thing this parser makes a decision about.
        let first = count === 0 ? 0 : lastAtOrBefore(this.#sourceStart, count, edit.location);
        const removedEnd = edit.location + edit.removed;
        const delta      = edit.inserted - edit.removed;

        const parser  = new Parser(source);
        const rebuilt = [];
        let location = count === 0 ? 0 : this.#sourceStart[first];
        let fence    = first === 0 ? null : lines[first - 1].exitFence;
        let rejoin   = -1;

        while (location < source.length) {
            // The same place in the text as it was before the edit. Once that
            // is past everything the edit touched and lands on a line the old
            // parse also started, the rest of the document is already right.
            const before = location - delta;
            if (before >= removedEnd) {
                const candidate = this.#lineStartingAt(before, first);
                if (candidate !== -1 && sameFence(lines[candidate].enterFence, fence)) {
                    rejoin = candidate;
                    break;
                }
            }
            const bounds = lineBounds(source, location);
            const line   = parseLine(parser, bounds, fence);
            rebuilt.push(line);
            fence    = line.exitFence;
            location = Math.max(bounds.lineEnd, location + 1);
        }
        if (rejoin === -1) rejoin = count;

        // How much of the document the edit left alone, counted in blocks from
        // the end so the number survives the splice.
        const oldSuffix = this.#blockLine.length - this.#blockOfLine[rejoin];
        const from      = this.#blockOfLine[first];

        this.source = source;
        spliceLines(
            { lines, sourceSpan: this.#sourceSpan, renderedSpan: this.#renderedSpan, fenceMark: this.#fenceMark },
            first,
            rejoin - first,
            rebuilt
        );
        this.#invalidate();
        this.#reindex(first);

        const newSuffix = this.#blockLine.length - this.#blockOfLine[first + rebuilt.length];
        this.#noteDirty(from, Math.min(oldSuffix, newSuffix));
        return this;
    }

    /**
     * Records the block range an update disturbed, merging it with anything
     * not yet drawn — several edits can land between two renders.
     *
     * The suffix is what both the old and the new block list still agree on,
     * so the smallest agreement across every pending update is the safe one.
     */
    #noteDirty(from, suffix) {
        if (this.#dirtyFrom === -1) {
            this.#dirtyFrom   = from;
            this.#dirtySuffix = suffix;
            return;
        }
        this.#dirtyFrom   = Math.min(this.#dirtyFrom, from);
        this.#dirtySuffix = Math.min(this.#dirtySuffix, suffix);
    }

    /** Index of the line that starts exactly at `offset`, at or after `from`. */
    #lineStartingAt(offset, from) {
        let low  = from;
        let high = this.#lines.length - 1;
        while (low <= high) {
            const middle = (low + high) >> 1;
            const start = this.#sourceStart[middle];
            if (start === offset) return middle;
            if (start < offset) low = middle + 1;
            else high = middle - 1;
        }
        return -1;
    }

    /**
     * What changed between the source the model holds and the one that arrived.
     *
     * A caller that says what it replaced is taken at its word only after the
     * claim is checked against the text that actually arrived. A wrong one is
     * measured instead, which is correct but costs a read of the whole
     * document — so it is also reported, because the only other symptom is a
     * keystroke that is quietly proportional to the document again.
     */
    #editFor(source, change) {
        const previous = this.source;
        if (change !== null) {
            if (
                change.previousSource === previous &&
                previous.length - change.range.length + change.replacement.length === source.length
            ) {
                return {
                    location: change.range.location,
                    removed:  change.range.length,
                    inserted: change.replacement.length,
                };
            }
            noteRejectedChange(change);
        }

        const shared = Math.min(previous.length, source.length);
        let prefix = 0;
        while (prefix < shared && previous.charCodeAt(prefix) === source.charCodeAt(prefix)) {
            prefix += 1;
        }
        let suffix = 0;
        while (
            suffix < shared - prefix &&
            previous.charCodeAt(previous.length - suffix - 1) ===
                source.charCodeAt(source.length - suffix - 1)
        ) {
            suffix += 1;
        }
        return {
            location: prefix,
            removed:  previous.length - prefix - suffix,
            inserted: source.length - prefix - suffix,
        };
    }

    #invalidate() {
        this.#text  = null;
        this.#spans = null;
    }

    /** Parses the whole document from nothing, one line at a time. */
    #reparseAll(source) {
        this.source = source;
        const parser = new Parser(source);
        const lines  = [];
        let location = 0;
        let fence    = null;

        while (location < source.length) {
            const bounds = lineBounds(source, location);
            const line   = parseLine(parser, bounds, fence);
            lines.push(line);
            fence    = line.exitFence;
            location = Math.max(bounds.lineEnd, location + 1);
        }

        this.#lines         = lines;
        this.#sourceStart   = new Array(lines.length);
        this.#renderedStart = new Array(lines.length);
        this.#sourceSpan    = lines.map((line) => line.sourceLength);
        this.#renderedSpan  = lines.map((line) => line.text.length);
        this.#fenceMark     = lines.map(fenceMarkFor);
        this.#fenceOpen     = [];
        this.#fenceClose    = [];
        this.#blockLine     = [];
        this.#blockOfLine   = [];
        this.#dirtyFrom     = -1;
        this.#invalidate();
        this.#reindex(0);
    }

    /**
     * Restates where every line from `from` onwards begins, and which lines
     * the fences run between.
     *
     * Integer arithmetic over an array that is already the right size, so an
     * edit near the top of a long document costs a walk of numbers rather than
     * a walk of the text.
     */
    #reindex(from) {
        const count = this.#lines.length;
        const sourceStart   = this.#sourceStart;
        const renderedStart = this.#renderedStart;
        const sourceSpan    = this.#sourceSpan;
        const renderedSpan  = this.#renderedSpan;
        const fenceMark     = this.#fenceMark;
        sourceStart.length   = count;
        renderedStart.length = count;

        let source   = from === 0 ? 0 : sourceStart[from - 1] + sourceSpan[from - 1];
        let rendered = from === 0 ? 0 : renderedStart[from - 1] + renderedSpan[from - 1];
        for (let index = from; index < count; index += 1) {
            sourceStart[index]   = source;
            renderedStart[index] = rendered;
            source   += sourceSpan[index];
            rendered += renderedSpan[index];
        }

        // Blocks, in the same walk. A line that renders nothing — a fence's
        // own marker — is not a block, and a document that ends in a newline
        // leaves an empty one behind that no line owns.
        const blockLine   = this.#blockLine;
        const blockOfLine = this.#blockOfLine;
        blockOfLine.length = count + 1;
        let block = from === 0 ? 0 : blockOfLine[from];
        for (let index = from; index < count; index += 1) {
            blockOfLine[index] = block;
            if (renderedSpan[index] > 0) {
                blockLine[block] = index;
                block += 1;
            }
        }
        blockOfLine[count] = block;
        blockLine.length = block;
        // Whether the rendered text ends in a newline, which is a question for
        // the last line that rendered anything — the last line of the document
        // may be a fence marker that rendered nothing at all.
        const last = block > 0 ? blockLine[block - 1] : -1;
        if (last !== -1 && this.#lines[last].text.endsWith('\n')) blockLine.push(-1);
        else if (block === 0) blockLine.push(-1);

        let kept = 0;
        while (kept < this.#fenceOpen.length && this.#fenceOpen[kept] < from) kept += 1;
        this.#fenceOpen.length  = kept;
        this.#fenceClose.length = kept;

        // A fence opened above the rebuilt range is still the same fence; only
        // where it ends can have moved.
        let open = kept > 0 && from < count && this.#lines[from].enterFence !== null ? kept - 1 : -1;
        if (open !== -1) this.#fenceClose[open] = -1;

        for (let index = from; index < count; index += 1) {
            const mark = fenceMark[index];
            if (mark === 0) continue;
            if (mark === 1) {
                this.#fenceOpen.push(index);
                this.#fenceClose.push(-1);
                open = this.#fenceOpen.length - 1;
            } else {
                if (open !== -1) this.#fenceClose[open] = index;
                open = -1;
            }
        }
    }
}

/**
 * Replaces `removeCount` lines with `insert`, keeping the numbers that sit
 * beside them in step.
 *
 * The overwhelmingly common edit replaces a line with a line, which is a
 * store rather than a move of everything below it. A whole document arriving
 * at once — an open, or a revision from another device — is rebuilt instead of
 * spliced, because spreading a document's worth of lines into a call is an
 * argument list no engine promises to accept.
 */
function spliceLines(model, start, removeCount, insert) {
    const { lines, sourceSpan, renderedSpan, fenceMark } = model;
    if (removeCount === insert.length) {
        for (let offset = 0; offset < insert.length; offset += 1) {
            const line  = insert[offset];
            const index = start + offset;
            lines[index]        = line;
            sourceSpan[index]   = line.sourceLength;
            renderedSpan[index] = line.text.length;
            fenceMark[index]    = fenceMarkFor(line);
        }
        return;
    }

    if (insert.length <= SPREAD_LIMIT) {
        lines.splice(start, removeCount, ...insert);
        sourceSpan.splice(start, removeCount, ...insert.map((line) => line.sourceLength));
        renderedSpan.splice(start, removeCount, ...insert.map((line) => line.text.length));
        fenceMark.splice(start, removeCount, ...insert.map(fenceMarkFor));
        return;
    }

    const tail = lines.slice(start + removeCount);
    lines.length        = start;
    sourceSpan.length   = start;
    renderedSpan.length = start;
    fenceMark.length    = start;
    for (const line of insert) appendLine(model, line);
    for (const line of tail)   appendLine(model, line);
}

/** How many lines may be spread into one call. */
const SPREAD_LIMIT = 8192;

function appendLine({ lines, sourceSpan, renderedSpan, fenceMark }, line) {
    lines.push(line);
    sourceSpan.push(line.sourceLength);
    renderedSpan.push(line.text.length);
    fenceMark.push(fenceMarkFor(line));
}

function fenceMarkFor(line) {
    if (line.enterFence === null) return line.exitFence === null ? 0 : 1;
    return line.exitFence === null ? 2 : 0;
}

/** One line's parse, in the line's own coordinates. */
function parseLine(parser, bounds, enterFence) {
    const builder = parser.beginLine();
    const step    = parser.renderLineAt(bounds, enterFence);
    return builder.lineRender(
        bounds.lineStart,
        bounds.lineEnd - bounds.lineStart,
        enterFence,
        step.fence,
    );
}

// ─── Public entry point ───────────────────────────────────────────────────────

/**
 * Updates that were given a description of the edit and could not use it.
 *
 * Passing no description at all is ordinary — an undo, an open, or a revision
 * from another device genuinely does not know what moved. Passing one that
 * does not fit the text that arrived is a mistake in the caller, and the only
 * symptom is that every keystroke silently reads the whole document again. So
 * it is counted, and said once.
 */
let rejectedChanges = 0;

/** How many descriptions have been turned down. Exported for tests. */
export function rejectedChangeCount() {
    return rejectedChanges;
}

function noteRejectedChange(change) {
    rejectedChanges += 1;
    if (rejectedChanges > 1 || typeof console === 'undefined') return;
    const wrongShape =
        typeof change.previousSource !== 'string' ||
        typeof change.replacement !== 'string' ||
        typeof change.range?.location !== 'number' ||
        typeof change.range?.length !== 'number';
    console.warn(
        'MarkdownRenderModel.update: the change passed could not be used, so the ' +
        'difference was measured instead — which reads the whole document. ' +
        (wrongShape
            ? `It must be { previousSource, range: { location, length }, replacement }; got { ${Object.keys(change).sort().join(', ')} }.`
            : 'Its `previousSource` is not the source this model holds, or its lengths ' +
              'do not add up to the text that arrived. Pass the change the edit was ' +
              'actually made from, or pass none at all.')
    );
}

/** A model of `markdown`, parsed in full. */
export function renderMarkdown(markdown) {
    return new MarkdownRenderModel(markdown);
}

// ─── RenderBuilder ────────────────────────────────────────────────────────────

class RenderBuilder {
    constructor(source) {
        this._source   = source;
        this._rendered = '';
        this.spans     = [];
        // Both arrays have rendered.length + 1 entries at all times.
        // _lower[i] = the source offset that is the "lower" (earliest) bound for
        //             rendered position i — used for mapping the end of selections.
        // _upper[i] = the source offset that is the "upper" (latest) bound for
        //             rendered position i — used for mapping carets and starts.
        // For literal characters they are equal; they diverge around hidden markup.
        this._lower = [0];
        this._upper = [0];
    }

    get length() { return this._rendered.length; }

    // Appends characters directly from source, recording the exact source offset
    // for each rendered code unit.
    appendSource(range) {
        if (range.length <= 0) {
            this.advanceSource(range.location);
            return;
        }
        this.advanceSource(range.location);
        this._rendered += substringWithRange(this._source, range);
        for (let offset = 1; offset <= range.length; offset++) {
            this._lower.push(range.location + offset);
            this._upper.push(range.location + offset);
        }
    }

    // Appends a synthetic string (not directly from source) and distributes
    // source offsets linearly across its code units.  Used for characters that
    // replace a span of source markup (bullets, task-list markers, images, etc.).
    appendSynthetic(string, sourceRange) {
        this.advanceSource(sourceRange.location);
        const renderedRange = makeRange(this._rendered.length, string.length);
        this._rendered += string;
        for (let offset = 1; offset <= renderedRange.length; offset++) {
            const progress     = offset / renderedRange.length;
            const sourceOffset = sourceRange.location + Math.round(sourceRange.length * progress);
            this._lower.push(sourceOffset);
            this._upper.push(sourceOffset);
        }
        return renderedRange;
    }

    // Updates the upper bound at the current rendered position, effectively
    // recording that the next rendered character starts after `offset` in source.
    // Called before rendering content that follows hidden markup.
    advanceSource(offset) {
        this._upper[this._upper.length - 1] = offset;
    }

    addSpan(style, renderedRange, sourceRange, includesMarkup = false, isAtomic = false) {
        this.spans.push({ style, renderedRange, sourceRange, includesMarkup, isAtomic });
    }

    /**
     * The line's parse, rebased onto the line's own coordinates.
     *
     * Everything the builder recorded is absolute, because the parser reads
     * the real document and has to see the real neighbouring characters. What
     * is stored is relative, because that is what survives the text above it
     * changing length.
     */
    lineRender(lineStart, sourceLength, enterFence, exitFence) {
        const length = this._rendered.length;
        const lower  = new Array(length);
        const upper  = new Array(length);
        for (let offset = 0; offset < length; offset++) {
            lower[offset] = this._lower[offset + 1] - lineStart;
            upper[offset] = this._upper[offset + 1] - lineStart;
        }
        const spans = this.spans;
        for (const span of spans) {
            span.sourceRange = makeRange(span.sourceRange.location - lineStart, span.sourceRange.length);
        }
        return new LineRender(
            sourceLength,
            this._rendered,
            spans,
            lower,
            upper,
            this._upper[0] - lineStart,
            enterFence,
            exitFence,
        );
    }
}

// ─── Block-level regex patterns (compiled once) ───────────────────────────────
// The `d` flag enables result.indices for capture-group positions.
// All patterns are anchored with `^` so exec() matches only at position 0 of
// the extracted line substring.

const HEADING_RE  = /^([ \t]{0,3})(#{1,6})[ \t]+/du;
const QUOTE_RE    = /^([ \t]*>[ \t]?)/du;
const TASK_RE     = /^([ \t]*)([-+*][ \t]+\[([ xX])\])([ \t]+)/du;
const BULLET_RE   = /^([ \t]*)([-+*])([ \t]+)/du;
const NUMBERED_RE = /^([ \t]*)(\d+[.)])([ \t]+)/du;

// ─── Parser ───────────────────────────────────────────────────────────────────

class Parser {
    constructor(source) {
        this._source         = source;
        this._builder        = new RenderBuilder(source);
        this._parsedTokenEnd = 0; // set by _parseCodeSpan / _parseDelimited before returning true
    }

    /** A builder holding one line's output, in that line's own coordinates. */
    beginLine() {
        this._builder = new RenderBuilder(this._source);
        return this._builder;
    }

    /**
     * Renders one line and reports the fence state that follows it.
     *
     * Every other decision the parser makes is confined to the line it is
     * looking at — inline scanning never crosses a newline, and the
     * neighbouring characters it does consult are always the terminators. The
     * fence is the single exception, so it is handed back rather than kept,
     * which is what lets a reparse start in the middle of a document.
     *
     * The fence's own span is not emitted here: it covers many lines, so it
     * belongs to whoever is stitching lines together.
     */
    renderLineAt(bounds, codeFence) {
        const source       = this._source;
        const { lineStart, lineEnd, contentsEnd } = bounds;
        const contentRange = makeRange(lineStart, contentsEnd - lineStart);
        const newlineRange = makeRange(contentsEnd, lineEnd - contentsEnd);
        const line         = source.slice(lineStart, contentsEnd);

        if (codeFence !== null) {
            if (isClosingFence(line, codeFence)) {
                this._builder.advanceSource(lineEnd);
                return { fence: null, opened: false, closed: true };
            }
            const renderedStart = this._builder.length;
            this._builder.appendSource(contentRange);
            this._builder.appendSource(newlineRange);
            this._builder.addSpan(
                codeBlock(codeFence.language),
                makeRange(renderedStart, this._builder.length - renderedStart),
                makeRange(contentRange.location, lineEnd - contentRange.location),
            );
            return { fence: codeFence, opened: false, closed: false };
        }

        const fence = openingFence(line);
        if (fence !== null) {
            this._builder.advanceSource(lineEnd);
            return { fence, opened: true, closed: false };
        }

        this._renderLine(contentRange);
        this._builder.appendSource(newlineRange);
        return { fence: null, opened: false, closed: false };
    }

    _renderLine(lineRange) {
        const source          = this._source;
        const line            = substringWithRange(source, lineRange);
        const renderedLineStart = this._builder.length;

        if (isHorizontalRule(line)) {
            const renderedRange = this._builder.appendSynthetic('—', lineRange);
            this._builder.addSpan(
                horizontalRule, renderedRange, lineRange,
                /*includesMarkup*/ true, /*isAtomic*/ true,
            );
            return;
        }

        let contentStart       = lineRange.location;
        let headingLevel       = null;
        let blockStyle         = null;
        let blockIncludesMarkup = false;

        const headingMatch = matchRegex(HEADING_RE, source, lineRange);
        if (headingMatch !== null) {
            headingLevel       = headingMatch[2].length;
            contentStart       = maxRange(headingMatch[0]);
            blockIncludesMarkup = true;
        } else {
            const quoteMatch = matchRegex(QUOTE_RE, source, lineRange);
            if (quoteMatch !== null) {
                contentStart       = maxRange(quoteMatch[1]);
                blockStyle         = quote;
                blockIncludesMarkup = true;
            }
        }

        const remainingRange = makeRange(contentStart, maxRange(lineRange) - contentStart);
        let listStyle = null;

        const taskMatch = matchRegex(TASK_RE, source, remainingRange);
        if (taskMatch !== null) {
            const markerRange = taskMatch[2];
            const checked     = substringWithRange(source, taskMatch[3]).toLowerCase() === 'x';
            this._builder.advanceSource(markerRange.location);
            const renderedMarker = this._builder.appendSynthetic(checked ? '☑' : '☐', markerRange);
            this._builder.addSpan(taskList(checked), renderedMarker, markerRange, false, /*isAtomic*/ true);
            this._builder.appendSource(taskMatch[4]);
            contentStart = maxRange(taskMatch[0]);
            listStyle    = taskList(checked);
        } else {
            const bulletMatch = matchRegex(BULLET_RE, source, remainingRange);
            if (bulletMatch !== null) {
                this._builder.advanceSource(bulletMatch[2].location);
                const renderedMarker = this._builder.appendSynthetic('•', bulletMatch[2]);
                this._builder.addSpan(bulletedList, renderedMarker, bulletMatch[2], false, /*isAtomic*/ true);
                this._builder.appendSource(bulletMatch[3]);
                contentStart = maxRange(bulletMatch[0]);
                listStyle    = bulletedList;
            } else {
                const numberedMatch = matchRegex(NUMBERED_RE, source, remainingRange);
                if (numberedMatch !== null) {
                    this._builder.advanceSource(numberedMatch[2].location);
                    this._builder.appendSource(numberedMatch[2]);
                    this._builder.appendSource(numberedMatch[3]);
                    contentStart = maxRange(numberedMatch[0]);
                    listStyle    = numberedList;
                }
            }
        }

        this._builder.advanceSource(contentStart);
        const renderedStart = this._builder.length;
        this._renderInline(makeRange(contentStart, maxRange(lineRange) - contentStart));
        const renderedContentRange = makeRange(renderedStart, this._builder.length - renderedStart);

        if (headingLevel !== null) {
            this._builder.addSpan(heading(headingLevel), renderedContentRange, lineRange, blockIncludesMarkup);
        } else if (blockStyle !== null) {
            this._builder.addSpan(blockStyle, renderedContentRange, lineRange, blockIncludesMarkup);
        }

        if (listStyle !== null) {
            const lineRenderedRange = makeRange(renderedLineStart, this._builder.length - renderedLineStart);
            this._builder.addSpan(listStyle, lineRenderedRange, lineRange);
        }
    }

    _renderInline(range) {
        const source = this._source;
        let location = range.location;
        const end    = maxRange(range);

        while (location < end) {
            // Backslash escape: \<punctuation> — the backslash is hidden, the
            // character is rendered, and the whole two-char source span is atomic
            // so selections snap to include the backslash.
            if (source.charCodeAt(location) === 0x5C &&
                location + 1 < end &&
                isMarkdownEscapable(source.charCodeAt(location + 1))
            ) {
                const srcRange = makeRange(location, 2);
                this._builder.advanceSource(location + 1);
                const renderedStart = this._builder.length;
                this._builder.appendSource(makeRange(location + 1, 1));
                this._builder.advanceSource(location + 2);
                this._builder.addSpan(
                    escaped,
                    makeRange(renderedStart, this._builder.length - renderedStart),
                    srcRange,
                    /*includesMarkup*/ true, /*isAtomic*/ true,
                );
                location += 2;
                continue;
            }

            // Image: ![alt](destination) — rendered as one atomic object-replacement char.
            const imgToken = this._linkToken(location, end, /*isImage*/ true);
            if (imgToken !== null) {
                this._builder.advanceSource(imgToken.fullRange.location);
                const renderedRange = this._builder.appendSynthetic('\uFFFC', imgToken.fullRange);
                this._builder.addSpan(
                    image(
                        substringWithRange(source, imgToken.labelRange),
                        substringWithRange(source, imgToken.destinationRange),
                    ),
                    renderedRange, imgToken.fullRange,
                    /*includesMarkup*/ true, /*isAtomic*/ true,
                );
                location = maxRange(imgToken.fullRange);
                continue;
            }

            // HTML image: <img src="…" width="…"> — the only way to express a
            // size, since Markdown has none. Parsed to the same atomic image
            // span so a sized image is still a picture and not a wall of text.
            const htmlImage = this._htmlImageToken(location, end);
            if (htmlImage !== null) {
                this._builder.advanceSource(htmlImage.fullRange.location);
                const renderedRange = this._builder.appendSynthetic('\uFFFC', htmlImage.fullRange);
                this._builder.addSpan(
                    image(
                        htmlImage.altText,
                        htmlImage.destination,
                        htmlImage.width,
                        htmlImage.height,
                    ),
                    renderedRange, htmlImage.fullRange,
                    /*includesMarkup*/ true, /*isAtomic*/ true,
                );
                location = maxRange(htmlImage.fullRange);
                continue;
            }

            // Link: [label](destination) — label is rendered inline, markup hidden.
            const lnkToken = this._linkToken(location, end, /*isImage*/ false);
            if (lnkToken !== null) {
                this._builder.advanceSource(lnkToken.labelRange.location);
                const renderedStart = this._builder.length;
                this._renderInline(lnkToken.labelRange);
                const renderedRange = makeRange(renderedStart, this._builder.length - renderedStart);
                this._builder.advanceSource(maxRange(lnkToken.fullRange));
                this._builder.addSpan(
                    link(substringWithRange(source, lnkToken.destinationRange)),
                    renderedRange, lnkToken.fullRange,
                    /*includesMarkup*/ true,
                );
                location = maxRange(lnkToken.fullRange);
                continue;
            }

            if (this._parseCodeSpan(location, end))                              { location = this._parsedTokenEnd; continue; }
            if (this._parseDelimited('<u>',  '</u>', [underline],      location, end, true)) { location = this._parsedTokenEnd; continue; }
            if (this._parseDelimited('***',  '***',  [bold, italic],   location, end, true)) { location = this._parsedTokenEnd; continue; }
            if (this._parseDelimited('___',  '___',  [bold, italic],   location, end, true)) { location = this._parsedTokenEnd; continue; }
            if (this._parseDelimited('**',   '**',   [bold],           location, end, true)) { location = this._parsedTokenEnd; continue; }
            if (this._parseDelimited('__',   '__',   [bold],           location, end, true)) { location = this._parsedTokenEnd; continue; }
            if (this._parseDelimited('~~',   '~~',   [strikethrough],  location, end, true)) { location = this._parsedTokenEnd; continue; }
            if (this._parseDelimited('*',    '*',    [italic],         location, end, true)) { location = this._parsedTokenEnd; continue; }
            if (this._parseDelimited('_',    '_',    [italic],         location, end, true)) { location = this._parsedTokenEnd; continue; }

            // Plain text run: consume until the next character that could begin a span.
            const runStart = location;
            location += 1;
            while (location < end && !isPotentialInlineMarker(source.charCodeAt(location))) {
                location += 1;
            }
            this._builder.appendSource(makeRange(runStart, location - runStart));
        }
    }

    _parseCodeSpan(location, end) {
        const source = this._source;
        if (source.charCodeAt(location) !== 0x60) return false;

        // Count the opening run of backticks.
        let openLen = 0;
        while (location + openLen < end && source.charCodeAt(location + openLen) === 0x60) {
            openLen++;
        }

        // Search for a closing run of exactly the same length.
        let closingStart = -1;
        let searchAt = location + openLen;
        while (searchAt < end) {
            if (source.charCodeAt(searchAt) !== 0x60) { searchAt++; continue; }
            const runStart = searchAt;
            while (searchAt < end && source.charCodeAt(searchAt) === 0x60) searchAt++;
            if (searchAt - runStart === openLen) { closingStart = runStart; break; }
        }

        if (closingStart === -1 || closingStart <= location + openLen) return false;

        const contentRange = makeRange(location + openLen, closingStart - location - openLen);

        // CommonMark padding rule: if the content starts and ends with a space and
        // is not all-whitespace, strip one leading and one trailing space.
        let displayedRange = contentRange;
        if (contentRange.length >= 2 &&
            source.charCodeAt(contentRange.location) === 0x20 &&
            source.charCodeAt(maxRange(contentRange) - 1) === 0x20 &&
            !isAllWhitespace(substringWithRange(source, contentRange))
        ) {
            displayedRange = makeRange(contentRange.location + 1, contentRange.length - 2);
        }

        const fullRange = makeRange(location, closingStart + openLen - location);
        this._builder.advanceSource(displayedRange.location);
        const renderedStart = this._builder.length;
        this._builder.appendSource(displayedRange);
        const renderedRange = makeRange(renderedStart, this._builder.length - renderedStart);
        this._builder.advanceSource(maxRange(fullRange));
        this._builder.addSpan(inlineCode, renderedRange, fullRange, /*includesMarkup*/ true);
        this._parsedTokenEnd = maxRange(fullRange);
        return true;
    }

    _parseDelimited(opening, closing, styles, location, end, parseContents) {
        const source    = this._source;
        const openLen   = opening.length;

        if (location + openLen >= end) return false;
        if (source.slice(location, location + openLen) !== opening) return false;
        if (!isMaximalRun(source, makeRange(location, openLen), opening)) return false;

        if (usesEmphasisBoundaries(opening)) {
            const nextLoc = location + openLen;
            if (isWhitespaceAt(source, nextLoc)) return false;
            // Underscore between two word characters is intraword, not emphasis.
            if (opening.startsWith('_') &&
                location > 0 &&
                isWordChar(source, location - 1) &&
                isWordChar(source, nextLoc)
            ) {
                return false;
            }
        }

        let closingRange = null;
        let searchAt = location + openLen;

        while (searchAt < end) {
            const ci = source.indexOf(closing, searchAt);
            if (ci === -1 || ci + closing.length > end) break;

            if (isEscaped(source, ci))             { searchAt = ci + closing.length; continue; }
            if (!isMaximalRun(source, makeRange(ci, closing.length), closing)) {
                searchAt = ci + closing.length; continue;
            }

            const nextLoc = ci + closing.length;
            const valid = !usesEmphasisBoundaries(closing) || (
                ci > 0 &&
                !isWhitespaceAt(source, ci - 1) &&
                !(closing.startsWith('_') &&
                  isWordChar(source, ci - 1) &&
                  nextLoc < end &&
                  isWordChar(source, nextLoc))
            );
            if (valid) { closingRange = makeRange(ci, closing.length); break; }
            searchAt = ci + closing.length;
        }

        if (closingRange === null || closingRange.location <= location + openLen) return false;

        const contentRange = makeRange(location + openLen, closingRange.location - location - openLen);
        const fullRange    = makeRange(location, maxRange(closingRange) - location);

        this._builder.advanceSource(contentRange.location);
        const renderedStart = this._builder.length;
        if (parseContents) {
            this._renderInline(contentRange);
        } else {
            this._builder.appendSource(contentRange);
        }
        const renderedRange = makeRange(renderedStart, this._builder.length - renderedStart);
        this._builder.advanceSource(maxRange(fullRange));
        for (const style of styles) {
            this._builder.addSpan(style, renderedRange, fullRange, /*includesMarkup*/ true);
        }
        this._parsedTokenEnd = maxRange(fullRange);
        return true;
    }

    /**
     * `<img …>` — the HTML form, which is the only one that can carry a size.
     * Delegated to `image-tag.js` so the parse and the write stay together.
     */
    _htmlImageToken(location, end) {
        if (this._source.charCodeAt(location) !== 0x3C) return null;   // <
        const tag = parseImageTag(this._source, location, end);
        if (tag === null) return null;
        return { ...tag, fullRange: makeRange(location, tag.end - location) };
    }

    _linkToken(location, end, isImage) {
        const source   = this._source;
        const prefixLen = isImage ? 2 : 1;
        const prefix    = isImage ? '![' : '[';
        if (location + prefixLen >= end) return null;
        if (source.slice(location, location + prefixLen) !== prefix) return null;

        // Scan label, allowing nested brackets and backslash escapes.
        // The condition `scan + 1 < end` ensures we can safely read scan+1 when
        // checking for the `](` terminator pair.
        const labelStart = location + prefixLen;
        let scan  = labelStart;
        let depth = 0;
        let bracketClose = -1;

        while (scan + 1 < end) {
            const ch = source.charCodeAt(scan);
            if (ch === 0x5C) {                       // backslash: skip next char
                scan += Math.min(2, end - scan);
                continue;
            }
            if (ch === 0x5B) { depth++; }             // [
            else if (ch === 0x5D) {                   // ]
                if (depth > 0) {
                    depth--;
                } else if (source.charCodeAt(scan + 1) === 0x28) { // (
                    bracketClose = scan;
                    break;
                }
            }
            scan++;
        }
        if (bracketClose === -1) return null;

        const labelRange = makeRange(labelStart, bracketClose - labelStart);
        const destStart  = bracketClose + 2; // skip ](

        // Angle-bracket form: <url>
        if (destStart < end && source.charCodeAt(destStart) === 0x3C) {
            let s = destStart + 1;
            let esc = false;
            while (s < end) {
                const ch = source.charCodeAt(s);
                if (ch === 0x3E && !esc && s + 1 < end && source.charCodeAt(s + 1) === 0x29) {
                    return {
                        fullRange:        makeRange(location, s + 2 - location),
                        labelRange,
                        destinationRange: makeRange(destStart + 1, s - destStart - 1),
                    };
                }
                esc = (ch === 0x5C) && !esc;
                if (ch !== 0x5C) esc = false;
                s++;
            }
            return null;
        }

        // Balanced-parentheses form
        let destEnd   = destStart;
        let esc       = false;
        let parenDepth = 0;
        while (destEnd < end) {
            const ch = source.charCodeAt(destEnd);
            if (ch === 0x29 && !esc) {   // )
                if (parenDepth === 0) {
                    return {
                        fullRange:        makeRange(location, destEnd + 1 - location),
                        labelRange,
                        destinationRange: makeRange(destStart, destEnd - destStart),
                    };
                }
                parenDepth--;
            } else if (ch === 0x28 && !esc) { // (
                parenDepth++;
            }
            esc = (ch === 0x5C) && !esc;
            if (ch !== 0x5C) esc = false;
            destEnd++;
        }
        return null;
    }
}

// ─── Module-private helpers ───────────────────────────────────────────────────

/**
 * Runs a pre-compiled, `^`-anchored regex against the substring addressed by
 * `range` and returns match group ranges in absolute source coordinates.
 * Returns null when there is no match.  Unmatched optional groups are
 * represented as makeRange(-1, 0).
 */
function matchRegex(regex, source, range) {
    const substring = source.slice(range.location, maxRange(range));
    const result    = regex.exec(substring);
    if (!result) return null;
    return Array.from({ length: result.length }, (_, i) => {
        const idx = result.indices[i];
        return idx === undefined
            ? makeRange(-1, 0)
            : makeRange(range.location + idx[0], idx[1] - idx[0]);
    });
}

function openingFence(line) {
    const trimmed = trimHorizontal(line);
    if (!trimmed.startsWith('```') && !trimmed.startsWith('~~~')) return null;
    const markerChar = trimmed[0];
    let markerLen = 0;
    while (markerLen < trimmed.length && trimmed[markerLen] === markerChar) markerLen++;
    if (markerLen < 3) return null;
    const marker = trimmed.slice(0, markerLen);
    const lang   = trimHorizontal(trimmed.slice(markerLen));
    // A backtick fence whose info string contains a backtick cannot be opened.
    if (markerChar === '`' && lang.includes('`')) return null;
    return { marker, language: lang || null };
}

function isClosingFence(line, fence) {
    const trimmed = trimHorizontal(line);
    if (!trimmed || trimmed[0] !== fence.marker[0]) return false;
    let markerLen = 0;
    while (markerLen < trimmed.length && trimmed[markerLen] === fence.marker[0]) markerLen++;
    if (markerLen < fence.marker.length) return false;
    return trimHorizontal(trimmed.slice(markerLen)) === '';
}

function isHorizontalRule(line) {
    const compact = line.replace(/\s/g, '');
    if (compact.length < 3) return false;
    const first = compact[0];
    if (first !== '-' && first !== '*' && first !== '_') return false;
    return compact.split('').every(ch => ch === first);
}

function isPotentialInlineMarker(code) {
    return code === 0x21 || // !
           code === 0x2A || // *
           code === 0x3C || // <
           code === 0x5B || // [
           code === 0x5C || // \
           code === 0x5F || // _
           code === 0x60 || // `
           code === 0x7E;   // ~
}

function usesEmphasisBoundaries(delimiter) {
    return delimiter.startsWith('*') ||
           delimiter.startsWith('_') ||
           delimiter.startsWith('~');
}

function isWhitespaceAt(source, location) {
    if (location < 0 || location >= source.length) return false;
    return /\s/.test(source[location]);
}

function isWordChar(source, location) {
    if (location < 0 || location >= source.length) return false;
    // Handle surrogate pairs so astral-plane letters/numbers are recognised.
    const code = source.charCodeAt(location);
    const ch   = (code >= 0xD800 && code <= 0xDBFF && location + 1 < source.length)
        ? source.slice(location, location + 2)
        : source[location];
    return /^[\p{L}\p{N}]$/u.test(ch);
}

function isEscaped(source, location) {
    let count = 0;
    let i     = location - 1;
    while (i >= 0 && source.charCodeAt(i) === 0x5C) { count++; i--; }
    return count % 2 === 1;
}

function isMarkdownEscapable(code) {
    return (code >= 0x21 && code <= 0x2F) ||
           (code >= 0x3A && code <= 0x40) ||
           (code >= 0x5B && code <= 0x60) ||
           (code >= 0x7B && code <= 0x7E);
}

// A delimiter run is "maximal" when no adjacent character is the same delimiter.
// If the delimiter itself has mixed characters the check is vacuous.
// Escaped occurrences of the same character do not extend the run.
function isMaximalRun(source, range, delimiter) {
    if (delimiter.length === 0) return true;
    const char = delimiter.charCodeAt(0);
    for (let i = 1; i < delimiter.length; i++) {
        if (delimiter.charCodeAt(i) !== char) return true; // mixed delimiter
    }
    const prevMatches = range.location > 0 &&
        source.charCodeAt(range.location - 1) === char &&
        !isEscaped(source, range.location - 1);
    const nextMatches = maxRange(range) < source.length &&
        source.charCodeAt(maxRange(range)) === char;
    return !prevMatches && !nextMatches;
}

function isAllWhitespace(str) {
    for (let i = 0; i < str.length; i++) {
        if (!/\s/.test(str[i])) return false;
    }
    return true;
}

function trimHorizontal(str) {
    return str.replace(/^[ \t]+|[ \t]+$/g, '');
}
