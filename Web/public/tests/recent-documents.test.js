import { suite, test, expect, expectEqual } from './harness.js';
import {
  DISPLAY_LIMIT,
  STORED_LIMIT,
  entries,
  isMarkdownPath,
  merged,
  promoting,
  removing,
  standardizePath,
} from '../app/core/recent-documents.js';

suite('Recent documents catalog', () => {
  test('Merging keeps preferred order and removes duplicates', () => {
    const result = merged(
      ['a.md', 'b.md'],
      ['b.md', 'c.md']
    );
    expectEqual(result, ['a.md', 'b.md', 'c.md']);
  });

  test('Merging drops paths that are not Markdown', () => {
    const result = merged(['notes.txt', 'a.md', 'image.png', 'b.markdown']);
    expectEqual(result, ['a.md', 'b.markdown']);
  });

  test('Merging stops at the limit', () => {
    const result = merged(['a.md', 'b.md', 'c.md'], [], 2);
    expectEqual(result, ['a.md', 'b.md']);
  });

  test('A non-positive limit yields nothing', () => {
    expectEqual(merged(['a.md'], [], 0), []);
  });

  test('Promoting moves an existing entry to the front', () => {
    const result = promoting('c.md', ['a.md', 'b.md', 'c.md']);
    expectEqual(result, ['c.md', 'a.md', 'b.md']);
  });

  test('Promoting inserts an entry that was not present', () => {
    const result = promoting('z.md', ['a.md']);
    expectEqual(result, ['z.md', 'a.md']);
  });

  test('Removing deletes every spelling of a path', () => {
    const result = removing('notes/a.md', ['notes/a.md', 'b.md', './notes//a.md']);
    expectEqual(result, ['b.md']);
  });

  test('Standardizing collapses redundant separators', () => {
    expectEqual(standardizePath('./notes//a.md'), 'notes/a.md');
    expectEqual(standardizePath('/a.md'), 'a.md');
    expectEqual(standardizePath(''), '');
  });

  test('Markdown detection is case insensitive and extension exact', () => {
    expect(isMarkdownPath('A.MD'));
    expect(isMarkdownPath('a.Markdown'));
    expect(!isMarkdownPath('a.mdx'));
    expect(!isMarkdownPath('markdown'));
  });

  test('Entries split the name from the containing folder', () => {
    const result = entries(['notes/ideas.md', 'top.md'], 'Docs');
    expectEqual(result, [
      { path: 'notes/ideas.md', name: 'ideas.md', folderDisplayPath: 'Docs/notes' },
      { path: 'top.md', name: 'top.md', folderDisplayPath: 'Docs' },
    ]);
  });

  test('Entries stop at the display limit', () => {
    const paths = Array.from({ length: 20 }, (_, index) => `file-${index}.md`);
    expectEqual(entries(paths, 'Docs').length, DISPLAY_LIMIT);
  });

  test('Limits match the macOS build', () => {
    expectEqual(STORED_LIMIT, 40);
    expectEqual(DISPLAY_LIMIT, 12);
  });
});
