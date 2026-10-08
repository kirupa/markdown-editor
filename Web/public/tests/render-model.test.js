import { suite, test, expect, expectEqual } from './harness.js';
import { renderMarkdown, MarkdownRenderModel } from '../app/core/render-model.js';
import { makeRange, maxRange, substringWithRange } from '../app/core/range.js';

// Mirrors `(text as NSString).range(of: substring)`.
function findRange(text, substring) {
    const loc = text.indexOf(substring);
    if (loc === -1) throw new Error(`substring not found: ${JSON.stringify(substring)}`);
    return makeRange(loc, substring.length);
}

suite('Markdown render model', () => {
    test('Common block and inline Markdown renders without syntax', () => {
        const source = `# Title

- **Bold** and _italic_
1. [Link](https://example.com)
- [x] Done
> Quote`;

        const model = renderMarkdown(source);

        expectEqual(model.text, `Title

\u2022 Bold and italic
1. Link
\u2611 Done
Quote`);
        expect(model.spans.some(s => s.style.kind === 'heading' && s.style.level === 1));
        expect(model.spans.some(s => s.style.kind === 'bold'));
        expect(model.spans.some(s => s.style.kind === 'italic'));
        expect(model.spans.some(s => s.style.kind === 'bulletedList'));
        expect(model.spans.some(s => s.style.kind === 'numberedList'));
        expect(model.spans.some(s => s.style.kind === 'taskList' && s.style.checked === true));
        expect(model.spans.some(s => s.style.kind === 'quote'));
        expect(model.spans.some(s =>
            s.style.kind === 'link' && s.style.destination === 'https://example.com'
        ));
    });

    test('Inline style content selection excludes its delimiters', () => {
        const source = 'Before **bold** after';
        const model = renderMarkdown(source);
        const renderedSelection = findRange(model.text, 'bold');
        const sourceSelection = model.sourceRange(renderedSelection);

        expectEqual(substringWithRange(source, sourceSelection), 'bold');
        expectEqual(
            substringWithRange(source, model.sourceRange(renderedSelection, true)),
            '**bold**',
        );
    });

    test('Selecting a heading preserves its block marker', () => {
        const source = '# Title';
        const model = renderMarkdown(source);
        const renderedSelection = findRange(model.text, 'Title');
        expectEqual(substringWithRange(source, model.sourceRange(renderedSelection)), 'Title');
    });

    test('Partial inline edit maps only content', () => {
        const source = 'Before **bold** after';
        const model = renderMarkdown(source);
        const renderedSelection = findRange(model.text, 'ol');
        const sourceSelection = model.sourceRange(renderedSelection);
        expectEqual(substringWithRange(source, sourceSelection), 'ol');
    });

    test('Deleting final styled character excludes closing delimiter', () => {
        const source = '**bold**';
        const model = renderMarkdown(source);
        const renderedRange = findRange(model.text, 'd');
        const sourceRange = model.sourceRange(renderedRange);
        expectEqual(substringWithRange(source, sourceRange), 'd');
    });

    test('Empty link does not absorb adjacent visual selection', () => {
        const source = '[](https://example.com)x';
        const model = renderMarkdown(source);
        const renderedRange = findRange(model.text, 'x');
        const sourceRange = model.sourceRange(renderedRange);
        expectEqual(substringWithRange(source, sourceRange), 'x');
    });

    test('Visual edit updates source without dropping surrounding markup', () => {
        const source = 'Before **bold** after';
        const model = renderMarkdown(source);
        const renderedSelection = findRange(model.text, 'ol');
        const sourceSelection = model.sourceRange(renderedSelection);
        const editedSource =
            source.slice(0, sourceSelection.location) +
            'XX' +
            source.slice(sourceSelection.location + sourceSelection.length);

        expectEqual(editedSource, 'Before **bXXd** after');
        expectEqual(renderMarkdown(editedSource).text, 'Before bXXd after');
    });

    test('Source selection inside markup maps back to rendered content', () => {
        const source = '**bold**';
        const model = renderMarkdown(source);
        const renderedSelection = model.renderedRange(makeRange(2, 4));
        expectEqual(substringWithRange(model.text, renderedSelection), 'bold');
    });

    test('Source caret remains a rendered caret across hidden markup', () => {
        const heading   = renderMarkdown('# Title');
        const emptyCode = renderMarkdown('```\n\n```');

        expectEqual(heading.renderedRange(makeRange(2, 0)), makeRange(0, 0));
        expect(emptyCode.renderedRange(makeRange(4, 0)).length === 0);
    });

    test('Image renders as one atomic placeholder', () => {
        const source = 'A ![Photo](Post.assets/photo.png) here';
        const model = renderMarkdown(source);
        const attachmentRange = findRange(model.text, '\uFFFC');

        expect(attachmentRange.length === 1);
        expectEqual(
            model.sourceRange(attachmentRange),
            findRange(source, '![Photo](Post.assets/photo.png)'),
        );
        expect(model.spans.some(s =>
            s.style.kind === 'image' &&
            s.style.altText === 'Photo' &&
            s.style.destination === 'Post.assets/photo.png'
        ));
    });

    // Markdown has no syntax for image dimensions, so a sized image is written
    // as HTML — the same reason `<u>` is the underline. It has to parse back to
    // an image span, or sizing one would turn it into a wall of raw text.
    test('An HTML image tag renders as an image, not as text', () => {
        const source = 'A <img src="Post.assets/photo.png" alt="Photo" width="300" height="200"> here';
        const model = renderMarkdown(source);
        const attachmentRange = findRange(model.text, '\uFFFC');

        expectEqual(model.text, 'A \uFFFC here');
        expectEqual(
            model.sourceRange(attachmentRange),
            findRange(source, '<img src="Post.assets/photo.png" alt="Photo" width="300" height="200">'),
        );
        expect(model.spans.some(s =>
            s.style.kind === 'image' &&
            s.style.altText === 'Photo' &&
            s.style.destination === 'Post.assets/photo.png' &&
            s.style.width === 300 &&
            s.style.height === 200
        ), 'the size is carried on the span');
    });

    test('An image tag parses whatever order and quoting it is written in', () => {
        const model = renderMarkdown(`<img width=300 alt='A "quoted" name' src="a.png"/>`);
        const span = model.spans.find(s => s.style.kind === 'image');
        expectEqual(model.text, '\uFFFC');
        expectEqual(span.style.destination, 'a.png');
        expectEqual(span.style.altText, 'A "quoted" name');
        expectEqual(span.style.width, 300);
        expectEqual(span.style.height, null, 'a height that was not given stays absent');
    });

    test('A Markdown image has no size', () => {
        const model = renderMarkdown('![Photo](a.png)');
        const span = model.spans.find(s => s.style.kind === 'image');
        expectEqual(span.style.width, null);
        expectEqual(span.style.height, null);
    });

    test('Tags that are not images are still literal text', () => {
        // Only `<img>` is understood. Everything else stays text, as before.
        const source = '<div>x</div> and <imgx src="a.png"> and <img>';
        const model = renderMarkdown(source);
        expectEqual(model.text, source, 'nothing was swallowed');
        expect(!model.spans.some(s => s.style.kind === 'image'), 'and no image was invented');
    });

    test('An image tag with no source is left as text', () => {
        // Without a `src` there is nothing to draw, and replacing it with an
        // empty box would lose text the author can still see and fix.
        const source = '<img alt="nothing" width="10">';
        const model = renderMarkdown(source);
        expectEqual(model.text, source);
    });

    test('Sizes that are not positive whole numbers are ignored', () => {
        // `width="50%"` is legal HTML this editor cannot represent as a number,
        // so the image still renders — it just has no size to show in the panel.
        const model = renderMarkdown('<img src="a.png" width="50%" height="-4">');
        const span = model.spans.find(s => s.style.kind === 'image');
        expectEqual(span.style.width, null);
        expectEqual(span.style.height, null);
    });

    test('Balanced parentheses remain inside link destinations', () => {
        const source = '[Docs](https://example.com/a_(b))';
        const model = renderMarkdown(source);
        expectEqual(model.text, 'Docs');
        expect(model.spans.some(s =>
            s.style.kind === 'link' &&
            s.style.destination === 'https://example.com/a_(b)'
        ));
    });

    test('Nested and escaped brackets remain in link label', () => {
        const source = '[a \\[bracket\\] and [nested]](https://example.com)';
        const model = renderMarkdown(source);
        expectEqual(model.text, 'a [bracket] and [nested]');
        expect(model.spans.some(s =>
            s.style.kind === 'link' && s.style.destination === 'https://example.com'
        ));
    });

    test('Fenced code hides fences and preserves code', () => {
        const source = '```swift\nlet value = 1\n```\n';
        const model = renderMarkdown(source);
        expectEqual(model.text, 'let value = 1\n');
        expect(model.spans.some(s =>
            s.style.kind === 'codeBlock' &&
            s.style.language === 'swift' &&
            s.includesMarkup
        ));
    });

    test('Longer fence can close a shorter opening fence', () => {
        const source = '```\ncode\n````\n';
        expectEqual(renderMarkdown(source).text, 'code\n');
    });

    test('Backticks in fence info do not open a code block', () => {
        const source = '```foo```\n';
        const model = renderMarkdown(source);
        expectEqual(model.text, 'foo\n');
        expect(!model.spans.some(s => s.style.kind === 'codeBlock'));
    });

    test('Code span closer must be an exact maximal run', () => {
        const source = '`a``';
        expectEqual(renderMarkdown(source).text, source);
    });

    test('Code span padding preserves edge backticks', () => {
        const source = '`` `foo ``';
        expectEqual(renderMarkdown(source).text, '`foo');
    });

    test('Underline strike code and rule render', () => {
        const source = '<u>under</u> ~~strike~~ `code` ``a`b``\n---';
        const model = renderMarkdown(source);
        expectEqual(model.text, 'under strike code a`b\n\u2014');
        expect(model.spans.some(s => s.style.kind === 'underline'));
        expect(model.spans.some(s => s.style.kind === 'strikethrough'));
        expect(model.spans.some(s => s.style.kind === 'inlineCode'));
        expect(model.spans.some(s => s.style.kind === 'horizontalRule'));
    });

    test('Nested bold does not close surrounding italic', () => {
        const source = '*foo **bar** baz*';
        const model = renderMarkdown(source);
        expectEqual(model.text, 'foo bar baz');
        expect(model.spans.some(s => s.style.kind === 'bold'));
        expect(model.spans.some(s => s.style.kind === 'italic'));
    });

    test('Unknown Markdown remains visible and editable', () => {
        const source = 'Text ==highlight==, snake_case_value, and <mark>tag</mark>';
        const model = renderMarkdown(source);
        expectEqual(model.text, source);
        expectEqual(
            model.sourceRange(makeRange(0, model.text.length)),
            makeRange(0, source.length),
        );
    });

    test('Escaped Markdown maps back to its escape marker', () => {
        const source = 'Literal \\* character';
        const model = renderMarkdown(source);
        const renderedSelection = findRange(model.text, '*');
        expectEqual(model.text, 'Literal * character');
        expectEqual(
            substringWithRange(source, model.sourceRange(renderedSelection)),
            '\\*',
        );
    });

    test('Backslashes before letters remain visible', () => {
        const source = 'Path C:\\Users\\Kirupa';
        expectEqual(renderMarkdown(source).text, source);
    });

    test('Unicode intraword underscores are not emphasis', () => {
        const source = 'caf\u00e9_value_';
        expectEqual(renderMarkdown(source).text, source);
    });

    test('Escaped emphasis delimiter stays in styled content', () => {
        const source = '*a\\**';
        const model = renderMarkdown(source);
        expectEqual(model.text, 'a*');
        expect(model.spans.some(s => s.style.kind === 'italic'));
    });
});

// ─── Editing through the rendered view ────────────────────────────────────────
// What `contract-edits.test.js` checks against the Swift, stated as behaviour.

/** Makes an edit to the rendered text the way the editor does. */
function editRendered(source, renderedRange, replacement, model = renderMarkdown(source)) {
    const range = model.sourceRangeReplacing(renderedRange, replacement);
    return {
        source: source.slice(0, range.location) + replacement + source.slice(maxRange(range)),
        caret: range.location + replacement.length,
    };
}

/** Every line break in the rendered text, removed the three ways the contract removes it. */
function lineBreakEdits(text) {
    const edits = [];
    let lineStart = 0;
    for (let index = 0; index < text.length; index += 1) {
        if (text[index] !== '\n') continue;
        edits.push([makeRange(index, 1), '']);
        edits.push([makeRange(index, 1), 'x']);
        edits.push([makeRange(lineStart, index + 1 - lineStart), '']);
        lineStart = index + 1;
    }
    return edits;
}

suite('Editing through the rendered view', () => {
    // The shape of the bug report: a quote, an empty heading line, a paragraph.
    const REPORT = '> **Note**\n> A quote.\n## \nLet\'s go.';

    test('⌫ on an empty heading line under a quote leaves no marker behind', () => {
        const model = renderMarkdown(REPORT);
        const emptyLine = model.text.indexOf('\n\n') + 1;
        const { source, caret } = editRendered(REPORT, makeRange(emptyLine - 1, 1), '', model);
        expectEqual(source, '> **Note**\n> A quote.\nLet\'s go.');
        const after = renderMarkdown(source);
        expectEqual(after.text, 'Note\nA quote.\nLet\'s go.');
        // At the end of the quote, where the line that went used to begin.
        expectEqual(after.renderedRange(makeRange(caret, 0)).location, emptyLine - 1);
    });

    test('⌫ at the start of the line below takes the empty heading line whole', () => {
        const model = renderMarkdown(REPORT);
        const below = model.text.indexOf('Let');
        const { source } = editRendered(REPORT, makeRange(below - 1, 1), '', model);
        expectEqual(source, '> **Note**\n> A quote.\nLet\'s go.');
        expect(!renderMarkdown(source).spans.some((s) => s.style.kind === 'heading'),
            'the paragraph that moved up became a heading');
    });

    test('a heading joined onto the paragraph above carries on as that paragraph', () => {
        const { source } = editRendered('Intro\n## Heading', makeRange(5, 1), '');
        expectEqual(source, 'IntroHeading');
    });

    test('only the line marker goes: the joined line keeps its inline markup', () => {
        const { source } = editRendered('Intro\n> **Bold** rest', makeRange(5, 1), '');
        expectEqual(source, 'Intro**Bold** rest');
    });

    test('a heading marker inside a fence is code, and a join keeps it', () => {
        const source = '```\nfirst\n## not a heading\n```\n';
        expectEqual(renderMarkdown(source).text, 'first\n## not a heading\n');
        expectEqual(editRendered(source, makeRange(5, 1), '').source,
            '```\nfirst## not a heading\n```\n');
    });

    test('Return over a line break is never adjusted', () => {
        const model = renderMarkdown('Intro\n## Heading');
        expectEqual(model.sourceRangeReplacing(makeRange(5, 1), '\n'),
            model.sourceRange(makeRange(5, 1)));
    });

    test('an edit that does not end at the start of a line maps as it always did', () => {
        const model = renderMarkdown('# Title\n\nSome **bold** text.\n> quote\n');
        const length = model.text.length;
        for (let location = 0; location <= length; location += 1) {
            for (const span of [0, 1, 3]) {
                const range = makeRange(location, Math.min(span, length - location));
                if (range.length > 0 && model.text[maxRange(range) - 1] === '\n') continue;
                for (const replacement of ['', 'x', '\n']) {
                    expectEqual(model.sourceRangeReplacing(range, replacement),
                        model.sourceRange(range),
                        `[${range.location},${range.length}] with ${JSON.stringify(replacement)}`);
                }
            }
        }
    });

    // The editor asks the model it keeps up to date, never a fresh one.
    test('a model updated in place answers as one parsed from nothing', () => {
        let source = 'Intro\n\n> quote\n## \nAfter\n';
        const model = new MarkdownRenderModel(source);
        const edits = [
            { at: 0, insert: '> ' },                    // the first line becomes a quote
            { at: source.length + 2, insert: '## ' },   // a heading at the end
            { at: 2, insert: '```\ncode\n```\n' },      // a fence above everything
            { at: 0, remove: 5 },                       // and part of it gone again
        ];
        for (const [step, edit] of edits.entries()) {
            const next =
                source.slice(0, edit.at) + (edit.insert ?? '') + source.slice(edit.at + (edit.remove ?? 0));
            model.update(next, step % 2 === 0
                ? {
                    previousSource: source,
                    range: makeRange(edit.at, edit.remove ?? 0),
                    replacement: edit.insert ?? '',
                }
                : null);
            source = next;
            const fresh = renderMarkdown(source);
            expectEqual(model.text, fresh.text, `text after edit ${step + 1}`);
            for (const [range, replacement] of lineBreakEdits(fresh.text)) {
                expectEqual(model.sourceRangeReplacing(range, replacement),
                    fresh.sourceRangeReplacing(range, replacement),
                    `edit ${step + 1}, [${range.location},${range.length}] ` +
                        `with ${JSON.stringify(replacement)} in ${JSON.stringify(source)}`);
            }
        }
    });
});
