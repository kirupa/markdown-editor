import {
    makeRange,
    maxRange,
    intersectionRange,
    substringWithRange,
    lineBounds,
} from './range.js';

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
export function image(altText, destination) { return { kind: 'image', altText, destination }; }
export const horizontalRule = Object.freeze({ kind: 'horizontalRule' });
export const escaped        = Object.freeze({ kind: 'escaped' });

// ─── MarkdownRenderModel ──────────────────────────────────────────────────────

export class MarkdownRenderModel {
    #lower; // lowerSourceOffsets: one entry per rendered boundary
    #upper; // upperSourceOffsets: one entry per rendered boundary

    constructor(text, spans, lowerSourceOffsets, upperSourceOffsets) {
        this.text  = text;
        this.spans = spans;
        this.#lower = lowerSourceOffsets;
        this.#upper = upperSourceOffsets;
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
        const renderedLength = this.text.length;
        const location = Math.min(Math.max(0, renderedRange.location), renderedLength);
        const length   = Math.min(Math.max(0, renderedRange.length), renderedLength - location);
        const clamped  = makeRange(location, length);

        if (clamped.length === 0) {
            return makeRange(this.#upper[location], 0);
        }

        let sourceStart = this.#upper[location];
        let sourceEnd   = this.#lower[maxRange(clamped)];

        for (const span of this.spans) {
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
        const renderedStart = this.#renderedOffset(sourceStart, this.#upper);
        if (sourceRange.length === 0) {
            return makeRange(renderedStart, 0);
        }
        const renderedEnd = this.#renderedOffset(sourceEnd, this.#lower);
        return makeRange(renderedStart, Math.max(0, renderedEnd - renderedStart));
    }

    // Linear forward scan: first rendered index whose mapped source offset >= target.
    #renderedOffset(target, offsets) {
        for (let i = 0; i < offsets.length; i++) {
            if (offsets[i] >= target) return i;
        }
        return Math.max(0, offsets.length - 1);
    }
}

// ─── Public entry point ───────────────────────────────────────────────────────

export function renderMarkdown(markdown) {
    return new Parser(markdown).render();
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

    model() {
        return new MarkdownRenderModel(
            this._rendered,
            this.spans,
            this._lower,
            this._upper,
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

    render() {
        const source = this._source;
        let location  = 0;
        let codeFence = null; // { marker, language, sourceStart, renderedStart }

        while (location < source.length) {
            const { lineStart, lineEnd, contentsEnd } = lineBounds(source, location);
            const contentRange = makeRange(lineStart, contentsEnd - lineStart);
            const newlineRange = makeRange(contentsEnd, lineEnd - contentsEnd);
            const line         = source.slice(lineStart, contentsEnd);

            if (codeFence !== null) {
                if (isClosingFence(line, codeFence)) {
                    this._builder.advanceSource(lineEnd);
                    this._builder.addSpan(
                        codeBlock(codeFence.language),
                        makeRange(codeFence.renderedStart, this._builder.length - codeFence.renderedStart),
                        makeRange(codeFence.sourceStart,  lineEnd - codeFence.sourceStart),
                        /*includesMarkup*/ true,
                    );
                    codeFence = null;
                } else {
                    const renderedStart = this._builder.length;
                    this._builder.appendSource(contentRange);
                    this._builder.appendSource(newlineRange);
                    this._builder.addSpan(
                        codeBlock(codeFence.language),
                        makeRange(renderedStart, this._builder.length - renderedStart),
                        makeRange(contentRange.location, lineEnd - contentRange.location),
                    );
                }
            } else {
                const fence = openingFence(line);
                if (fence !== null) {
                    this._builder.advanceSource(lineEnd);
                    codeFence = {
                        marker:        fence.marker,
                        language:      fence.language,
                        sourceStart:   lineStart,
                        renderedStart: this._builder.length,
                    };
                } else {
                    this._renderLine(contentRange);
                    this._builder.appendSource(newlineRange);
                }
            }

            location = Math.max(lineEnd, location + 1);
        }

        // Unclosed fence: emit everything from the opening line to EOF as a code block.
        if (codeFence !== null) {
            this._builder.addSpan(
                codeBlock(codeFence.language),
                makeRange(codeFence.renderedStart, this._builder.length - codeFence.renderedStart),
                makeRange(codeFence.sourceStart, source.length - codeFence.sourceStart),
                /*includesMarkup*/ true,
            );
        }

        this._builder.advanceSource(source.length);
        return this._builder.model();
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
