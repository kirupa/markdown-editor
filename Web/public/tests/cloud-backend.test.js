// The cloud backend, exercised end to end against an in-memory Firestore.
//
// Everything the filesystem used to do for the local build is hand-written in
// the cloud backend, so everything the filesystem used to guarantee has to be
// checked here: that a rename carries the images with it, that a folder cannot
// be moved inside itself, that a name collision does not overwrite, and that a
// sibling with a similar name is not swept up by a prefix query.

import { suite, test, expect, expectEqual, expectRejects } from './harness.js';
import { createFirestoreBackend } from '../app/backends/firestore.js';
import {
  createMemoryNodeStore,
  createMemoryAssetStore,
  fileNode,
  folderNode,
  assetNode,
  fakeImage,
} from './support/memory-store.js';

function build(seed = []) {
  const nodes = createMemoryNodeStore(seed);
  const assets = createMemoryAssetStore();
  return { nodes, assets, backend: createFirestoreBackend({ nodes, assets }) };
}

suite('Cloud backend', () => {
  test('writing a document creates every folder above it', async () => {
    const { backend, nodes } = build();
    await backend.write('Trips/2024/Kyoto.md', '# Kyoto');

    expectEqual(nodes.paths(), ['Trips', 'Trips/2024', 'Trips/2024/Kyoto.md']);
    expectEqual((await nodes.read('Trips')).type, 'folder');
    expectEqual((await backend.read('Trips/2024/Kyoto.md')).text, '# Kyoto');
  });

  test('a document size is UTF-8 bytes, not characters', async () => {
    const { backend } = build();
    const written = await backend.write('Café.md', 'café');
    expectEqual(written.size, 5);
    expectEqual((await backend.read('Café.md')).size, 5);
  });

  test('a byte order mark survives a round trip', async () => {
    const { backend } = build();
    await backend.write('Bom.md', 'text', true);
    expectEqual((await backend.read('Bom.md')).hasByteOrderMark, true);
  });

  test('listing a folder puts folders first, then natural order', async () => {
    const { backend } = build([
      fileNode('Zebra.md'), folderNode('Folder 10'), fileNode('apple.md'),
      folderNode('Folder 2'), fileNode('file2.md'), fileNode('file10.md'),
      fileNode('File3.md'),
    ]);
    const listing = await backend.tree('');
    expectEqual(listing.entries.map((entry) => entry.name), [
      'Folder 2', 'Folder 10',
      'apple.md', 'file2.md', 'File3.md', 'file10.md', 'Zebra.md',
    ]);
  });

  test('listing a folder shows only its direct children', async () => {
    const { backend } = build([
      folderNode('Notes'), fileNode('Notes/One.md'),
      folderNode('Notes/Deep'), fileNode('Notes/Deep/Two.md'),
    ]);
    expectEqual((await backend.tree('Notes')).entries.map((e) => e.name), ['Deep', 'One.md']);
  });

  test('ancestors walk from the workspace down to the folder', async () => {
    const { backend } = build([folderNode('A'), folderNode('A/B')]);
    const listing = await backend.tree('A/B');
    expectEqual(listing.ancestors.map((a) => a.name), ['kirupaMarkdown', 'A', 'B']);
    expectEqual(listing.ancestors.map((a) => a.path), ['', 'A', 'A/B']);
  });

  test('reading something that is not there says so instead of returning empty', async () => {
    const { backend } = build();
    await expectRejects(() => backend.read('Missing.md'));
  });

  test('reading a folder, or a non-Markdown file, is refused', async () => {
    const { backend } = build([folderNode('Notes'), fileNode('notes.txt', 'x')]);
    await expectRejects(() => backend.read('Notes'));
    await expectRejects(() => backend.read('notes.txt'));
  });

  test('writing refuses a name that is not Markdown', async () => {
    const { backend } = build();
    await expectRejects(() => backend.write('notes.txt', 'x'));
  });

  test('writing refuses a document past the Firestore limit', async () => {
    const { backend, nodes } = build();
    // The rules refuse this too, but a rules rejection arrives as a bare
    // permission error. The point of the client check is the message.
    await expectRejects(() => backend.write('Huge.md', 'x'.repeat(900_000)));
    expectEqual(await nodes.read('Huge.md'), null, 'nothing was written');
  });

  test('writing counts bytes, not characters, against the limit', async () => {
    const { backend } = build();
    // Every one of these is four UTF-8 bytes, so a document well under the
    // limit in characters is well over it in bytes. A port that measures
    // `length` accepts this and is then refused by the rules.
    await expectRejects(() => backend.write('Emoji.md', '😀'.repeat(240_000)));
  });

  test('writing accepts a document just under the limit', async () => {
    const { backend } = build();
    const written = await backend.write('Big.md', 'x'.repeat(899_999));
    expectEqual(written.size, 899_999, 'size is the UTF-8 byte count');
  });

  test('creating refuses to land on something that already exists', async () => {
    const { backend } = build([fileNode('Ideas.md', 'kept')]);
    await expectRejects(() => backend.create('Ideas.md'));
    expectEqual((await backend.read('Ideas.md')).text, 'kept');
  });

  test('a new folder or document with a taken name is numbered, not merged', async () => {
    const { backend } = build([folderNode('Untitled Folder'), fileNode('Untitled.md')]);
    expectEqual((await backend.newFolder('', 'Untitled Folder')).name, 'Untitled Folder-2');
    expectEqual((await backend.newDocument('', 'Untitled.md')).name, 'Untitled-2.md');
  });

  test('a new document gets an .md extension when it has none', async () => {
    const { backend } = build();
    expectEqual((await backend.newDocument('', 'Plans')).name, 'Plans.md');
  });

  test('renaming a document moves it and leaves nothing behind', async () => {
    const { backend, nodes } = build([fileNode('Notes/Old.md', 'body')]);
    const renamed = await backend.rename('Notes/Old.md', 'New.md');

    expectEqual(renamed.path, 'Notes/New.md');
    expectEqual(await nodes.read('Notes/Old.md'), null);
    expectEqual((await backend.read('Notes/New.md')).text, 'body');
  });

  test('renaming refuses to overwrite an existing sibling', async () => {
    const { backend } = build([fileNode('A.md', 'a'), fileNode('B.md', 'b')]);
    await expectRejects(() => backend.rename('A.md', 'B.md'));
    expectEqual((await backend.read('B.md')).text, 'b');
    expectEqual((await backend.read('A.md')).text, 'a');
  });

  test('renaming a folder brings its whole subtree along', async () => {
    const { backend, nodes } = build([
      folderNode('Old'), folderNode('Old/Deep'), fileNode('Old/Deep/File.md', 'x'),
    ]);
    await backend.rename('Old', 'New');
    expectEqual(nodes.paths(), ['New', 'New/Deep', 'New/Deep/File.md']);
    expectEqual((await nodes.read('New/Deep/File.md')).parent, 'New/Deep');
  });

  test('a similarly named sibling is not dragged along by the prefix query', async () => {
    // "Notes 2" sorts inside the range a naive `path >= 'Notes'` query covers.
    const { backend, nodes } = build([
      folderNode('Notes'), fileNode('Notes/In.md', 'in'),
      folderNode('Notes 2'), fileNode('Notes 2/Out.md', 'out'),
      fileNode('Notes.md', 'sibling'),
    ]);
    await backend.rename('Notes', 'Archive');
    expect(nodes.paths().includes('Notes 2/Out.md'), 'the sibling folder stayed put');
    expect(nodes.paths().includes('Notes.md'), 'the similarly named file stayed put');
    expectEqual((await backend.read('Archive/In.md')).text, 'in');
  });

  test('a folder cannot be moved inside itself', async () => {
    const { backend } = build([folderNode('A'), folderNode('A/B')]);
    await expectRejects(() => backend.move('A', 'A/B'));
    await expectRejects(() => backend.move('A', 'A'));
  });

  test('moving a document into a folder keeps its name', async () => {
    const { backend } = build([fileNode('Ideas.md', 'x'), folderNode('Archive')]);
    expectEqual((await backend.move('Ideas.md', 'Archive')).path, 'Archive/Ideas.md');
  });

  test('deleting removes the whole subtree and its stored image bytes', async () => {
    const { backend, nodes, assets } = build([
      folderNode('Trip'), fileNode('Trip/Day.md', 'x'),
      folderNode('Trip/Day.assets'), assetNode('Trip/Day.assets/a.png', 'k1'),
    ]);
    assets.bytes.set('k1', 'bytes');
    await backend.remove('Trip');

    expectEqual(nodes.paths(), []);
    expectEqual(assets.bytes.has('k1'), false);
  });

  test('duplicating numbers the copy and leaves the original alone', async () => {
    const { backend } = build([fileNode('Ideas.md', 'body')]);
    const copy = await backend.duplicate('Ideas.md');
    expectEqual(copy.name, 'Ideas-2.md');
    expectEqual((await backend.read('Ideas-2.md')).text, 'body');
    expectEqual((await backend.read('Ideas.md')).text, 'body');
  });

  test('duplicating twice keeps counting instead of colliding', async () => {
    const { backend } = build([fileNode('Ideas.md', 'body')]);
    await backend.duplicate('Ideas.md');
    expectEqual((await backend.duplicate('Ideas.md')).name, 'Ideas-3.md');
  });
});

suite('Cloud backend images', () => {
  test('an upload lands in <stem>.assets and returns a usable reference', async () => {
    const { backend, nodes } = build([fileNode('Trips/Kyoto.md', '')]);
    const result = await backend.uploadImage('Trips/Kyoto.md', fakeImage('shrine gate.png'));

    expectEqual(result.path, 'Trips/Kyoto.assets/shrine gate.png');
    expectEqual(result.relativePath, 'Kyoto.assets/shrine%20gate.png');
    expectEqual(result.markdownReference, '![shrine gate](Kyoto.assets/shrine%20gate.png)');
    expectEqual((await nodes.read('Trips/Kyoto.assets')).type, 'folder');
  });

  test('a second image with the same name is numbered, not overwritten', async () => {
    const { backend, assets } = build([fileNode('Kyoto.md', '')]);
    const first = await backend.uploadImage('Kyoto.md', fakeImage('photo.png'));
    const second = await backend.uploadImage('Kyoto.md', fakeImage('photo.png'));

    expectEqual(second.fileName, 'photo-2.png');
    expect(first.path !== second.path, 'the two images are separate documents');
    expectEqual(assets.bytes.size, 2);
  });

  test('a file that is not an image, or is too large, is refused', async () => {
    const { backend } = build([fileNode('Kyoto.md', '')]);
    await expectRejects(() => backend.uploadImage('Kyoto.md', fakeImage('notes.pdf')));
    await expectRejects(() =>
      backend.uploadImage('Kyoto.md', fakeImage('huge.png', { size: 11 * 1024 * 1024 }))
    );
  });

  test('an image of exactly the limit is refused, because the rule refuses it', async () => {
    // `storage.rules` allows `request.resource.size < 10 * 1024 * 1024`, so a
    // file of exactly that size is denied by the server. Letting it past here
    // turns a clear message into a bare permission error, and the Swift build
    // already draws the line in the right place — so this is also the two
    // builds disagreeing with each other.
    const { backend } = build([fileNode('Kyoto.md', '')]);
    await expectRejects(() =>
      backend.uploadImage('Kyoto.md', fakeImage('exact.png', { size: 10 * 1024 * 1024 }))
    );
  });

  test('an image one byte under the limit is still accepted', async () => {
    const { backend } = build([fileNode('Kyoto.md', '')]);
    const added = await backend.uploadImage(
      'Kyoto.md', fakeImage('just-under.png', { size: 10 * 1024 * 1024 - 1 })
    );
    expectEqual(added.fileName, 'just-under.png');
  });

  test('an unsaved document has nowhere to put an image, and says so', async () => {
    const { backend } = build();
    await expectRejects(() => backend.uploadImage('', fakeImage('photo.png')));
  });

  test('reading a document makes its image URLs available synchronously', async () => {
    const { backend } = build([
      fileNode('Kyoto.md', ''), folderNode('Kyoto.assets'),
      assetNode('Kyoto.assets/a.png', 'k1'),
    ]);
    expectEqual(backend.imageURL('Kyoto.assets/a.png'), null);
    await backend.read('Kyoto.md');
    expectEqual(backend.imageURL('Kyoto.assets/a.png'), 'https://storage.test/seed/k1');
  });

  test('renaming a document keeps its images resolvable', async () => {
    const { backend } = build([
      fileNode('Kyoto.md', '![a](Kyoto.assets/a.png)'),
      folderNode('Kyoto.assets'), assetNode('Kyoto.assets/a.png', 'k1'),
    ]);
    await backend.read('Kyoto.md');
    await backend.rename('Kyoto.md', 'Osaka.md');

    // Deliberately no re-read: renaming the open document does not reload it,
    // it just relocates the model in place. The renderer then asks for URLs
    // under the new paths while it builds the DOM, so if the cache still only
    // knows the old ones every image in the document breaks until reload.
    expect(
      backend.imageURL('Osaka.assets/a.png') !== null,
      'the image resolves under its new path'
    );
    expectEqual(backend.imageURL('Kyoto.assets/a.png'), null, 'the old path is gone');
  });

  test('an image with no declared type still uploads as an image', async () => {
    const { backend, assets, nodes } = build([fileNode('Kyoto.md', '')]);
    // Dragging from some applications gives a File with an empty type. The
    // Storage rules accept only image/*, so uploading it as-is would be
    // refused by the server and look, to the user, like nothing happened.
    await backend.uploadImage('Kyoto.md', fakeImage('shot.png', { type: '' }));

    const [storagePath] = [...assets.types.keys()];
    expectEqual(assets.types.get(storagePath), 'image/png', 'type came from the extension');
    expectEqual((await nodes.read('Kyoto.assets/shot.png')).contentType, 'image/png');
  });

  test('a wrong declared type is corrected from the extension', async () => {
    const { backend, assets } = build([fileNode('Kyoto.md', '')]);
    await backend.uploadImage('Kyoto.md', fakeImage('shot.jpg', { type: 'application/octet-stream' }));

    const [storagePath] = [...assets.types.keys()];
    expectEqual(assets.types.get(storagePath), 'image/jpeg');
  });

  test('a declared image type is kept as it is', async () => {
    const { backend, assets } = build([fileNode('Kyoto.md', '')]);
    // jpg maps to image/jpeg, so keeping the browser's answer is visible here.
    await backend.uploadImage('Kyoto.md', fakeImage('shot.jpg', { type: 'image/webp' }));

    const [storagePath] = [...assets.types.keys()];
    expectEqual(assets.types.get(storagePath), 'image/webp');
  });

  test('every accepted extension maps to an image type', async () => {
    const { backend, assets } = build([fileNode('Kyoto.md', '')]);
    const config = await backend.config();
    for (const extension of config.imageExtensions) {
      await backend.uploadImage('Kyoto.md', fakeImage(`shot.${extension}`, { type: '' }));
    }
    // Any extension the picker offers but the map misses would upload as
    // octet-stream and be refused by the rules.
    for (const type of assets.types.values()) {
      expect(type.startsWith('image/'), `${type} is an image type`);
    }
    expectEqual(assets.types.size, config.imageExtensions.length);
  });

  test('renaming a folder keeps the images inside it resolvable', async () => {
    const { backend } = build([
      folderNode('Trips'), fileNode('Trips/Kyoto.md', '![a](Kyoto.assets/a.png)'),
      folderNode('Trips/Kyoto.assets'), assetNode('Trips/Kyoto.assets/a.png', 'k1'),
    ]);
    await backend.read('Trips/Kyoto.md');
    await backend.rename('Trips', 'Journeys');

    // Here the images are inside the moved subtree rather than in a sibling
    // folder, so this is a different code path from renaming the document.
    expect(
      backend.imageURL('Journeys/Kyoto.assets/a.png') !== null,
      'the image resolves under the new folder'
    );
    expectEqual(backend.imageURL('Trips/Kyoto.assets/a.png'), null, 'the old path is gone');
  });

  test('a duplicate resolves to its own copy, and the original is untouched', async () => {
    const { backend, assets } = build([
      fileNode('Kyoto.md', '![a](Kyoto.assets/a.png)'),
      folderNode('Kyoto.assets'), assetNode('Kyoto.assets/a.png', 'k1'),
    ]);
    assets.bytes.set('k1', 'original');
    await backend.read('Kyoto.md');
    const copy = await backend.duplicate('Kyoto.md');

    const originalURL = backend.imageURL('Kyoto.assets/a.png');
    const copyURL = backend.imageURL(`${copy.path.replace(/\.md$/, '')}.assets/a.png`);
    expect(originalURL !== null, 'the original still resolves');
    expect(copyURL !== null, 'the copy resolves too');
    // Copies own their bytes, so sharing a URL would mean deleting one breaks
    // the other.
    expect(copyURL !== originalURL, 'the copy has its own URL');
  });

  test('renaming a document renames its assets folder and its references', async () => {
    const { backend, nodes } = build([
      fileNode('Kyoto.md', 'before ![a](Kyoto.assets/a.png) and ![b](Kyoto.assets/my%20b.png)'),
      folderNode('Kyoto.assets'), assetNode('Kyoto.assets/a.png'),
    ]);
    await backend.rename('Kyoto.md', 'Osaka.md');

    expect(nodes.paths().includes('Osaka.assets/a.png'), 'the image moved with the document');
    expectEqual(await nodes.read('Kyoto.assets'), null);
    expectEqual(
      (await backend.read('Osaka.md')).text,
      'before ![a](Osaka.assets/a.png) and ![b](Osaka.assets/my%20b.png)'
    );
  });

  test('moving a document to another folder takes its images too', async () => {
    const { backend, nodes } = build([
      fileNode('Kyoto.md', '![a](Kyoto.assets/a.png)'),
      folderNode('Kyoto.assets'), assetNode('Kyoto.assets/a.png'),
      folderNode('Archive'),
    ]);
    await backend.move('Kyoto.md', 'Archive');

    expect(nodes.paths().includes('Archive/Kyoto.assets/a.png'), 'the image followed');
    // The folder name did not change, so the reference should not either.
    expectEqual((await backend.read('Archive/Kyoto.md')).text, '![a](Kyoto.assets/a.png)');
  });

  test('a duplicated document gets its own copy of the image bytes', async () => {
    const { backend, nodes, assets } = build([
      fileNode('Kyoto.md', '![a](Kyoto.assets/a.png)'),
      folderNode('Kyoto.assets'), assetNode('Kyoto.assets/a.png', 'k1'),
    ]);
    assets.bytes.set('k1', 'original');
    const copy = await backend.duplicate('Kyoto.md');

    expectEqual(copy.name, 'Kyoto-2.md');
    expectEqual((await backend.read('Kyoto-2.md')).text, '![a](Kyoto-2.assets/a.png)');

    const copied = await nodes.read('Kyoto-2.assets/a.png');
    expect(copied.storagePath !== 'k1', 'the copy points at its own bytes');
    expectEqual(assets.bytes.get(copied.storagePath), 'original');

    // Deleting the copy must not blank the original.
    await backend.remove('Kyoto-2.assets');
    expectEqual(assets.bytes.get('k1'), 'original');
  });

  test('deleting a document leaves its images behind, as the local build does', async () => {
    const { backend, nodes } = build([
      fileNode('Kyoto.md', ''), folderNode('Kyoto.assets'), assetNode('Kyoto.assets/a.png'),
    ]);
    await backend.remove('Kyoto.md');
    expect(nodes.paths().includes('Kyoto.assets/a.png'), 'the image is still recoverable');
  });
});
