// Path arithmetic for the cloud workspace.
//
// These exist because the cloud backend has to reach the *same* answers the
// PHP build reaches from a real filesystem. Where a rule was ported rather
// than invented, the test names say which local behaviour it is matching.

import { suite, test, expect, expectEqual, expectThrows } from './harness.js';
import * as paths from '../app/cloud/paths.js';

suite('Cloud paths', () => {
  test('normalizing strips leading, trailing, and doubled separators', () => {
    expectEqual(paths.normalize('/Notes//Ideas.md/'), 'Notes/Ideas.md');
    expectEqual(paths.normalize(''), '');
    expectEqual(paths.normalize('./Notes/./Ideas.md'), 'Notes/Ideas.md');
  });

  test('normalizing accepts a backslash separator', () => {
    expectEqual(paths.normalize('Notes\\Ideas.md'), 'Notes/Ideas.md');
  });

  test('normalizing refuses "..", which would break path identity', () => {
    expectThrows(() => paths.normalize('Notes/../Ideas.md'));
    expectThrows(() => paths.normalize('../secrets.md'));
  });

  test('name, parent, stem, and extension split the same way PATHINFO does', () => {
    expectEqual(paths.nameOf('Notes/Ideas.md'), 'Ideas.md');
    expectEqual(paths.parentOf('Notes/Ideas.md'), 'Notes');
    expectEqual(paths.parentOf('Ideas.md'), '');
    expectEqual(paths.stemOf('Ideas.md'), 'Ideas');
    expectEqual(paths.stemOf('archive.tar.gz'), 'archive.tar');
    expectEqual(paths.extensionOf('Ideas.MD'), 'md');
    expectEqual(paths.extensionOf('README'), '');
  });

  test('a leading dot is an extension, exactly as PATHINFO has it', () => {
    // Verified against PHP rather than assumed: pathinfo('.gitignore') gives
    // filename '' and extension 'gitignore'. Surprising, but matching it is
    // what keeps the two storage modes agreeing on names.
    expectEqual(paths.stemOf('.gitignore'), '');
    expectEqual(paths.extensionOf('.gitignore'), 'gitignore');
    expectEqual(paths.stemOf('x.'), 'x');
    expectEqual(paths.extensionOf('x.'), '');
  });

  test('only .md and .markdown are Markdown', () => {
    expect(paths.isMarkdown('Ideas.md'));
    expect(paths.isMarkdown('Ideas.markdown'));
    expect(!paths.isMarkdown('Ideas.txt'));
    expect(!paths.isMarkdown('Notes'));
  });

  test('joining ignores an empty parent and an empty name', () => {
    expectEqual(paths.join('', 'Ideas.md'), 'Ideas.md');
    expectEqual(paths.join('Notes', 'Ideas.md'), 'Notes/Ideas.md');
    expectEqual(paths.join('Notes', ''), 'Notes');
  });

  test('the assets folder is named after the document stem (I-1)', () => {
    expectEqual(paths.assetsFolderName('Notes/Trip.md'), 'Trip.assets');
    expectEqual(paths.assetsFolderName('Trip.markdown'), 'Trip.assets');
  });

  test('ancestors run from the workspace root down, root included', () => {
    expectEqual(paths.ancestorsOf('A/B/C.md', 'kirupaMarkdown'), [
      { name: 'kirupaMarkdown', path: '' },
      { name: 'A', path: 'A' },
      { name: 'B', path: 'A/B' },
      { name: 'C.md', path: 'A/B/C.md' },
    ]);
    expectEqual(paths.ancestorsOf('', 'kirupaMarkdown'), [
      { name: 'kirupaMarkdown', path: '' },
    ]);
  });

  test('a folder does not claim a similarly named sibling', () => {
    // The local build has the same test: deleting "Notes" must not take
    // "Notes archive" with it.
    expect(paths.isDescendantOf('Notes/Ideas.md', 'Notes'));
    expect(!paths.isDescendantOf('Notes archive/Ideas.md', 'Notes'));
    expect(!paths.isDescendantOf('Notes', 'Notes'));
  });

  test('everything is a descendant of the root', () => {
    expect(paths.isDescendantOf('Ideas.md', ''));
    expect(!paths.isDescendantOf('', ''));
  });

  test('rewriting repoints a subtree and leaves everything else alone', () => {
    expectEqual(paths.rewrite('A/B/C.md', 'A', 'Z'), 'Z/B/C.md');
    expectEqual(paths.rewrite('A', 'A', 'Z'), 'Z');
    expectEqual(paths.rewrite('A2/B.md', 'A', 'Z'), 'A2/B.md');
    expectEqual(paths.rewrite('A/B.md', 'A', 'X/Y'), 'X/Y/B.md');
  });

  test('rewriting out of the root moves a top-level item into a folder', () => {
    expectEqual(paths.rewrite('Ideas.md', 'Ideas.md', 'Notes/Ideas.md'), 'Notes/Ideas.md');
  });

  test('folders sort ahead of files, then naturally (X-6, X-7, X-8)', () => {
    const entries = [
      { name: 'Zebra.md', isExpandable: false },
      { name: 'Folder 10', isExpandable: true },
      { name: 'apple.md', isExpandable: false },
      { name: 'Folder 2', isExpandable: true },
    ];
    expectEqual(
      [...entries].sort(paths.compareEntries).map((entry) => entry.name),
      ['Folder 2', 'Folder 10', 'apple.md', 'Zebra.md']
    );
  });

  test('a duplicate is named stem-2.ext, matching FileManager::nextAvailable', () => {
    expectEqual(paths.nextAvailableName(['Ideas.md'], 'Ideas.md'), 'Ideas-2.md');
    expectEqual(
      paths.nextAvailableName(['Ideas.md', 'Ideas-2.md'], 'Ideas.md'),
      'Ideas-3.md'
    );
    expectEqual(paths.nextAvailableName(['Notes'], 'Notes'), 'Notes-2');
  });

  test('a duplicate keeps the extension it had, including its case', () => {
    expectEqual(paths.nextAvailableName(['Photo.PNG'], 'Photo.PNG'), 'Photo-2.PNG');
  });

  test('duplicating takes only the name into account, not the folder', () => {
    expectEqual(paths.nextAvailableName(['Ideas.md'], 'Notes/Ideas.md'), 'Ideas-2.md');
  });

  test('percent-encoding matches ImageImporter::encodeComponent', () => {
    // Unreserved characters survive; everything else becomes uppercase hex.
    expectEqual(paths.encodeComponent('a-b._~c'), 'a-b._~c');
    expectEqual(paths.encodeComponent('my photo.png'), 'my%20photo.png');
    expectEqual(paths.encodeComponent('Trip.assets'), 'Trip.assets');
  });

  test('percent-encoding is per byte, so non-ASCII becomes several escapes', () => {
    expectEqual(paths.encodeComponent('café.png'), 'caf%C3%A9.png');
    expectEqual(paths.encodeComponent('Folder 2'), 'Folder%202');
  });

  test('splitting agrees with PHP on every case that was actually run there', () => {
    // Captured from pathinfo() itself, not from reading the manual.
    const fromPhp = {
      'Ideas.md': ['Ideas', 'md'],
      'archive.tar.gz': ['archive.tar', 'gz'],
      '.gitignore': ['', 'gitignore'],
      README: ['README', ''],
      'Photo.PNG': ['Photo', 'png'],
      'a-b._~c': ['a-b', '_~c'],
      'x.': ['x', ''],
      'Trip.assets': ['Trip', 'assets'],
    };
    for (const [name, [stem, extension]] of Object.entries(fromPhp)) {
      expectEqual(paths.stemOf(name), stem, `stem of ${name}`);
      expectEqual(paths.extensionOf(name), extension, `extension of ${name}`);
    }
  });

  test('an image reference escapes alt text so a filename cannot break it (I-10)', () => {
    expectEqual(
      paths.markdownImageReference('a [b] c', 'X.assets/y.png'),
      '![a \\[b\\] c](X.assets/y.png)'
    );
    expectEqual(
      paths.markdownImageReference('back\\slash', 'X.assets/y.png'),
      '![back\\\\slash](X.assets/y.png)'
    );
  });

  test('a document ID round trips and never contains a slash', () => {
    const id = paths.documentId('Notes/Sub folder/Ideas.md');
    expect(!id.includes('/'), id);
    expectEqual(paths.pathFromDocumentId(id), 'Notes/Sub folder/Ideas.md');
  });

  test('the workspace root is not a document', () => {
    expectThrows(() => paths.documentId(''));
  });

  test('ancestor folders list the folders a document needs, outermost first', () => {
    expectEqual(paths.ancestorFolders('A/B/C.md'), ['A', 'A/B']);
    expectEqual(paths.ancestorFolders('C.md'), []);
  });
});
