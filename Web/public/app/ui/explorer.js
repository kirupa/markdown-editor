// Workspace file explorer (PRD X-*).
//
// The server does the listing, sorting, and hidden-file filtering so the rules
// match the macOS `FileTreeLoader` exactly. This is the presentation half:
// lazy expansion, selection, reveal, and the ancestor path dropdown.

import { api } from '../api.js';
import { showError } from './dialogs.js';

const TWISTY = '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M3.5 2 6.8 5 3.5 8" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';

const ICONS = {
  folder:
    '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M1.6 4.2a1.3 1.3 0 0 1 1.3-1.3h3l1.4 1.6h5.2a1.3 1.3 0 0 1 1.3 1.3v6a1.3 1.3 0 0 1-1.3 1.3H2.9a1.3 1.3 0 0 1-1.3-1.3z" fill="currentColor" opacity="0.85"/></svg>',
  markdown:
    '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.4 1.8h6L13 5.4v8.8H3.4z" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M9.2 1.9v3.6h3.6" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M5 11.6V8.2l1.5 1.9L8 8.2v3.4" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/></svg>',
  file: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.4 1.8h6L13 5.4v8.8H3.4z" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M9.2 1.9v3.6h3.6" fill="none" stroke="currentColor" stroke-width="1.2"/></svg>',
};

export class Explorer {
  /**
   * @param {object} elements
   * @param {HTMLElement} elements.tree
   * @param {HTMLButtonElement} elements.pathButton
   * @param {HTMLElement} elements.pathLabel
   * @param {HTMLButtonElement} elements.refreshButton
   * @param {HTMLButtonElement} elements.revealButton
   */
  constructor(elements) {
    this.tree = elements.tree;
    this.pathButton = elements.pathButton;
    this.pathLabel = elements.pathLabel;

    this.root = '';
    this.rootName = 'Workspace';
    this.ancestors = [];
    this.expanded = new Set();
    this.children = new Map();
    this.selectedPath = null;
    this.onOpenFile = () => {};
    this.onRevealRequested = () => {};

    this.pathMenu = document.createElement('ul');
    this.pathMenu.className = 'me-menu__list';
    this.pathMenu.setAttribute('role', 'menu');
    this.pathMenu.hidden = true;
    // The header is the positioned ancestor `.me-menu__list` expects.
    this.pathButton.parentElement.style.position = 'relative';
    this.pathButton.parentElement.append(this.pathMenu);

    elements.refreshButton.addEventListener('click', () => this.reload());
    elements.revealButton.addEventListener('click', () => this.onRevealRequested());
    this.pathButton.addEventListener('click', (event) => {
      event.stopPropagation();
      this.togglePathMenu();
    });
    document.addEventListener('click', () => this.closePathMenu());
  }

  async setRoot(path) {
    this.root = path;
    this.expanded.clear();
    this.children.clear();
    await this.reload();
  }

  async reload() {
    try {
      const payload = await api.tree(this.root);
      this.ancestors = payload.ancestors ?? [];
      this.rootName = this.ancestors.at(-1)?.name ?? this.rootName;
      this.children.set(this.root, payload.entries);

      // Re-fetch anything the user had open so a refresh does not collapse the
      // tree out from under them (X-6).
      for (const path of [...this.expanded]) {
        try {
          const child = await api.tree(path);
          this.children.set(path, child.entries);
        } catch {
          this.expanded.delete(path);
          this.children.delete(path);
        }
      }
      this.render();
    } catch (error) {
      showError(error);
    }
  }

  render() {
    this.pathLabel.textContent = this.rootName || '/';
    const entries = this.children.get(this.root) ?? [];
    if (entries.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'me-tree__empty';
      empty.textContent = 'This folder is empty.';
      this.tree.replaceChildren(empty);
      return;
    }
    this.tree.replaceChildren(...this.nodesFor(this.root));
  }

  nodesFor(parent) {
    const entries = this.children.get(parent) ?? [];
    return entries.flatMap((entry) => {
      const row = this.rowFor(entry);
      if (!entry.isDirectory || !this.expanded.has(entry.path)) return [row];
      const children = document.createElement('div');
      children.className = 'me-tree__children';
      children.setAttribute('role', 'group');
      const nested = this.nodesFor(entry.path);
      if (nested.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'me-tree__empty';
        empty.textContent = 'Empty';
        children.append(empty);
      } else {
        children.append(...nested);
      }
      return [row, children];
    });
  }

  rowFor(entry) {
    const row = document.createElement('div');
    row.className = 'me-tree__row';
    row.setAttribute('role', 'treeitem');
    row.dataset.path = entry.path;
    row.tabIndex = 0;
    row.setAttribute('aria-selected', String(entry.path === this.selectedPath));
    if (entry.isDirectory) {
      row.setAttribute('aria-expanded', String(this.expanded.has(entry.path)));
    }
    // X-9: non-Markdown files stay visible but read as unavailable.
    if (!entry.isDirectory && !entry.isMarkdown) row.classList.add('me-tree__row--other');

    const twisty = document.createElement('span');
    twisty.className = 'me-tree__twisty';
    if (entry.isDirectory) {
      twisty.innerHTML = TWISTY;
      twisty.addEventListener('click', (event) => {
        event.stopPropagation();
        this.toggleFolder(entry.path);
      });
    }

    const icon = document.createElement('span');
    icon.className = 'me-tree__icon';
    icon.innerHTML = entry.isDirectory
      ? ICONS.folder
      : entry.isMarkdown
        ? ICONS.markdown
        : ICONS.file;

    const label = document.createElement('span');
    label.className = 'me-tree__label';
    label.textContent = entry.name;

    row.append(twisty, icon, label);

    const activate = () => {
      if (entry.isDirectory) this.toggleFolder(entry.path);
      else this.onOpenFile(entry);
    };
    row.addEventListener('click', activate);
    row.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        activate();
      }
    });
    return row;
  }

  async toggleFolder(path) {
    if (this.expanded.has(path)) {
      this.expanded.delete(path);
      this.render();
      return;
    }
    try {
      if (!this.children.has(path)) {
        const payload = await api.tree(path);
        this.children.set(path, payload.entries);
      }
      this.expanded.add(path);
      this.render();
    } catch (error) {
      showError(error);
    }
  }

  select(path) {
    this.selectedPath = path;
    for (const row of this.tree.querySelectorAll('.me-tree__row')) {
      row.setAttribute('aria-selected', String(row.dataset.path === path));
    }
  }

  /** X-7: expand every ancestor of `path`, select it, and scroll it into view. */
  async reveal(path) {
    if (!path) return;
    const segments = path.split('/').filter(Boolean);
    let prefix = '';
    for (let index = 0; index < segments.length - 1; index += 1) {
      prefix = prefix ? `${prefix}/${segments[index]}` : segments[index];
      if (this.root !== '' && !prefix.startsWith(this.root)) continue;
      if (!this.children.has(prefix)) {
        try {
          const payload = await api.tree(prefix);
          this.children.set(prefix, payload.entries);
        } catch {
          return;
        }
      }
      this.expanded.add(prefix);
    }
    this.selectedPath = path;
    this.render();
    this.tree
      .querySelector(`[data-path="${cssEscape(path)}"]`)
      ?.scrollIntoView({ block: 'nearest' });
  }

  togglePathMenu() {
    if (!this.pathMenu.hidden) {
      this.closePathMenu();
      return;
    }
    // X-11/X-12: one folder basename per row, from the workspace root to here.
    this.pathMenu.replaceChildren(
      ...this.ancestors
        .slice()
        .reverse()
        .map((ancestor) => {
          const row = document.createElement('li');
          const option = document.createElement('button');
          option.type = 'button';
          option.className = 'me-menu__item';
          option.setAttribute('role', 'menuitem');

          const check = document.createElement('span');
          check.className = 'me-menu__check';
          check.textContent = ancestor.path === this.root ? '✓' : '';
          const label = document.createElement('span');
          label.textContent = ancestor.name;

          option.append(check, label);
          option.addEventListener('click', () => {
            this.closePathMenu();
            this.setRoot(ancestor.path);
          });
          row.append(option);
          return row;
        })
    );
    this.pathMenu.hidden = false;
    this.pathButton.setAttribute('aria-expanded', 'true');
  }

  closePathMenu() {
    this.pathMenu.hidden = true;
    this.pathButton.setAttribute('aria-expanded', 'false');
  }
}

function cssEscape(value) {
  return window.CSS?.escape ? window.CSS.escape(value) : value.replace(/"/g, '\\"');
}
