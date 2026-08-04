// Signing in, signing out, and knowing who is signed in.
//
// Firebase restores a session asynchronously after the page loads, so "is
// anyone signed in?" has no answer at boot — only "not yet". `restore()` waits
// for the first `onAuthStateChanged`, which is the moment that question
// becomes answerable, and everything that depends on an account waits for it.

import { loadFirebase } from './sdk.js';
import { ApiError } from '../backends/api-error.js';

const listeners = new Set();
let current = null;
let restored = null;

function describe(user) {
  if (!user) return null;
  return {
    uid: user.uid,
    name: user.displayName ?? '',
    email: user.email ?? '',
    photo: user.photoURL ?? '',
  };
}

function publish(user) {
  current = describe(user);
  for (const listener of listeners) listener(current);
}

/** Calls `listener` now with the current account, and again on every change. */
export function observeAccount(listener) {
  listeners.add(listener);
  listener(current);
  return () => listeners.delete(listener);
}

export function currentAccount() {
  return current;
}

/**
 * Resolves once Firebase has decided whether a previous session is still
 * valid. Returns the account, or null.
 */
export function restoreAccount() {
  if (!restored) {
    restored = loadFirebase().then(
      (firebase) =>
        new Promise((resolve) => {
          let settled = false;
          firebase.auth.onAuthStateChanged(firebase.authentication, (user) => {
            publish(user);
            if (!settled) {
              settled = true;
              resolve(current);
            }
          });
        })
    );
  }
  return restored;
}

export async function signIn() {
  const firebase = await loadFirebase();
  const provider = new firebase.auth.GoogleAuthProvider();
  try {
    const credential = await firebase.auth.signInWithPopup(
      firebase.authentication,
      provider
    );
    publish(credential.user);
    return current;
  } catch (error) {
    throw signInFailure(error);
  }
}

export async function signOutOfAccount() {
  const firebase = await loadFirebase();
  await firebase.auth.signOut(firebase.authentication);
  publish(null);
}

/**
 * Turns a Firebase auth code into something worth reading.
 *
 * The two that will actually happen are the popup being closed, which is not
 * an error at all, and the domain not being authorised, which is a setup step
 * in the Firebase console that no amount of retrying will fix — so it says so
 * rather than suggesting the user try again.
 */
function signInFailure(error) {
  const code = error?.code ?? '';
  switch (code) {
    case 'auth/popup-closed-by-user':
    case 'auth/cancelled-popup-request':
      return new ApiError('Sign-in was cancelled.', 'Nothing was changed.');
    case 'auth/popup-blocked':
      return new ApiError(
        'The browser blocked the sign-in window.',
        'Allow pop-ups for this site, then try again.'
      );
    case 'auth/unauthorized-domain':
      return new ApiError(
        `Sign-in is not enabled for ${location.hostname}.`,
        'Add this domain under Authentication ▸ Settings ▸ Authorized domains in the Firebase console.'
      );
    case 'auth/operation-not-allowed':
      return new ApiError(
        'Google sign-in is not turned on for this Firebase project.',
        'Enable the Google provider under Authentication ▸ Sign-in method.'
      );
    case 'auth/network-request-failed':
      return new ApiError(
        'The editor could not reach Firebase.',
        'Check your network connection and try again.'
      );
    default:
      return new ApiError(
        'Sign-in failed.',
        error?.message ?? 'Try again, or keep working with files on this device.'
      );
  }
}
