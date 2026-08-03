import { suite, test, expect, expectEqual } from './harness.js';
import {
  adding,
  contains,
  normalized,
  relocating,
  removing,
  removingUnder,
  toggling,
} from '../app/core/saved-documents.js';

suite('Saved documents', () => {
  test('Adding puts the newest first', () => {
    expectEqual(adding('b.md', ['a.md']), ['b.md', 'a.md']);
  });

  test('Adding something already saved leaves the order alone', () => {
    // Ticking an already-ticked checkbox must not reorder the list under
    // whoever is reading it.
    expectEqual(adding('c.md', ['a.md', 'b.md', 'c.md']), ['a.md', 'b.md', 'c.md']);
  });

  test('Only Markdown documents can be saved', () => {
    expectEqual(adding('notes.txt', ['a.md']), ['a.md']);
    expectEqual(adding('photo.png', []), []);
    expectEqual(adding('', ['a.md']), ['a.md']);
  });

  test('Both Markdown extensions are accepted', () => {
    expectEqual(adding('b.markdown', ['a.md']), ['b.markdown', 'a.md']);
  });

  test('Containment compares standardized paths', () => {
    expect(contains('Notes/a.md', ['Notes//a.md']));
    expect(contains('./Notes/a.md', ['Notes/a.md']));
    expect(!contains('Notes/b.md', ['Notes/a.md']));
    expect(!contains('', ['a.md']));
  });

  test('Removing takes out every spelling', () => {
    expectEqual(removing('Notes/a.md', ['Notes//a.md', 'b.md', './Notes/a.md']), ['b.md']);
  });

  test('Toggling adds when absent and removes when present', () => {
    expectEqual(toggling('a.md', []), ['a.md']);
    expectEqual(toggling('a.md', ['a.md']), []);
  });

  test('Reading normalizes a list that was tampered with', () => {
    // localStorage is editable by hand, so a duplicate or a stray non-Markdown
    // entry must not reach the UI.
    expectEqual(normalized(['a.md', 'a.md', 'x.txt', '', 'Notes//b.md']), ['a.md', 'Notes/b.md']);
    expectEqual(normalized(null), []);
  });

  test('A renamed document keeps its place in the list', () => {
    expectEqual(
      relocating('b.md', 'renamed.md', ['a.md', 'b.md', 'c.md']),
      ['a.md', 'renamed.md', 'c.md']
    );
  });

  test('A move out of the workspace, or to a non-Markdown name, drops the entry', () => {
    expectEqual(relocating('b.md', 'b.txt', ['a.md', 'b.md']), ['a.md']);
    expectEqual(relocating('b.md', '', ['a.md', 'b.md']), ['a.md']);
  });

  test('Relocating something that is not saved changes nothing', () => {
    expectEqual(relocating('z.md', 'y.md', ['a.md']), ['a.md']);
  });

  test('Relocating onto a path already saved does not duplicate it', () => {
    expectEqual(relocating('b.md', 'a.md', ['a.md', 'b.md']), ['a.md']);
  });

  test('Deleting a folder drops the documents underneath it', () => {
    expectEqual(
      removingUnder('Notes', ['Notes/a.md', 'Notes/deep/b.md', 'Other/c.md']),
      ['Other/c.md']
    );
  });

  test('A folder does not take a similarly named sibling with it', () => {
    // "Notes2/a.md" starts with "Notes", which is exactly the bug a naive
    // prefix test would ship.
    expectEqual(removingUnder('Notes', ['Notes2/a.md', 'Notes/b.md']), ['Notes2/a.md']);
  });
});
