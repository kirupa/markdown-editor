import { suite, test, expect, expectEqual } from './harness.js';
import { renderMarkdown } from '../app/core/render-model.js';
import { makeRange, substringWithRange } from '../app/core/range.js';

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
