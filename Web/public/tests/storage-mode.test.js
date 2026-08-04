// How the two storage modes stay out of each other's way.

import { suite, test, expectEqual, expect } from './harness.js';
import { scopedKey, LOCAL, CLOUD } from '../app/storage.js';

suite('Storage modes', () => {
  test('local keeps the original keys, so an existing install keeps its recents', () => {
    expectEqual(scopedKey('markdown-editor.recents', LOCAL), 'markdown-editor.recents');
    expectEqual(scopedKey('markdown-editor.savedForLater', LOCAL), 'markdown-editor.savedForLater');
  });

  test('cloud gets its own keys, because a path means a different document there', () => {
    expectEqual(scopedKey('markdown-editor.recents', CLOUD), 'markdown-editor.recents.cloud');
    expect(
      scopedKey('markdown-editor.recents', CLOUD) !== scopedKey('markdown-editor.recents', LOCAL),
      'the two modes never share a list'
    );
  });
});
