// How the two storage modes stay out of each other's way.

import { suite, test, expectEqual, expect } from './harness.js';
import { scopedKey, storageChoices, LOCAL, CLOUD } from '../app/storage.js';

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

/**
 * The copy on the welcome screen's storage section (WR-1).
 *
 * These read like tests of wording, and they are, but the wording is the whole
 * safety property: the server's workspace has no accounts, so whoever can open
 * the page can edit whatever is in it. That sentence was previously written on
 * the branch for "the cloud is in use", which is exactly when it does not
 * apply — so the only people who ever saw the warning were the ones it was not
 * about. Anchoring it to the option rather than to the selection is what these
 * assert, in both directions.
 */
suite('Storage choices', () => {
  const local = (options) => storageChoices(options).find((choice) => choice.id === LOCAL);
  const cloud = (options) => storageChoices(options).find((choice) => choice.id === CLOUD);
  const both = [
    { mode: LOCAL, account: null, workspaceName: 'kirupaMarkdown' },
    { mode: CLOUD, account: { email: 'someone@example.com' }, workspaceName: 'kirupaMarkdown' },
  ];

  test('the server workspace warns that anyone reaching the page can edit it', () => {
    for (const options of both) {
      expectEqual(
        local(options).detail,
        'Anyone who can open this page can read and change these documents.'
      );
    }
  });

  test('the warning does not depend on which option is in use', () => {
    expectEqual(local(both[0]).detail, local(both[1]).detail);
  });

  test('exactly one option is in use, and it is the mode passed in', () => {
    expectEqual(local(both[0]).active, true);
    expectEqual(cloud(both[0]).active, false);
    expectEqual(local(both[1]).active, false);
    expectEqual(cloud(both[1]).active, true);
  });

  test('the cloud option is recommended only while it is not the one in use', () => {
    expectEqual(cloud(both[0]).recommended, true);
    expectEqual(cloud(both[1]).recommended, false);
    expect(both.every((options) => local(options).recommended === false),
      'the shared workspace is never recommended');
  });

  test('the signed-in account is named, and never named while signed out', () => {
    expectEqual(cloud(both[1]).title, 'Cloud — someone@example.com');
    expectEqual(cloud(both[0]).title, 'Your Google account');
    expect(!cloud({ ...both[0], account: { email: 'stale@example.com' } }).title.includes('stale'),
      'an account left over from a previous session is not shown as in use');
  });

  test('the action offered is the one that changes something', () => {
    expectEqual(cloud(both[0]).label, 'Connect Google account');
    expectEqual(cloud(both[1]).label, 'Sign out');
    expectEqual(local(both[0]).label, null);
    expectEqual(local(both[1]).label, 'Use local files');
  });

  test('the workspace is still named when the server has not answered yet', () => {
    expectEqual(local({ mode: LOCAL, account: null }).title, 'On this server');
    expectEqual(local(both[0]).title, 'On this server — kirupaMarkdown');
  });
});
