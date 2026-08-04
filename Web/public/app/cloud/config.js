// The Firebase project this build talks to.
//
// Yes, this is a real API key, and yes, it belongs in a public repository.
// A Firebase web API key is an identifier, not a credential: it names the
// project so the SDK knows where to send requests, and every client that ever
// loads the app has to have it. It grants nothing on its own. What actually
// decides who may read or write anything is the Security Rules, which are in
// `Web/firebase/` beside this file and are the thing to review if you are
// wondering whether this is safe. Google documents this directly:
// https://firebase.google.com/docs/projects/api-keys
//
// The rules restrict every document to the user who signed in and owns it, so
// a stranger with this key can create an account and see their own empty
// workspace, and nothing else.

export const firebaseConfig = {
  apiKey: 'AIzaSyDpnMoGkLQ0hHa5y71kJ36A-ROlCU2oXZk',
  authDomain: 'kirupa-markdown.firebaseapp.com',
  projectId: 'kirupa-markdown',
  storageBucket: 'kirupa-markdown.firebasestorage.app',
  messagingSenderId: '777425511524',
  appId: '1:777425511524:web:1bb6b0d961ab673031ab71',
  measurementId: 'G-PLQDXJ3ZJR',
};

/**
 * Pinned, because an unpinned CDN import is a third party deciding when this
 * app changes. Bump it deliberately and re-run the suite.
 */
export const FIREBASE_VERSION = '12.4.0';

export const FIREBASE_CDN = `https://www.gstatic.com/firebasejs/${FIREBASE_VERSION}`;

/**
 * The collection each user's nodes live in: `users/{uid}/nodes/{documentId}`.
 * A subcollection rather than one flat collection with a `uid` field, so the
 * rules can be a path match and cannot be got wrong per-document.
 */
export const NODES_COLLECTION = 'nodes';
export const USERS_COLLECTION = 'users';
