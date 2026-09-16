// The rail of comments down the right-hand side, and the highlights it points
// at.
//
// Mirrors macOS/Sources/MarkdownEditor/CritiqueSidebar.swift: a card per
// finding, the open one raised and tinted, the passage it describes shaded in
// the text, and a click on either side moving the other.
//
// The one thing that is not a port is where the key lives. A browser cannot
// hold a secret, so the provider and the key are the server's and this asks it
// to make the call -- see Web/src/Critique.php.

import { ApiError } from '../backends/api-error.js';
import { critiqueApi } from '../critique-api.js';
import { decodeCritiqueReport } from '../core/critique-report.js';
import {
  RESOLUTION,
  RESOLUTION_LABEL,
  anchoredCount,
  highlightsFor,
  isAnchored,
  isOutstanding,
  makeItems,
  reorder,
  resolutionKey,
  resolvedCount,
  scoreFor,
  severityCounts,
  verdictFor,
} from '../core/critique-model.js';
import { trackItems } from '../core/critique-anchor-tracking.js';
import { findingAdvice, findingAdviceLabel } from '../core/critique-report.js';
import {
  PROVIDERS,
  currentModel,
  currentProvider,
  hasKey,
  maskKey,
  providerByID,
  removeKey,
  saveKey,
  setCurrentModel,
  setCurrentProvider,
  storedKey,
} from '../core/critique-credentials.js';
import { dialogParts, presentDialog } from './dialogs.js';
import { keepFocus } from './keep-focus.js';

const HAND_KEY = 'markdown-editor.critiqueHand';
const VISIBLE_KEY = 'markdown-editor.critiqueVisible';
const RESOLUTIONS_KEY = 'markdown-editor.critiqueResolutions';

/**
 * The hands the critique can be written in.
 *
 * A choice rather than a decision, because this one is taste: a marker, a
 * drafting hand and a pen are three different tones of voice for the same
 * comment, and which one reads as "somebody wrote on my draft" rather than "a
 * machine generated this" is not something to settle on somebody's behalf.
 *
 * `scale` is what to multiply a requested size by so every face lands at the
 * same *read* size, measured from x-height rather than cap height -- these
 * faces disagree about capitals far more than about lowercase, and almost
 * every word here is lowercase. The numbers are the macOS build's, measured
 * from the same font files.
 */
export const HANDS = [
  { id: 'sans', title: 'System Sans', family: '', scale: 1.0, bundled: false },
  { id: 'architectsDaughter', title: 'Architects Daughter', family: 'Architects Daughter', scale: 1.19, bundled: true },
  { id: 'caveat', title: 'Caveat', family: 'Caveat', scale: 1.28, bundled: true },
  { id: 'indieFlower', title: 'Indie Flower', family: 'Indie Flower', scale: 1.12, bundled: true },
  { id: 'patrickHand', title: 'Patrick Hand', family: 'Patrick Hand', scale: 1.09, bundled: true },
  { id: 'shadowsIntoLight', title: 'Shadows Into Light', family: 'Shadows Into Light', scale: 0.84, bundled: true },
  { id: 'gloriaHallelujah', title: 'Gloria Hallelujah', family: 'Gloria Hallelujah', scale: 0.90, bundled: true },
  { id: 'kalam', title: 'Kalam', family: 'Kalam', scale: 0.97, bundled: true },
  { id: 'permanentMarker', title: 'Permanent Marker', family: 'Permanent Marker', scale: 0.84, bundled: true },
  { id: 'bradleyHand', title: 'Bradley Hand', family: 'Bradley Hand', scale: 1.03, bundled: false },
  { id: 'markerFelt', title: 'Marker Felt', family: 'Marker Felt', scale: 0.88, bundled: false },
  { id: 'noteworthy', title: 'Noteworthy', family: 'Noteworthy', scale: 0.94, bundled: false },
  { id: 'chalkboard', title: 'Chalkboard', family: 'Chalkboard SE', scale: 1.01, bundled: false },
];

/**
 * The face to use before anybody has chosen one.
 *
 * Named once and read everywhere. On the Mac this was written out three times
 * and two of them disagreed, so the rail's menu ticked a hand the rail was not
 * writing in -- a control lying about its own state, which is the worst kind
 * of wrong a picker can be.
 */
export const INITIAL_HAND = 'sans';

/**
 * Which faces to offer.
 *
 * The bundled ones always; the system ones only where they resolve. This is
 * the web's version of the Mac's `NSFont(name:) != nil` check, and it exists
 * for the same reason: a picker offering a face that is not there means
 * choosing it silently draws something else, which looks like the app
 * ignoring you.
 */
export function availableHands() {
  return HANDS.filter((hand) => {
    if (hand.id === 'sans' || hand.bundled) return true;
    if (typeof document === 'undefined' || !document.fonts?.check) return false;
    try {
      return document.fonts.check(`16px "${hand.family}"`);
    } catch {
      return false;
    }
  });
}

export function handByID(id) {
  return HANDS.find((hand) => hand.id === id) ?? HANDS[0];
}

const SEVERITY_LABELS = { high: 'High', medium: 'Medium', low: 'Low' };

const ICONS = {
  sparkles:
    '<path d="M8 1.6l1.1 3 3 1.1-3 1.1L8 9.8 6.9 6.8l-3-1.1 3-1.1z" fill="currentColor"/>'
    + '<path d="M13 9.2l.6 1.6 1.6.6-1.6.6-.6 1.6-.6-1.6-1.6-.6 1.6-.6z" fill="currentColor"/>'
    + '<path d="M3.4 9.8l.5 1.3 1.3.5-1.3.5-.5 1.3-.5-1.3-1.3-.5 1.3-.5z" fill="currentColor"/>',
  gear:
    '<path d="M8 10.2a2.2 2.2 0 1 0 0-4.4 2.2 2.2 0 0 0 0 4.4z" fill="none" stroke="currentColor" stroke-width="1.3"/>'
    + '<path d="M8 1.6l.9 1.7 1.9-.4.5 1.9 1.8.7-.8 1.8.8 1.8-1.8.7-.5 1.9-1.9-.4L8 14.4l-.9-1.7-1.9.4-.5-1.9-1.8-.7.8-1.8-.8-1.8 1.8-.7.5-1.9 1.9.4z" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"/>',
  pen:
    '<path d="M2.5 13.5l1-3L10.4 3.6a1.4 1.4 0 0 1 2 2L5.5 12.5z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/>',
  refresh:
    '<path d="M13 8a5 5 0 1 1-1.6-3.7" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>'
    + '<path d="M13 2.2V5h-2.8" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>',
  close:
    '<path d="M4 4l8 8M12 4l-8 8" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>',
  check:
    '<path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
  undo:
    '<path d="M3 8h7a3 3 0 0 1 0 6H7" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>'
    + '<path d="M5.5 5.5L3 8l2.5 2.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>',
  history:
    '<path d="M8 4v4l2.6 1.6" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>'
    + '<circle cx="8" cy="8" r="5.6" fill="none" stroke="currentColor" stroke-width="1.3"/>',
};

function icon(name) {
  return `<svg viewBox="0 0 16 16" aria-hidden="true">${ICONS[name]}</svg>`;
}

function build(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function iconButton(name, label, onClick) {
  const button = build('button', 'me-critique__icon');
  button.type = 'button';
  button.innerHTML = icon(name);
  button.title = label;
  button.setAttribute('aria-label', label);
  button.addEventListener('click', onClick);
  keepFocus(button);
  return button;
}

/**
 * A stable tilt per note, so answering one does not reshuffle the pad.
 *
 * Hashed from the note's own identity rather than from its position: the
 * position changes when a note above it is answered, and a pad that
 * re-scatters itself every time you tick something off is a pad nobody trusts.
 */
function jitter(id) {
  let hash = 0;
  for (let index = 0; index < id.length; index += 1) {
    hash = (hash * 31 + id.charCodeAt(index)) | 0;
  }
  const angle = ((hash % 100) / 100 - 0.5) * 1.7;
  const nudge = (((hash >> 7) % 100) / 100 - 0.5) * 4;
  return { angle, nudge };
}

export class CritiqueRail {
  /**
   * @param {object} options
   * @param {HTMLElement} options.root the rail's own element
   * @param {() => string} options.text the document as it stands
   * @param {() => string|null} options.documentPath which document is open
   * @param {() => void} options.onHighlightsChanged redraw the shading
   * @param {(range: {location: number, length: number}) => void} options.onReveal
   */
  constructor({ root, text, documentPath, onHighlightsChanged, onReveal }) {
    this.root = root;
    this.readText = text;
    this.readPath = documentPath;
    this.onHighlightsChanged = onHighlightsChanged;
    this.onReveal = onReveal;

    this.report = null;
    this.items = [];
    this.isRunning = false;
    this.failure = null;
    this.progressNote = '';
    this.selectedID = null;
    this.criticisedText = null;
    this.currentText = '';
    this.config = null;
    this.hand = localStorage.getItem(HAND_KEY) ?? INITIAL_HAND;
    this.visible = localStorage.getItem(VISIBLE_KEY) === 'true';
    this.resolutions = this.#loadResolutions();
    this.pending = null;

    this.root.classList.add('me-critique');
    this.applyHand();
    this.render();
  }

  // MARK: - Showing and hiding

  get isVisible() {
    return this.visible;
  }

  show() {
    this.visible = true;
    localStorage.setItem(VISIBLE_KEY, 'true');
    this.render();
    this.onHighlightsChanged();
  }

  dismiss() {
    this.visible = false;
    localStorage.setItem(VISIBLE_KEY, 'false');
    this.selectedID = null;
    this.render();
    this.onHighlightsChanged();
  }

  toggle() {
    if (this.visible) this.dismiss();
    else this.show();
  }

  // MARK: - The hand

  applyHand() {
    const hand = handByID(this.hand);
    const root = document.documentElement;
    root.style.setProperty(
      '--me-critique-hand',
      hand.family === '' ? 'var(--me-ui-font)' : `"${hand.family}", var(--me-ui-font)`
    );
    // Type is specified in points but read at whatever size it happens to
    // draw, and these faces are not the same size at the same number. The rail
    // asks for an *optical* size and this is what turns that into one each
    // face can be given.
    root.style.setProperty('--me-critique-hand-scale', String(hand.scale));
  }

  setHand(id) {
    this.hand = id;
    localStorage.setItem(HAND_KEY, id);
    this.applyHand();
    this.render();
  }

  // MARK: - Tracking the document

  /**
   * Moves the marks onto the text as it stands now.
   *
   * Called from wherever the document changes rather than from the editing
   * surface, because what moved the marks is the document changing, whoever
   * changed it -- a reload from the server has to move them too.
   */
  noteCurrentText(text) {
    const previous = this.currentText;
    this.currentText = text;
    if (previous === '' || previous === text) return;
    // Nothing anchored, nothing to move — and working out what changed means
    // comparing the whole draft against the whole draft.
    if (this.items.length === 0) return;
    const before = this.items;
    this.items = trackItems(this.items, previous, text);
    if (before.some((item, index) => item.range !== this.items[index].range)) {
      this.onHighlightsChanged();
      if (this.visible) this.render();
    }
  }

  isStale() {
    if (this.criticisedText === null) return false;
    return this.criticisedText !== this.readText();
  }

  get highlights() {
    return this.visible ? highlightsFor(this.items) : [];
  }

  itemWithID(id) {
    return this.items.find((item) => item.id === id) ?? null;
  }

  /** Selects the finding whose passage contains `offset`, if any. */
  selectAtOffset(offset) {
    const hit = this.items.find(
      (item) =>
        isOutstanding(item)
        && isAnchored(item)
        && offset >= item.range.location
        && offset < item.range.location + item.range.length
    );
    if (!hit || hit.id === this.selectedID) return false;
    this.selectedID = hit.id;
    this.render();
    this.#scrollCardIntoView(hit.id);
    this.onHighlightsChanged();
    return true;
  }

  // MARK: - Running

  async loadConfig() {
    try {
      this.config = await critiqueApi.config();
    } catch {
      // A configuration the server will not describe is the same, to the
      // reader, as one that is not set up: the rail says so and offers no
      // button that cannot work.
      this.config = { available: false };
    }
    if (this.visible) this.render();
  }

  /** Whether a critique can run at all: a key here, or one on the server. */
  get isConfigured() {
    return hasKey() || this.config?.serverKey === true;
  }

  async run({ focus = null } = {}) {
    if (this.isRunning) return;
    // Asking without a key spends a request to be told what this already
    // knows. The rail says what is missing and offers the panel that fixes it.
    if (!this.isConfigured) {
      this.show();
      this.render();
      await this.#openSettings();
      if (!this.isConfigured) return;
    }
    const text = this.readText();
    this.noteCurrentText(text);
    this.show();
    this.isRunning = true;
    this.failure = null;
    this.progressNote = 'Reading the draft…';
    this.render();

    const controller = new AbortController();
    this.pending = controller;
    try {
      const answer = await critiqueApi.run({
        text,
        focus,
        provider: currentProvider(),
        model: currentModel(),
        key: storedKey(),
        signal: controller.signal,
      });
      const report = decodeCritiqueReport(answer.reply);
      this.#apply(report, text);
    } catch (error) {
      if (controller.signal.aborted) {
        this.isRunning = false;
        this.progressNote = '';
        this.render();
        return;
      }
      this.#fail(error);
    } finally {
      this.pending = null;
    }
  }

  cancel() {
    this.pending?.abort();
  }

  #apply(report, text) {
    this.report = report;
    this.items = reorder(makeItems(report.findings, text, this.resolutions));
    this.criticisedText = text;
    this.currentText = text;
    this.isRunning = false;
    this.progressNote = '';
    this.failure = null;
    this.selectedID = null;
    this.render();
    this.onHighlightsChanged();
  }

  #fail(error) {
    this.isRunning = false;
    this.progressNote = '';
    this.report = null;
    this.items = [];
    this.failure =
      error instanceof ApiError
        ? { message: error.message, recovery: error.recovery }
        : { message: error.message ?? 'The critique could not be read.', recovery: '' };
    this.render();
    this.onHighlightsChanged();
  }

  // MARK: - Answering a note

  setResolution(id, resolution) {
    const item = this.itemWithID(id);
    if (!item) return;
    item.resolution = resolution;
    const key = resolutionKey(item.finding);
    if (resolution === null) delete this.resolutions[key];
    else this.resolutions[key] = resolution;
    this.#saveResolutions();
    // A resolved finding stops shading its passage: the whole point of
    // answering one is that it is no longer something to look at.
    if (resolution !== null && this.selectedID === id) this.selectedID = null;
    this.items = reorder(this.items);
    this.render();
    this.onHighlightsChanged();
  }

  #resolutionsStorageKey() {
    return `${RESOLUTIONS_KEY}:${this.readPath() ?? ''}`;
  }

  #loadResolutions() {
    try {
      const raw = localStorage.getItem(this.#resolutionsStorageKey());
      const parsed = raw === null ? {} : JSON.parse(raw);
      return parsed && typeof parsed === 'object' ? parsed : {};
    } catch {
      return {};
    }
  }

  #saveResolutions() {
    try {
      localStorage.setItem(this.#resolutionsStorageKey(), JSON.stringify(this.resolutions));
    } catch {
      // A full or disabled localStorage loses the record of what was answered,
      // which is a real loss and not one worth an alert in the middle of
      // ticking notes off.
    }
  }

  /** The document changed under us, so the answers for the old one do not apply. */
  documentChanged() {
    this.report = null;
    this.items = [];
    this.failure = null;
    this.criticisedText = null;
    this.currentText = this.readText();
    this.selectedID = null;
    this.resolutions = this.#loadResolutions();
    this.render();
    this.onHighlightsChanged();
  }

  // MARK: - Drawing

  render() {
    this.root.hidden = !this.visible;
    if (!this.visible) {
      this.root.replaceChildren();
      return;
    }
    const body = build('div', 'me-critique__body');
    this.root.replaceChildren(this.#header(), body);

    if (this.isRunning) {
      body.append(this.#running());
      return;
    }
    if (this.failure) {
      body.append(this.#failed());
      return;
    }
    if (!this.isConfigured) {
      body.append(this.#needsKey());
      return;
    }
    if (!this.report) {
      body.append(this.#nothingYet());
      return;
    }

    body.append(this.#scoreBanner());
    if (this.isStale()) body.append(this.#staleNotice());
    body.append(this.#summary(this.report));

    let answeredHeadingDrawn = false;
    for (const item of this.items) {
      if (!isOutstanding(item) && !answeredHeadingDrawn) {
        body.append(this.#answeredHeading());
        answeredHeadingDrawn = true;
      }
      body.append(this.#card(item));
    }
  }

  #header() {
    const header = build('header', 'me-critique__header');
    const mark = build('span', 'me-critique__mark');
    mark.innerHTML = icon('sparkles');
    const title = build('span', 'me-critique__title', 'CRITIQUE');
    const spacer = build('span', 'me-critique__spacer');
    header.append(mark, title, spacer);

    // The provider, the model and the skill live behind this. On the Mac it is
    // also where the key is; here the key is the server's, so this says what
    // the server is set up with rather than asking for one.
    header.append(iconButton('gear', 'Which model and skill answer', () => this.#openSettings()));
    header.append(this.#handMenu());

    if (this.isRunning) {
      const stop = build('button', 'me-critique__text-button', 'Stop');
      stop.type = 'button';
      stop.addEventListener('click', () => this.cancel());
      keepFocus(stop);
      header.append(stop);
    } else if (this.report) {
      header.append(
        iconButton('refresh', 'Critique the document again', () => this.run())
      );
    }
    header.append(iconButton('close', 'Close the critique', () => this.dismiss()));
    return header;
  }

  /**
   * Pick the hand the comments are written in.
   *
   * Each name is set in its own face, because the names mean nothing -- nobody
   * knows what "Caveat" looks like, and a list of thirteen words in the same
   * font asks you to guess and then look. Showing them is the whole answer to
   * the question the menu is asking.
   */
  #handMenu() {
    const wrapper = build('span', 'me-critique__hand-menu');
    const select = build('select', 'me-critique__hand-select');
    select.title = 'The hand the comments are written in';
    select.setAttribute('aria-label', 'Comments are written in');

    const hands = availableHands();
    const system = hands.filter((hand) => !hand.bundled && hand.id !== 'sans');

    const add = (parent, hand) => {
      const option = build('option', '', hand.title);
      option.value = hand.id;
      if (hand.family !== '') option.style.fontFamily = `"${hand.family}"`;
      if (hand.id === this.hand) option.selected = true;
      parent.append(option);
    };

    add(select, hands[0]);
    const bundled = build('optgroup');
    bundled.label = 'Bundled';
    for (const hand of hands.filter((entry) => entry.bundled)) add(bundled, hand);
    select.append(bundled);
    if (system.length > 0) {
      const group = build('optgroup');
      group.label = 'From your computer';
      for (const hand of system) add(group, hand);
      select.append(group);
    }

    select.addEventListener('change', () => this.setHand(select.value));
    const glyph = build('span', 'me-critique__hand-glyph');
    glyph.innerHTML = icon('pen');
    wrapper.append(glyph, select);
    return wrapper;
  }

  #running() {
    const panel = build('div', 'me-critique__state');
    const spinner = build('div', 'me-critique__spinner');
    const note = build('p', 'me-critique__state-note', this.progressNote || 'Reading…');
    const detail = build(
      'p',
      'me-critique__state-detail',
      'A careful read of a full draft takes the better part of a minute.'
    );
    panel.append(spinner, note, detail);
    return panel;
  }

  #failed() {
    const panel = build('div', 'me-critique__state me-critique__state--failed');
    panel.append(build('p', 'me-critique__state-note', this.failure.message));
    if (this.failure.recovery) {
      panel.append(build('p', 'me-critique__state-detail', this.failure.recovery));
    }
    const again = build('button', 'me-critique__button', 'Try again');
    again.type = 'button';
    again.addEventListener('click', () => this.run());
    panel.append(again);
    return panel;
  }

  /**
   * The first-run state: a critique needs a model, and a model needs a key.
   *
   * It says whose key and where it goes, because "enter your API key" is not
   * help if you do not already know where they live or what happens to it.
   */
  #needsKey() {
    const panel = build('div', 'me-critique__state');
    panel.append(build('p', 'me-critique__state-note', 'Bring your own key.'));
    panel.append(
      build(
        'p',
        'me-critique__state-detail',
        'A critique is read by a model, and reaching one costs money, so it runs '
          + 'on your account rather than on this site\u2019s. The key is kept in '
          + 'this browser and sent with each critique for the server to use and '
          + 'forget.'
      )
    );
    const open = build('button', 'me-critique__button', 'Add a key');
    open.type = 'button';
    open.addEventListener('click', () => this.#openSettings());
    panel.append(open);
    return panel;
  }

  #nothingYet() {
    const panel = build('div', 'me-critique__state');
    panel.append(build('p', 'me-critique__state-note', 'Nothing read yet.'));
    panel.append(
      build(
        'p',
        'me-critique__state-detail',
        'A critique reads the whole draft and writes notes on the passages that '
          + 'prove each point.'
      )
    );
    const run = build('button', 'me-critique__button', 'Critique this draft');
    run.type = 'button';
    run.addEventListener('click', () => this.run());
    panel.append(run);
    return panel;
  }

  /**
   * How good the draft looks, out of a hundred.
   *
   * Counts only what is outstanding, so answering everything returns it to
   * 100. That is the point of the two actions: the author has said what they
   * meant to say, and the score should agree with them rather than keep score
   * against them.
   */
  #scoreBanner() {
    const score = scoreFor(this.items);
    const severity = score >= 85 ? 'low' : score >= 50 ? 'medium' : 'high';
    const banner = build('div', `me-critique__score me-critique__score--${severity}`);

    const top = build('div', 'me-critique__score-top');
    const number = build('span', 'me-critique__score-number', String(score));
    const outOf = build('span', 'me-critique__score-outof', '/100');
    const right = build('div', 'me-critique__score-verdict');
    right.append(build('span', 'me-critique__score-caption', 'AWESOMENESS'));
    right.append(build('span', 'me-critique__score-word', verdictFor(this.items)));
    top.append(number, outOf, right);

    // A bar, because a number alone gives nothing to compare against. It fills
    // as findings are answered, which is the whole loop: the rail is a list of
    // things to do, and this is how much is left.
    //
    // Stepped, not smooth: the bar reads in whole blocks, the way a health
    // meter does, rather than as a continuous measurement it cannot honestly
    // claim to be.
    const bar = build('div', 'me-critique__bar');
    for (let block = 0; block < 20; block += 1) {
      const cell = build('span', 'me-critique__bar-block');
      if (block * 5 < score) cell.classList.add('is-filled');
      bar.append(cell);
    }

    banner.append(top, bar);
    const answered = resolvedCount(this.items);
    if (answered > 0) {
      banner.append(
        build(
          'p',
          'me-critique__score-answered',
          answered === this.items.length
            ? 'Everything answered.'
            : `${answered} of ${this.items.length} answered.`
        )
      );
    }
    return banner;
  }

  #staleNotice() {
    const notice = build('div', 'me-critique__stale');
    const total = this.items.length;
    const applying = anchoredCount(this.items);
    const survivors = total > 0 ? ` ${applying} of ${total} notes still point at something.` : '';
    notice.append(
      build(
        'p',
        'me-critique__stale-text',
        `The draft has changed since this critique.${survivors}`
      )
    );
    const again = build('button', 'me-critique__button', 'Critique again');
    again.type = 'button';
    again.addEventListener('click', () => this.run());
    notice.append(again);
    return notice;
  }

  #answeredHeading() {
    const heading = build('div', 'me-critique__answered-heading');
    heading.append(build('span', 'me-critique__section-title', 'ANSWERED'));
    heading.append(build('span', 'me-critique__rule'));
    return heading;
  }

  /**
   * The first note on the pad: what the piece is, what works, what does not.
   *
   * White, and the only white note, because it is not a finding -- it is the
   * reader's impression of the whole draft. Colour on this one would file it
   * alongside the problems, which is exactly what it is not.
   *
   * Entirely in the app's own face rather than the hand, because it is a
   * summary *of* the handwritten notes rather than one of them.
   */
  #summary(report) {
    const note = this.#stickyNote('me-critique__note--summary', 'summary');
    const inner = note.querySelector('.me-critique__note-body');

    if (report.jobRead) {
      inner.append(build('p', 'me-critique__job', report.jobRead));
    }
    if (report.whatWorks.length > 0) {
      inner.append(this.#summarySection('WHAT WORKS', report.whatWorks, '+', 'works'));
    }
    const problems =
      report.whatDoesNotWork.length > 0
        ? report.whatDoesNotWork
        : report.overall
          ? [report.overall]
          : [];
    if (problems.length > 0) {
      inner.append(this.#summarySection("WHAT DOESN'T WORK", problems, '–', 'problems'));
    }

    const counts = severityCounts(this.items);
    if (counts.length > 0) {
      const row = build('div', 'me-critique__counts');
      for (const entry of counts) {
        const chip = build('span', `me-critique__count me-critique__count--${entry.severity}`);
        chip.append(build('span', 'me-critique__count-swatch'));
        chip.append(
          build('span', '', `${entry.count} ${SEVERITY_LABELS[entry.severity].toUpperCase()}`)
        );
        row.append(chip);
      }
      inner.append(row);
    }

    const unanchored = this.items.length - anchoredCount(this.items);
    if (unanchored > 0) {
      inner.append(
        build(
          'p',
          'me-critique__job',
          `${unanchored} ${unanchored === 1 ? 'note' : 'notes'} could not be `
            + 'matched to a passage, so nothing is shaded for them.'
        )
      );
    }
    return note;
  }

  #summarySection(title, lines, mark, kind) {
    const section = build('section', `me-critique__summary-section me-critique__summary-section--${kind}`);
    section.append(build('h3', 'me-critique__section-title', title));
    const list = build('ul', 'me-critique__summary-list');
    for (const line of lines) {
      const entry = build('li');
      entry.append(build('span', 'me-critique__summary-mark', mark));
      entry.append(build('span', '', line));
      list.append(entry);
    }
    section.append(list);
    return section;
  }

  /**
   * A note on the pad.
   *
   * The tilt and the nudge are what make a stack of these read as paper rather
   * than as a list of rows; a note that has been dealt with is straightened,
   * which reads as "this one has been handled" without needing a word for it.
   */
  #stickyNote(modifier, id) {
    const note = build('article', `me-critique__note ${modifier}`);
    const { angle, nudge } = jitter(id);
    note.style.setProperty('--me-note-angle', `${angle.toFixed(2)}deg`);
    note.style.setProperty('--me-note-nudge', `${nudge.toFixed(1)}px`);
    note.append(build('div', 'me-critique__note-body'));
    return note;
  }

  #card(item) {
    const finding = item.finding;
    const answered = !isOutstanding(item);
    const note = this.#stickyNote(
      `me-critique__note--${finding.severity}${answered ? ' is-answered' : ''}`,
      item.id
    );
    if (answered) note.style.setProperty('--me-note-angle', '0deg');
    if (this.selectedID === item.id) note.classList.add('is-selected');
    note.dataset.findingId = item.id;

    // Severity reads twice over: the paper it is written on, and the tag
    // itself. That is deliberate rather than redundant -- the colour is what
    // you take in scrolling past, and the word is what you check when it
    // matters. An answered note shows what was decided instead, because the
    // severity of something you have dealt with is no longer the useful fact.
    const tag = build(
      'span',
      `me-critique__tag${answered ? ' me-critique__tag--answered' : ''}`,
      (answered ? RESOLUTION_LABEL[item.resolution] : SEVERITY_LABELS[finding.severity]).toUpperCase()
    );
    note.prepend(tag);

    const body = note.querySelector('.me-critique__note-body');

    const head = build('div', 'me-critique__note-head');
    head.append(build('h3', 'me-critique__note-category', finding.category));
    if (finding.needsVerification) {
      head.append(build('span', 'me-critique__flag', 'needs verification'));
    }
    body.append(head);

    // The passage is *not* repeated here. The highlight in the document is
    // already pointing at it, and a note that restates the sentence it is
    // about makes you read the same words twice to learn nothing.
    //
    // The exception is a note nothing points at: when the quote could not be
    // found there is no highlight, and without the words the note has no
    // subject at all. Deliberately not handwriting -- this is the author's own
    // sentence quoted back at them, and it has to be recognisable as theirs.
    if (!isAnchored(item) && finding.quote) {
      body.append(build('blockquote', 'me-critique__quote', finding.quote));
    }

    body.append(build('p', 'me-critique__why', finding.why));

    const advice = findingAdvice(finding);
    if (advice) {
      const block = build('div', 'me-critique__advice');
      block.append(
        build('span', 'me-critique__advice-label', findingAdviceLabel(finding).toUpperCase())
      );
      block.append(build('p', 'me-critique__advice-text', advice));
      body.append(block);
    }

    const footer = build('div', 'me-critique__note-foot');
    if (isAnchored(item)) {
      if (finding.location) {
        footer.append(build('span', 'me-critique__location', finding.location));
      }
    } else {
      footer.append(build('span', 'me-critique__location', 'Not found in the document'));
    }
    footer.append(build('span', 'me-critique__spacer'));

    // Always present rather than revealed on hover: a control that appears
    // only when the pointer is over it is a control nobody finds, and these
    // two are the whole reason the rail is not merely a list of complaints.
    if (answered) {
      footer.append(
        iconButton('undo', 'Put this note back.', (event) => {
          event.stopPropagation();
          this.setResolution(item.id, null);
        })
      );
    } else {
      const done = iconButton('check', 'I have fixed this. It will not be raised again.', (event) => {
        event.stopPropagation();
        this.setResolution(item.id, RESOLUTION.completed);
      });
      done.classList.add('me-critique__stamp', 'me-critique__stamp--done');
      const dismiss = iconButton('close', 'I am not doing this. It will not be raised again.', (event) => {
        event.stopPropagation();
        this.setResolution(item.id, RESOLUTION.dismissed);
      });
      dismiss.classList.add('me-critique__stamp', 'me-critique__stamp--dismiss');
      footer.append(done, dismiss);
    }
    body.append(footer);

    note.addEventListener('click', () => this.#selectCard(item));
    return note;
  }

  #selectCard(item) {
    this.selectedID = this.selectedID === item.id ? null : item.id;
    this.render();
    this.onHighlightsChanged();
    if (this.selectedID && isAnchored(item)) this.onReveal(item.range);
  }

  #scrollCardIntoView(id) {
    const card = this.root.querySelector(`[data-finding-id="${CSS.escape(id)}"]`);
    card?.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }

  /**
   * Which model answers, on which key, against which skill.
   *
   * The Mac keeps the key in the Keychain and talks to the provider itself.
   * A browser can do neither: it has nowhere safe to put a secret, and the two
   * of the three providers that matter do not answer a cross-origin request at
   * all. So the key is the reader's, kept in this browser, and sent with each
   * request for the server to spend and forget.
   *
   * That is a real trade and it is written down rather than implied:
   * `localStorage` is readable by any script on this origin, which is the same
   * exposure the rest of the app's preferences have and a good deal more
   * consequence. It is the least-bad option a page has, and it is the reader's
   * own key rather than somebody else's.
   */
  async #openSettings() {
    if (!this.config) await this.loadConfig();
    const { heading, paragraph, button } = dialogParts;

    await presentDialog((alert, close) => {
      alert.classList.add('me-alert--settings');
      alert.append(heading('AI Assisted Critique'));

      let providerID = currentProvider();

      const field = (labelText, control) => {
        const row = document.createElement('label');
        row.className = 'me-settings__row';
        const label = document.createElement('span');
        label.className = 'me-settings__label';
        label.textContent = labelText;
        row.append(label, control);
        return row;
      };

      // --- Provider -------------------------------------------------------
      const providerSelect = document.createElement('select');
      providerSelect.className = 'me-settings__control';
      for (const provider of PROVIDERS) {
        const option = document.createElement('option');
        option.value = provider.id;
        option.textContent = provider.title;
        option.selected = provider.id === providerID;
        providerSelect.append(option);
      }

      // --- Model ----------------------------------------------------------
      const modelSelect = document.createElement('select');
      modelSelect.className = 'me-settings__control';

      // --- Key ------------------------------------------------------------
      // A password field, so a key does not sit in plain sight on a screen
      // somebody might be sharing.
      const keyField = document.createElement('input');
      keyField.type = 'password';
      keyField.className = 'me-settings__control';
      keyField.autocomplete = 'off';
      keyField.spellcheck = false;
      keyField.placeholder = 'Paste your API key';

      const status = document.createElement('p');
      status.className = 'me-settings__status';
      const origin = document.createElement('p');
      origin.className = 'me-alert__recovery';

      const refresh = () => {
        const provider = providerByID(providerID);
        modelSelect.replaceChildren();
        for (const model of provider.models) {
          const option = document.createElement('option');
          option.value = model;
          option.textContent = model;
          option.selected = model === currentModel(provider.id);
          modelSelect.append(option);
        }
        keyField.value = '';
        origin.textContent = `Keys come from ${provider.keyOrigin}`;
        status.textContent = hasKey(provider.id)
          ? `A key is stored in this browser: ${maskKey(storedKey(provider.id))}`
          : 'No key yet, so a critique cannot run.';
        status.dataset.state = hasKey(provider.id) ? 'ok' : 'missing';
      };

      providerSelect.addEventListener('change', () => {
        providerID = providerSelect.value;
        setCurrentProvider(providerID);
        refresh();
      });
      modelSelect.addEventListener('change', () => {
        setCurrentModel(modelSelect.value, providerID);
      });

      alert.append(
        field('Provider', providerSelect),
        field('Model', modelSelect),
        field('API key', keyField),
        status,
        origin
      );

      const note = paragraph(
        'The key is kept in this browser and sent with each critique for the '
          + 'server to use and forget. It is never stored on the server, and '
          + 'nobody else who visits this page can use it.',
        'me-alert__recovery'
      );
      alert.append(note);

      // --- The skill ------------------------------------------------------
      const skill = this.config?.skill;
      alert.append(
        paragraph(
          skill
            ? `KONVO skill ${skill.summary} — ${skill.subject}`
            : 'No KONVO skill was deployed with this build.',
          'me-alert__recovery'
        )
      );
      if (skill) {
        alert.append(
          paragraph(
            skill.loaded
              ? 'Its critique pass is sent with every request, so the critique '
                + "is KONVO's whichever model answers."
              : 'Its critique pass was not deployed, so the critique will be '
                + 'generic.',
            'me-alert__recovery'
          )
        );
      }

      // --- Buttons --------------------------------------------------------
      const buttons = document.createElement('div');
      buttons.className = 'me-alert__buttons';

      const testResult = document.createElement('p');
      testResult.className = 'me-settings__status';

      const test = button('Test', '', async () => {
        const key = keyField.value.trim() || storedKey(providerID);
        if (key === '') {
          testResult.textContent = 'Enter a key first.';
          testResult.dataset.state = 'missing';
          return;
        }
        testResult.textContent = 'Asking…';
        delete testResult.dataset.state;
        try {
          const answer = await critiqueApi.test({
            provider: providerID,
            model: modelSelect.value,
            key,
          });
          testResult.textContent = answer.detail;
          testResult.dataset.state = 'ok';
        } catch (error) {
          testResult.textContent = error.message;
          testResult.dataset.state = 'missing';
        }
      });

      const remove = button('Remove', '', () => {
        removeKey(providerID);
        refresh();
        testResult.textContent = '';
      });

      const save = button('Save', 'me-button--default', () => {
        const typed = keyField.value.trim();
        if (typed !== '') saveKey(typed, providerID);
        setCurrentProvider(providerID);
        setCurrentModel(modelSelect.value, providerID);
        close(null);
        this.render();
      });

      buttons.append(test, remove, save);
      alert.append(testResult, buttons);
      refresh();
    });
  }
}
