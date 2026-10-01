// Who answers a critique, and where the key for them is kept.
//
// Port of the parts of Shared/Sources/MarkdownEditorCore/CritiqueProvider.swift
// a browser needs: the names, the models, and where to get a key. The request
// shapes are not here, because the browser does not make the request -- see
// `critique-api.js` for why it goes through the server.
//
// The Mac's fourth provider, a model already installed on the reader's machine
// needing no key, has no equivalent here and is deliberately absent. A browser
// has no such thing, and offering it would put an option in a menu that could
// never work.

const KEY_PREFIX = 'markdown-editor.critiqueKey.';
const PROVIDER_KEY = 'markdown-editor.critiqueProvider';
const MODEL_PREFIX = 'markdown-editor.critiqueModel.';

export const PROVIDERS = [
  {
    id: 'openAI',
    title: 'OpenAI',
    keyOrigin: 'platform.openai.com/api-keys',
    models: ['gpt-4o-mini', 'gpt-4o'],
  },
  {
    id: 'anthropic',
    title: 'Anthropic',
    keyOrigin: 'console.anthropic.com/settings/keys',
    models: ['claude-3-5-haiku-latest', 'claude-3-5-sonnet-latest'],
  },
  {
    id: 'gemini',
    title: 'Google Gemini',
    keyOrigin: 'aistudio.google.com/apikey',
    // The 1.5 pair this shipped with had been retired, and the API reports
    // that as "is not found for API version v1beta" -- which reads like a
    // mistyped name rather than a model that no longer exists. These two are
    // the ones verified answering.
    models: ['gemini-2.5-flash', 'gemini-3.6-flash'],
  },
];

export const INITIAL_PROVIDER = 'openAI';

export function providerByID(id) {
  return PROVIDERS.find((provider) => provider.id === id) ?? PROVIDERS[0];
}

/**
 * The chosen provider.
 *
 * Read through one function rather than written out wherever it is wanted. On
 * the Mac the same default was written in three places and two of them
 * disagreed, so a picker ticked one provider while the critiques went through
 * another -- a control lying about its own state.
 */
export function currentProvider() {
  const stored = localStorage.getItem(PROVIDER_KEY);
  return PROVIDERS.some((provider) => provider.id === stored) ? stored : INITIAL_PROVIDER;
}

export function setCurrentProvider(id) {
  localStorage.setItem(PROVIDER_KEY, providerByID(id).id);
}

export function currentModel(providerID = currentProvider()) {
  const provider = providerByID(providerID);
  const stored = localStorage.getItem(MODEL_PREFIX + provider.id);
  return provider.models.includes(stored) ? stored : provider.models[0];
}

export function setCurrentModel(model, providerID = currentProvider()) {
  localStorage.setItem(MODEL_PREFIX + providerByID(providerID).id, model);
}

/**
 * The reader's key for a provider.
 *
 * Kept per provider, so switching to try another one and back does not lose
 * the first.
 */
export function storedKey(providerID = currentProvider()) {
  return localStorage.getItem(KEY_PREFIX + providerByID(providerID).id) ?? '';
}

export function saveKey(key, providerID = currentProvider()) {
  const trimmed = String(key ?? '').trim();
  if (trimmed === '') {
    removeKey(providerID);
    return;
  }
  localStorage.setItem(KEY_PREFIX + providerByID(providerID).id, trimmed);
}

export function removeKey(providerID = currentProvider()) {
  localStorage.removeItem(KEY_PREFIX + providerByID(providerID).id);
}

export function hasKey(providerID = currentProvider()) {
  return storedKey(providerID) !== '';
}

/**
 * What a key looks like when it is shown back to someone.
 *
 * Never the whole thing. The point of showing it at all is to answer "is the
 * right key in here", which the ends answer and the middle does not, and a key
 * printed in full on screen is a key that ends up in a screenshot.
 */
export function maskKey(key) {
  const value = String(key ?? '').trim();
  if (value === '') return '';
  if (value.length <= 12) return `${value.slice(0, 2)}…${value.slice(-2)}`;
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}
