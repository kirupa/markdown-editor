// Runs the app's real cloud store against a real Firestore, and against the
// double every other cloud test uses.
//
//     Web/firebase/run-cloud-checks.sh
//
// The suite's cloud tests are deliberately built on an in-memory Firestore:
// that is what makes the backend's decisions testable without a network, and
// it is the right design. It has one cost, recorded honestly in the web PRD
// for a long time -- nothing had ever checked that the double behaves like
// Firestore. Every one of those tests is only as good as that assumption, and
// the assumption was never tested.
//
// This tests it. `Web/public/tests/support/memory-store.js` and the shipped
// `app/cloud/firestore-store.js` expose the same four-method node store, so
// the same sequences can go through both and the answers compared. Where they
// differ on purpose, the difference is asserted rather than smoothed over.
//
// Two things here cannot be done against the live project and are the reason
// the emulator earns its keep:
//
//   - Live updates. `watchChildren` and `watchNode` had only ever run against
//     the double, which announces changes synchronously from the same object
//     that stored them. Real delivery involves a server, a local echo that
//     must be skipped, and an attach snapshot. Two independent SDK clients on
//     one emulator make that a genuine two-device test.
//   - The range query in `subtreeOf`. Its filter exists because the query
//     over-matches; that is a claim about Firestore, and only Firestore can
//     confirm it.

import { readFile } from 'node:fs/promises';
import { suite, test, expect, expectEqual, runAll } from '../public/tests/harness.js';
import { createMemoryNodeStore } from '../public/tests/support/memory-store.js';
import { createFirestoreNodeStore } from '../public/app/cloud/firestore-store.js';
import { loadFirebase } from '../public/app/cloud/sdk.js';
import { NODES_COLLECTION, USERS_COLLECTION } from '../public/app/cloud/config.js';

const FIRESTORE_HOST = process.env.MDE_FIRESTORE_HOST ?? '127.0.0.1:8481';
const AUTH_HOST = process.env.MDE_AUTH_HOST ?? 'http://127.0.0.1:9481';

// --- connecting ------------------------------------------------------------

/**
 * The app's own `loadFirebase`, pointed at the emulators.
 *
 * `loadFirebase` caches, so this is the one place the emulator connection can
 * be made and it covers every later `createFirestoreNodeStore`. Connecting
 * redirects all traffic to localhost; nothing here can reach the real project.
 * The published rules are the backstop if that were ever wrong -- an
 * unauthenticated write to the real database is refused, which
 * `check-rules.mjs` verifies.
 */
const firebase = await loadFirebase();
const [host, port] = FIRESTORE_HOST.split(':');
firebase.firestore.connectFirestoreEmulator(firebase.db, host, Number(port));
firebase.auth.connectAuthEmulator(firebase.authentication, AUTH_HOST, { disableWarnings: true });

const signedIn = await firebase.auth.signInAnonymously(firebase.authentication);
const uid = signedIn.user.uid;

/**
 * A second, independent SDK client for the same account.
 *
 * This is the other device. It has its own app, its own Firestore instance and
 * its own local cache, so a write through it reaches the first client the way
 * a change made on a phone reaches a laptop -- through the server, with no
 * shared object in between.
 */
const other = firebase.app.initializeApp({ ...firebase.instance.options }, 'second-device');
const otherDb = firebase.firestore.getFirestore(other);
firebase.firestore.connectFirestoreEmulator(otherDb, host, Number(port));
const otherAuth = firebase.auth.getAuth(other);
firebase.auth.connectAuthEmulator(otherAuth, AUTH_HOST, { disableWarnings: true });
await firebase.auth.signInWithCustomToken(
  otherAuth,
  await mintTokenFor(uid)
).catch(async () => {
  // The emulator will mint a custom token for an existing uid; if that path is
  // unavailable, fall back to signing the second client in as the same user by
  // reusing the first client's credential.
  await firebase.auth.updateCurrentUser(otherAuth, signedIn.user);
});

/** A custom token for an existing uid, which only the emulator will hand out. */
async function mintTokenFor(subject) {
  // The Auth emulator accepts an unsigned custom token: the signature is not
  // checked. This is how a second client signs in as the same account without
  // a service account key.
  const header = Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })).toString('base64url');
  const body = Buffer.from(
    JSON.stringify({
      iss: 'firebase-auth-emulator@example.com',
      sub: 'firebase-auth-emulator@example.com',
      aud: 'https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit',
      iat: Math.floor(Date.now() / 1000),
      exp: Math.floor(Date.now() / 1000) + 3600,
      uid: subject,
    })
  ).toString('base64url');
  return `${header}.${body}.`;
}

// --- fixtures --------------------------------------------------------------

const node = (path, extra = {}) => ({
  type: 'file',
  path,
  parent: path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : '',
  name: path.slice(path.lastIndexOf('/') + 1),
  ...extra,
});

const folder = (path) => node(path, { type: 'folder' });

/**
 * The trap `subtreeOf` exists to avoid: three paths that all begin with the
 * five characters "Notes", of which only two belong to the folder.
 */
const CORPUS = [
  folder('Notes'),
  node('Notes/A.md', { text: 'a' }),
  node('Notes/Deep/B.md', { text: 'b' }),
  folder('Notes 2'),
  node('Notes 2/Out.md', { text: 'out' }),
  node('Notes.md', { text: 'sibling' }),
];

/** A clean pair of stores, real and double, holding the same corpus. */
async function stores(corpus = CORPUS) {
  const real = await createFirestoreNodeStore(uid);
  const double = createMemoryNodeStore();

  // The real store keeps whatever earlier checks wrote, so clear it first.
  const existing = await real.subtreeOf('');
  if (existing.length) {
    await real.commit(existing.map((row) => ({ path: row.path, remove: true })));
  }

  const writes = corpus.map((data) => ({ path: data.path, data }));
  await real.commit(writes);
  await double.commit(writes);
  return { real, double };
}

/** Comparable regardless of the order a query happened to return rows in. */
const byPath = (rows) => rows.map((row) => row.path).sort();

const sameRows = (a, b, what) =>
  expectEqual(byPath(a).join('|'), byPath(b).join('|'), what);

// --- the queries -----------------------------------------------------------

suite('The real store and the double answer alike', () => {
  test('a subtree stops at the folder boundary in both', async () => {
    const { real, double } = await stores();
    const fromReal = await real.subtreeOf('Notes');
    const fromDouble = await double.subtreeOf('Notes');
    sameRows(fromReal, fromDouble, 'subtreeOf("Notes")');
    expectEqual(
      byPath(fromReal).join('|'),
      'Notes|Notes/A.md|Notes/Deep/B.md',
      'the subtree should be the folder and its descendants only'
    );
  });

  test('the range query really does over-match, so the filter is load-bearing', async () => {
    // `subtreeOf` filters the rows the range query returns, with a comment
    // saying the range alone would catch "Notes 2" and "Notes.md". If that
    // were not true the filter would be dead code and nobody would know.
    // Issue the bare range and look.
    const { collection, getDocs, query, where } = firebase.firestore;
    const nodes = collection(firebase.db, USERS_COLLECTION, uid, NODES_COLLECTION);
    const snapshot = await getDocs(
      query(nodes, where('path', '>=', 'Notes'), where('path', '<', `Notes\uf8ff`))
    );
    const matched = snapshot.docs.map((entry) => entry.data().path).sort();
    expect(
      matched.includes('Notes 2/Out.md') && matched.includes('Notes.md'),
      `the bare range should have over-matched, returned ${matched.join(', ')}`
    );
  });

  test('a folder listing agrees in both', async () => {
    const { real, double } = await stores();
    sameRows(await real.childrenOf(''), await double.childrenOf(''), 'childrenOf("")');
    sameRows(await real.childrenOf('Notes'), await double.childrenOf('Notes'), 'childrenOf("Notes")');
  });

  test('a read returns the same fields in both, and null for what is absent', async () => {
    const { real, double } = await stores();
    const fromReal = await real.read('Notes/A.md');
    const fromDouble = await double.read('Notes/A.md');
    expectEqual(JSON.stringify(fromReal), JSON.stringify(fromDouble), 'read of Notes/A.md');
    expectEqual(await real.read('Nothing.md'), null, 'read of an absent path');
    expectEqual(await double.read('Nothing.md'), null, 'read of an absent path in the double');
  });

  test('a delete and a create in one commit leave the same state in both', async () => {
    const { real, double } = await stores();
    const writes = [
      { path: 'Notes/C.md', data: node('Notes/C.md', { text: 'c' }) },
      { path: 'Notes/A.md', remove: true },
    ];
    await real.commit(writes);
    await double.commit(writes);
    sameRows(await real.subtreeOf('Notes'), await double.subtreeOf('Notes'), 'after a mixed commit');
  });
});

// --- the parts only a real Firestore has ----------------------------------

suite('Firestore behaves as the store assumes', () => {
  test('a commit larger than one batch is applied whole', async () => {
    // BATCH_LIMIT is 500 because Firestore refuses a larger batch. A subtree
    // can exceed it, and the chunking had never met a real Firestore.
    //
    // What this proves is that chunking loses and duplicates nothing. It does
    // *not* prove the limit, because the emulator does not enforce it --
    // measured, it accepts 613 writes in a single batch where production
    // refuses more than 500. The limit itself is guarded by the check below.
    const real = await createFirestoreNodeStore(uid);
    const existing = await real.subtreeOf('Big');
    if (existing.length) {
      await real.commit(existing.map((row) => ({ path: row.path, remove: true })));
    }
    const many = Array.from({ length: 611 }, (_, index) =>
      node(`Big/${String(index).padStart(4, '0')}.md`, { text: 'x' })
    );
    await real.commit([{ path: 'Big', data: folder('Big') }, ...many.map((data) => ({ path: data.path, data }))]);
    const back = await real.subtreeOf('Big');
    expectEqual(back.length, 612, 'every node in a multi-batch commit should be present');
  });

  test('the batch size the store chunks to is one Firestore will accept', async () => {
    // Read out of the source rather than repeated here, so this cannot drift
    // from what the store does. It exists because the emulator will not catch
    // a raised limit: it accepts any batch, so the functional check above
    // passes at any value and production would fail at 501.
    const source = await readFile(
      new URL('../public/app/cloud/firestore-store.js', import.meta.url),
      'utf8'
    );
    const match = source.match(/const BATCH_LIMIT = (\d+);/);
    expect(match !== null, 'BATCH_LIMIT should still be a literal in firestore-store.js');
    expect(
      Number(match[1]) <= 500,
      `Firestore refuses a batch over 500 writes; BATCH_LIMIT is ${match?.[1]}`
    );
  });

  test('a batch is refused whole when one write in it breaks the rules', async () => {
    // The ordering argument in `commit` -- creates before the deletes they
    // replace, so an interruption duplicates rather than loses -- rests on a
    // batch being atomic. Check that a batch really is.
    const real = await createFirestoreNodeStore(uid);
    await real.commit([{ path: 'Atomic/keep.md', data: node('Atomic/keep.md', { text: 'k' }) }]);
    let refused = false;
    try {
      await real.commit([
        { path: 'Atomic/one.md', data: node('Atomic/one.md', { text: '1' }) },
        // No `name`, which the rules require.
        { path: 'Atomic/two.md', data: { type: 'file', path: 'Atomic/two.md', parent: 'Atomic' } },
      ]);
    } catch {
      refused = true;
    }
    expect(refused, 'a batch containing an invalid write should have been refused');
    expectEqual(await real.read('Atomic/one.md'), null, 'the valid write in a refused batch');
  });

  test('the rules the double transcribes are the rules the server applies', async () => {
    // The double refuses malformed writes by transcribing the rules. If the
    // transcription were wrong in the permissive direction, tests would pass
    // on writes the server rejects. Put the same bad write through both.
    const real = await createFirestoreNodeStore(uid);
    const double = createMemoryNodeStore();
    const bad = { path: 'Bad.md', data: { type: 'script', path: 'Bad.md', parent: '', name: 'Bad.md' } };

    let realRefused = false;
    let doubleRefused = false;
    try { await real.commit([bad]); } catch { realRefused = true; }
    try { await double.commit([bad]); } catch { doubleRefused = true; }
    expect(realRefused, 'the server should have refused a node of type "script"');
    expectEqual(doubleRefused, realRefused, 'the double should agree with the server');
  });
});

// --- live updates, across two clients -------------------------------------

/** Resolves on the first delivery that satisfies `matches`, or rejects. */
function nextDelivery(subscribe, matches, what, timeout = 8000) {
  return new Promise((resolve, reject) => {
    let unsubscribe = () => {};
    const timer = setTimeout(() => {
      unsubscribe();
      reject(new Error(`timed out waiting for ${what}`));
    }, timeout);
    unsubscribe = subscribe((value) => {
      if (!matches(value)) return;
      clearTimeout(timer);
      // Unsubscribing inside the callback is what the app does when a folder
      // closes, so it is worth exercising here too.
      setTimeout(unsubscribe, 0);
      resolve(value);
    });
  });
}

/** Writes through the *other* client, so the change arrives via the server. */
async function writeFromOtherDevice(data) {
  const { doc, setDoc, collection } = firebase.firestore;
  const nodes = collection(otherDb, USERS_COLLECTION, uid, NODES_COLLECTION);
  await setDoc(doc(nodes, encodeURIComponent(data.path)), data);
}

suite('Live updates arrive from another device', () => {
  test('watching a folder delivers what is already there', async () => {
    // The attach snapshot. Two hazards in the live-update work were found
    // because the double delivers one; this confirms Firestore does too.
    const real = await createFirestoreNodeStore(uid);
    await stores();
    const rows = await nextDelivery(
      (listener) => real.watchChildren('Notes', listener),
      (value) => value.length > 0,
      'the attach snapshot for Notes'
    );
    expect(
      rows.some((row) => row.path === 'Notes/A.md'),
      'the attach snapshot should contain what the folder already holds'
    );
  });

  test("a folder listener sees another device's new document", async () => {
    const real = await createFirestoreNodeStore(uid);
    await stores();
    const arrival = nextDelivery(
      (listener) => real.watchChildren('Notes', listener),
      (rows) => rows.some((row) => row.path === 'Notes/FromPhone.md'),
      'a document created on the other device'
    );
    // Let the listener attach before the other device writes, so this tests
    // delivery of a change rather than the attach snapshot again.
    await new Promise((resolve) => setTimeout(resolve, 400));
    await writeFromOtherDevice(node('Notes/FromPhone.md', { text: 'typed elsewhere' }));
    const rows = await arrival;
    expect(rows.length >= 1, 'the folder should have been delivered');
  });

  test("a document listener sees another device's edit, then its deletion", async () => {
    const real = await createFirestoreNodeStore(uid);
    await stores();
    const edited = nextDelivery(
      (listener) => real.watchNode('Notes/A.md', listener),
      (value) => value?.text === 'edited elsewhere',
      "the other device's edit"
    );
    await new Promise((resolve) => setTimeout(resolve, 400));
    await writeFromOtherDevice(node('Notes/A.md', { text: 'edited elsewhere' }));
    await edited;

    const removed = nextDelivery(
      (listener) => real.watchNode('Notes/A.md', listener),
      (value) => value === null,
      'the deletion'
    );
    await new Promise((resolve) => setTimeout(resolve, 400));
    const { doc, deleteDoc, collection } = firebase.firestore;
    await deleteDoc(
      doc(collection(otherDb, USERS_COLLECTION, uid, NODES_COLLECTION), encodeURIComponent('Notes/A.md'))
    );
    expectEqual(await removed, null, 'a deleted document should be delivered as null');
  });

  test('a local write is not delivered back as an incoming change', async () => {
    // `isLocalEcho` skips the snapshot carrying this client's own pending
    // write. The double models no such thing, so this is the one behaviour
    // where the two deliberately differ -- and the app depends on the real
    // one, because delivering a local echo re-renders the pane out from under
    // whoever is typing.
    //
    // The assertion is zero deliveries, not "at most one". Measured against
    // the emulator, a local write produces exactly one snapshot, carrying
    // `hasPendingWrites`. There is no second, confirmed one: a listener
    // without `includeMetadataChanges` is not woken when a write is merely
    // acknowledged, because the document's data did not change. So a working
    // skip means the listener hears nothing at all, and an earlier version of
    // this check that allowed one delivery passed whether the skip worked or
    // not.
    //
    // That also corrects the comment on `isLocalEcho` in firestore-store.js,
    // which describes a later server echo arriving with the flag cleared. It
    // does not arrive. Nothing depends on it -- the upstream content
    // comparison it justifies is still wanted, for genuine changes from
    // another device -- but the sequence is not what was written down.
    const real = await createFirestoreNodeStore(uid);
    await stores();

    const deliveries = [];
    const unsubscribe = real.watchNode('Notes/A.md', (value) => deliveries.push(value));
    await new Promise((resolve) => setTimeout(resolve, 500));
    const before = deliveries.length;

    await real.commit([{ path: 'Notes/A.md', data: node('Notes/A.md', { text: 'typed here' }) }]);
    await new Promise((resolve) => setTimeout(resolve, 1200));
    unsubscribe();

    expectEqual(
      deliveries.length - before,
      0,
      'a local write should reach the listener not at all'
    );
  });
});

// --- running ---------------------------------------------------------------

const red = (text) => `\u001b[31m${text}\u001b[0m`;
const green = (text) => `\u001b[32m${text}\u001b[0m`;
const dim = (text) => `\u001b[2m${text}\u001b[0m`;

const summary = await runAll((event) => {
  if (event.kind === 'suite') console.log(dim(`\n${event.name} (${event.count})`));
  else if (event.kind === 'pass') console.log(`  ${green('✔')} ${event.name}`);
  else if (event.kind === 'fail') console.log(`  ${red('✘')} ${event.name}\n      ${red(event.message)}`);
});

console.log(
  summary.failed === 0
    ? green(`\n${summary.passed} cloud checks in ${summary.suites} suites passed`)
    : red(`\n${summary.failed} of ${summary.total} cloud checks failed`)
);

process.exit(summary.failed === 0 ? 0 : 1);
