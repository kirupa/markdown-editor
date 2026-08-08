// The one place that knows how an image with a size is written.
//
// Markdown cannot express a width or a height. Every syntax that tries is an
// extension of one renderer or another, and the two common ones both fail
// where it matters: `![alt](a.png =300x200)` is not recognised by GitHub, which
// renders the whole thing as literal text and loses the picture entirely, and
// `![alt|300x200](a.png)` keeps the picture but ignores the size everywhere
// except Obsidian and puts the digits in the alt text, where a screen reader
// reads them out.
//
// So a sized image is written as HTML — `<img src="a.png" width="300">` — which
// GitHub, VS Code, pandoc and the static site generators all honour. That is the
// same reasoning that already makes `<u>` the underline in this editor: reach
// for HTML exactly where Markdown has no syntax, and nowhere else.
//
// An image with no size stays `![alt](a.png)`. Plain Markdown is the common
// case and it stays plain; the HTML appears only when it buys something.

/** Attributes are parsed and written here and nowhere else. */
const TAG_START = '<img';

/**
 * Reads an `<img …>` tag starting at `location`.
 *
 * @returns {{ end: number, destination: string, altText: string,
 *             width: number|null, height: number|null } | null}
 *   `null` when this is not an image tag, or is one with no `src` — a tag with
 *   nothing to draw is left as text, because replacing it with an empty box
 *   would hide something the author can still see and correct.
 */
export function parseImageTag(source, location, end = source.length) {
    if (source.slice(location, location + TAG_START.length).toLowerCase() !== TAG_START) {
        return null;
    }
    // `<imgx>` is a different element that happens to share a prefix.
    const afterName = source.charCodeAt(location + TAG_START.length);
    if (!isSpace(afterName) && afterName !== 0x2F && afterName !== 0x3E) return null;

    const attributes = new Map();
    let scan = location + TAG_START.length;
    // A tag is only a tag once it is closed. Without this, text that merely
    // begins like one — `Check <img src="a.png" in the docs` — would be
    // swallowed to the end of the line.
    let closed = false;

    while (scan < end) {
        while (scan < end && isSpace(source.charCodeAt(scan))) scan += 1;
        if (scan >= end) return null;

        const ch = source.charCodeAt(scan);
        if (ch === 0x3E) {                                   // >
            scan += 1;
            closed = true;
            break;
        }
        if (ch === 0x2F) {                                   // / — self-closing
            scan += 1;
            continue;
        }

        const nameStart = scan;
        while (scan < end && isAttributeName(source.charCodeAt(scan))) scan += 1;
        if (scan === nameStart) return null;                 // not an attribute
        const name = source.slice(nameStart, scan).toLowerCase();

        while (scan < end && isSpace(source.charCodeAt(scan))) scan += 1;
        if (source.charCodeAt(scan) !== 0x3D) {              // valueless attribute
            attributes.set(name, '');
            continue;
        }
        scan += 1;
        while (scan < end && isSpace(source.charCodeAt(scan))) scan += 1;

        const quote = source.charCodeAt(scan);
        let value;
        if (quote === 0x22 || quote === 0x27) {              // " or '
            const close = source.indexOf(String.fromCharCode(quote), scan + 1);
            if (close === -1 || close >= end) return null;
            value = source.slice(scan + 1, close);
            scan = close + 1;
        } else {
            const valueStart = scan;
            while (scan < end && !isSpace(source.charCodeAt(scan)) &&
                   source.charCodeAt(scan) !== 0x3E) {
                scan += 1;
            }
            if (scan === valueStart) return null;
            value = source.slice(valueStart, scan);
        }
        attributes.set(name, decodeEntities(value));
    }

    if (!closed) return null;

    const destination = attributes.get('src') ?? '';
    if (destination === '') return null;

    return {
        end: scan,
        destination,
        altText: attributes.get('alt') ?? '',
        width: pixelCount(attributes.get('width')),
        height: pixelCount(attributes.get('height')),
    };
}

/**
 * Writes the reference for an image, choosing the form by whether it has a size.
 *
 * This is the only function that decides between the two forms, so the rule
 * "HTML only when it buys something" lives in one place: give an image a size
 * and it becomes HTML, clear the size and it goes back to being Markdown.
 */
export function imageReference({ destination, altText = '', width = null, height = null }) {
    const w = pixelCount(width);
    const h = pixelCount(height);
    if (w === null && h === null) return markdownImageReference(altText, destination);

    let tag = `<img src="${escapeAttribute(destination)}" alt="${escapeAttribute(altText)}"`;
    if (w !== null) tag += ` width="${w}"`;
    if (h !== null) tag += ` height="${h}"`;
    return `${tag}>`;
}

/**
 * `![alt](destination)`, with the label escaped and the destination encoded so
 * the result round-trips.
 *
 * The encoding matters most when converting back from the HTML form: an HTML
 * attribute happily holds `my file.png`, but the same text in Markdown is not
 * an image at all — GitHub renders it as literal text and the picture is lost.
 * `encodeDestination` is idempotent, so an already-encoded path is unharmed.
 */
export function markdownImageReference(altText, destination) {
    return `![${escapeLabel(altText)}](${encodeDestination(destination)})`;
}

/** Escape the characters that would otherwise end a `[…]` label early. */
export function escapeLabel(text) {
    return String(text)
        .replace(/\\/g, '\\\\')
        .replace(/\[/g, '\\[')
        .replace(/\]/g, '\\]');
}

/**
 * Percent-encode the characters that would end an inline destination early.
 * Shared by links and images so a URL behaves the same in both.
 */
export function encodeDestination(destination) {
    return String(destination)
        .replace(/\\/g, '%5C')
        .replace(/ /g, '%20')
        .replace(/\(/g, '%28')
        .replace(/\)/g, '%29')
        .replace(/</g, '%3C')
        .replace(/>/g, '%3E');
}

/**
 * A width and a height that keep the shape of `natural`.
 *
 * Whichever of the two the author last typed is the one that is honoured
 * exactly; the other is derived. Rounding is deliberately kept away from zero,
 * so a very wide, very short image never derives a height of 0 and vanishes.
 */
export function proportionalSize({ width, height, natural, edited = 'width' }) {
    const naturalWidth = pixelCount(natural?.width);
    const naturalHeight = pixelCount(natural?.height);
    const w = pixelCount(width);
    const h = pixelCount(height);

    if (naturalWidth === null || naturalHeight === null) return { width: w, height: h };

    if (edited === 'width') {
        if (w === null) return { width: null, height: null };
        return { width: w, height: Math.max(1, Math.round(w * naturalHeight / naturalWidth)) };
    }
    if (h === null) return { width: null, height: null };
    return { width: Math.max(1, Math.round(h * naturalWidth / naturalHeight)), height: h };
}

// ── Private helpers ──────────────────────────────────────────────────────────

/**
 * A size this editor can show in a number field, or null.
 *
 * `width="50%"` is legal HTML that has no pixel count, and `width="-4"` is not a
 * size at all. Both leave the image rendering exactly as it would otherwise —
 * they only mean there is no number to put in the panel, so nothing the author
 * wrote by hand is quietly rewritten.
 */
function pixelCount(value) {
    if (value === null || value === undefined || value === '') return null;
    if (typeof value === 'number') {
        return Number.isFinite(value) && value >= 1 ? Math.round(value) : null;
    }
    if (!/^\d+$/.test(String(value).trim())) return null;
    const number = Number.parseInt(String(value).trim(), 10);
    return number >= 1 ? number : null;
}

function isSpace(code) {
    return code === 0x20 || code === 0x09 || code === 0x0A || code === 0x0D || code === 0x0C;
}

function isAttributeName(code) {
    return !isSpace(code) && code !== 0x3D && code !== 0x3E && code !== 0x2F &&
           !Number.isNaN(code);
}

/** The five named entities that matter inside an attribute, plus numeric ones. */
function decodeEntities(value) {
    if (!value.includes('&')) return value;
    return value
        .replace(/&#(\d+);/g, (_, digits) => safeCodePoint(Number.parseInt(digits, 10)))
        .replace(/&#[xX]([0-9a-fA-F]+);/g, (_, hex) => safeCodePoint(Number.parseInt(hex, 16)))
        .replace(/&quot;/g, '"')
        .replace(/&apos;/g, "'")
        .replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>')
        .replace(/&amp;/g, '&');
}

function safeCodePoint(number) {
    if (!Number.isFinite(number) || number < 0 || number > 0x10FFFF) return '';
    try {
        return String.fromCodePoint(number);
    } catch {
        return '';
    }
}

function escapeAttribute(value) {
    return String(value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}
