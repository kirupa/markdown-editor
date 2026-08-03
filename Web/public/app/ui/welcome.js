// Welcome screen (PRD W-*).
//
// Shown at launch when the preference allows it, and reachable again from
// File ▸ Open Recent. Recents live in localStorage as workspace-relative
// paths, so the list survives moving the workspace to a different server.

import { api } from '../api.js';
import * as recents from '../core/recent-documents.js';
import * as saved from '../core/saved-documents.js';
import { showError } from './dialogs.js';

const RECENTS_KEY = 'markdown-editor.recents';
const SAVED_KEY = 'markdown-editor.savedForLater';
const SHOW_AT_LAUNCH_KEY = 'markdown-editor.showWelcomeAtLaunch';

const MARK =
  '<svg viewBox="0 0 48 48" class="me-welcome__mark" aria-hidden="true"><rect x="5" y="7" width="38" height="34" rx="6" fill="none" stroke="currentColor" stroke-width="3"/><path d="M13 32V18l6 7.5L25 18v14" fill="none" stroke="currentColor" stroke-width="3" stroke-linejoin="round"/><path d="M32 18v10m0 0 4-4m-4 4-4-4" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>';

const DOC_ICON =
  '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.4 1.8h6L13 5.4v8.8H3.4z" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M9.2 1.9v3.6h3.6" fill="none" stroke="currentColor" stroke-width="1.2"/></svg>';

export const recentDocuments = {
  all() {
    try {
      const stored = JSON.parse(localStorage.getItem(RECENTS_KEY) ?? '[]');
      return Array.isArray(stored) ? stored.filter((item) => typeof item === 'string') : [];
    } catch {
      return [];
    }
  },
  note(path) {
    if (!path) return;
    localStorage.setItem(RECENTS_KEY, JSON.stringify(recents.promoting(path, this.all())));
  },
  forget(path) {
    localStorage.setItem(RECENTS_KEY, JSON.stringify(recents.removing(path, this.all())));
  },
  clear() {
    localStorage.setItem(RECENTS_KEY, '[]');
  },
  get showAtLaunch() {
    return localStorage.getItem(SHOW_AT_LAUNCH_KEY) !== 'false';
  },
  set showAtLaunch(value) {
    localStorage.setItem(SHOW_AT_LAUNCH_KEY, value ? 'true' : 'false');
  },
};

/**
 * Documents the user explicitly kept (WB-8). Deliberately separate from
 * recents: recents reorder and age out, so simply using the editor would lose
 * whatever you meant to come back to.
 */
export const savedDocuments = {
  all() {
    try {
      const stored = JSON.parse(localStorage.getItem(SAVED_KEY) ?? '[]');
      return saved.normalized(Array.isArray(stored) ? stored : []);
    } catch {
      return [];
    }
  },
  write(paths) {
    localStorage.setItem(SAVED_KEY, JSON.stringify(paths));
    return paths;
  },
  includes(path) {
    return saved.contains(path, this.all());
  },
  set(path, wanted) {
    return this.write(
      wanted ? saved.adding(path, this.all()) : saved.removing(path, this.all())
    );
  },
  /** Keeps the list pointing at a document that was renamed or moved. */
  relocate(fromPath, toPath) {
    return this.write(saved.relocating(fromPath, toPath, this.all()));
  },
  forget(path) {
    return this.write(saved.removing(path, this.all()));
  },
  forgetUnder(folderPath) {
    return this.write(saved.removingUnder(folderPath, this.all()));
  },
  clear() {
    return this.write([]);
  },
};

export class WelcomeScreen {
  /**
   * @param {HTMLElement} root the backdrop element
   * @param {object} actions `newDocument`, `open`, and `openPath`
   */
  constructor(root, actions) {
    this.root = root;
    this.actions = actions;
    this.workspaceName = 'Workspace';

    // Clicking the backdrop dismisses, but only when a document is open behind it.
    root.addEventListener('click', (event) => {
      if (event.target === root && this.dismissable) this.hide();
    });
    this.dismissable = false;
  }

  get isVisible() {
    return !this.root.hidden;
  }

  show({ dismissable = false } = {}) {
    this.dismissable = dismissable;
    this.render();
    this.root.hidden = false;
  }

  hide() {
    this.root.hidden = true;
  }

  render() {
    const panel = document.createElement('div');
    panel.className = 'me-welcome';
    panel.append(this.buildSide(), this.buildMain());
    this.root.replaceChildren(panel);
  }

  buildSide() {
    const side = document.createElement('div');
    side.className = 'me-welcome__side';
    side.insertAdjacentHTML('beforeend', MARK);

    const title = document.createElement('h1');
    title.className = 'me-welcome__title';
    title.textContent = 'Markdown Editor';

    const subtitle = document.createElement('p');
    subtitle.className = 'me-welcome__subtitle';
    subtitle.textContent = 'A focused editor for Markdown documents.';

    const actions = document.createElement('div');
    actions.className = 'me-welcome__actions';

    const create = document.createElement('button');
    create.type = 'button';
    create.className = 'me-button me-button--default';
    create.textContent = 'New Document';
    create.addEventListener('click', () => {
      this.hide();
      this.actions.newDocument();
    });

    const open = document.createElement('button');
    open.type = 'button';
    open.className = 'me-button';
    open.textContent = 'Open…';
    open.addEventListener('click', () => {
      this.hide();
      this.actions.open();
    });

    actions.append(create, open);

    const footer = document.createElement('div');
    footer.className = 'me-welcome__footer';

    const checkbox = document.createElement('label');
    checkbox.className = 'me-checkbox';
    const toggle = document.createElement('input');
    toggle.type = 'checkbox';
    toggle.checked = recentDocuments.showAtLaunch;
    toggle.addEventListener('change', () => {
      recentDocuments.showAtLaunch = toggle.checked;
    });
    checkbox.append(toggle, document.createTextNode('Show this window at launch'));
    footer.append(checkbox);

    if (this.dismissable) {
      const dismiss = document.createElement('button');
      dismiss.type = 'button';
      dismiss.className = 'me-button';
      dismiss.textContent = 'Close';
      dismiss.addEventListener('click', () => this.hide());
      footer.append(dismiss);
    }

    side.append(title, subtitle, actions, footer);
    return side;
  }

  buildMain() {
    const main = document.createElement('div');
    main.className = 'me-welcome__main';

    const savedPaths = savedDocuments.all();
    if (savedPaths.length > 0) {
      main.append(
        this.buildSection({
          title: 'Saved for Later',
          paths: savedPaths,
          onClear: () => {
            savedDocuments.clear();
            this.render();
          },
          onMissing: (path) => savedDocuments.forget(path),
          limit: savedPaths.length,
        })
      );
    }

    main.append(
      this.buildSection({
        title: 'Recent Documents',
        paths: recentDocuments.all(),
        limit: undefined,
        emptyText: 'No recent documents yet.',
        onClear: () => {
          recentDocuments.clear();
          this.render();
        },
        onMissing: (path) => recentDocuments.forget(path),
      })
    );

    return main;
  }

  buildSection({ title, paths, limit, emptyText, onClear, onMissing }) {
    const section = document.createElement('section');
    section.className = 'me-welcome__section';

    const heading = document.createElement('div');
    heading.className = 'me-welcome__heading';
    const label = document.createElement('span');
    label.textContent = title;
    heading.append(label);

    if (paths.length > 0) {
      const clear = document.createElement('button');
      clear.type = 'button';
      clear.className = 'me-welcome__clear';
      clear.textContent = 'Clear';
      clear.addEventListener('click', onClear);
      heading.append(clear);
    }

    const list = document.createElement('div');
    list.className = 'me-welcome__recents';

    // The saved list is curated by hand, so it is shown whole; recents fall
    // back to the shared display limit.
    const items = recents.entries(paths, this.workspaceName, limit ?? undefined);
    if (items.length === 0) {
      const empty = document.createElement('p');
      empty.className = 'me-welcome__empty';
      empty.textContent = emptyText ?? '';
      list.append(empty);
    } else {
      list.append(...items.map((entry) => this.buildRecent(entry, onMissing)));
    }

    section.append(heading, list);
    return section;
  }

  buildRecent(entry, onMissing) {
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'me-recent';

    const icon = document.createElement('span');
    icon.className = 'me-recent__icon';
    icon.innerHTML = DOC_ICON;

    const text = document.createElement('span');
    text.className = 'me-recent__text';
    const name = document.createElement('span');
    name.className = 'me-recent__name';
    name.textContent = entry.name;
    const folder = document.createElement('span');
    folder.className = 'me-recent__folder';
    folder.textContent = entry.folderDisplayPath;
    text.append(name, folder);

    row.append(icon, text);
    row.addEventListener('click', async () => {
      try {
        // W-8: a recent entry whose file has since disappeared is removed
        // rather than opening onto an error.
        const check = await api.exists(entry.path);
        if (!check.exists) {
          onMissing(entry.path);
          this.render();
          return;
        }
        this.hide();
        await this.actions.openPath(entry.path);
      } catch (error) {
        showError(error);
      }
    });
    return row;
  }
}
