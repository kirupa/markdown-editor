// Workspace file explorer (PRD X-*).
//
// The server does the listing, sorting, and hidden-file filtering so the rules
// match the macOS `FileTreeLoader` exactly. This is the presentation half:
// lazy expansion, selection, reveal, and the ancestor path dropdown.

import { api } from '../api.js';
import { showError, showPrompt, confirmAction } from './dialogs.js';
import { showContextMenu } from './context-menu.js';

const TWISTY = '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M3.5 2 6.8 5 3.5 8" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';

/** Private to the sidebar, so a tree drag is never mistaken for a file drop. */
const ENTRY_DRAG_TYPE = 'application/x-markdown-editor-entry';

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
   * @param {HTMLButtonElement} elements.newDocumentButton
   * @param {HTMLButtonElement} elements.newFolderButton
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
    /** Every entry the sidebar has seen, so a path can be described. */
    this.entries = new Map();
    this.selectedPath = null;
    this.draggingPath = null;
    this.onOpenFile = () => {};
    this.onRevealRequested = () => {};
    this.onEntryCreated = () => {};
    this.onEntryMoved = () => {};
    this.onEntryDeleted = () => {};

    this.pathMenu = document.createElement('ul');
    this.pathMenu.className = 'me-menu__list';
    this.pathMenu.setAttribute('role', 'menu');
    this.pathMenu.hidden = true;
    // The header is the positioned ancestor `.me-menu__list` expects.
    this.pathButton.parentElement.style.position = 'relative';
    this.pathButton.parentElement.append(this.pathMenu);

    elements.refreshButton.addEventListener('click', () => this.reload());
    elements.revealButton.addEventListener('click', () => this.onRevealRequested());
    elements.newDocumentButton?.addEventListener('click', () => this.newDocument());
    elements.newFolderButton?.addEventListener('click', () => this.newFolder());
    this.pathButton.addEventListener('click', (event) => {
      event.stopPropagation();
      this.togglePathMenu();
    });
    document.addEventListener('click', () => this.closePathMenu());

    // Empty space below the rows still belongs to the folder being shown, so
    // it offers the same New items and accepts a drop.
    this.tree.addEventListener('contextmenu', (event) => {
      if (event.target.closest('.me-tree__row')) return;
      event.preventDefault();
      this.presentMenu(null, event.clientX, event.clientY);
    });
    this.tree.addEventListener('dragover', (event) => {
      if (event.target.closest('.me-tree__row') || !this.isEntryDrag(event)) return;
      if (this.isSelfOrDescendant(this.root)) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = 'move';
      this.tree.classList.add('me-sidebar__tree--drop');
    });
    this.tree.addEventListener('dragleave', (event) => {
      if (event.target === this.tree) this.tree.classList.remove('me-sidebar__tree--drop');
    });
    this.tree.addEventListener('drop', (event) => {
      this.tree.classList.remove('me-sidebar__tree--drop');
      if (event.target.closest('.me-tree__row') || !this.isEntryDrag(event)) return;
      if (this.isSelfOrDescendant(this.root)) return;
      event.preventDefault();
      this.moveEntry(this.draggingPath, this.root);
    });
  }

  async setRoot(path) {
    this.root = path;
    this.expanded.clear();
    this.children.clear();
    this.entries.clear();
    await this.reload();
  }

  /** Remembers a listing so any path on screen can be described later. */
  setChildren(path, entries) {
    this.children.set(path, entries);
    for (const entry of entries) this.entries.set(entry.path, entry);
  }

  async reload() {
    try {
      const payload = await api.tree(this.root);
      this.ancestors = payload.ancestors ?? [];
      this.rootName = this.ancestors.at(-1)?.name ?? this.rootName;
      this.setChildren(this.root, payload.entries);

      // Re-fetch anything the user had open so a refresh does not collapse the
      // tree out from under them (X-6).
      for (const path of [...this.expanded]) {
        try {
          const child = await api.tree(path);
          this.setChildren(path, child.entries);
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

    row.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      event.stopPropagation();
      this.select(entry.path);
      this.presentMenu(entry, event.clientX, event.clientY);
    });

    // WF-10: dragging a row onto a folder moves it there.
    row.draggable = true;
    row.addEventListener('dragstart', (event) => {
      this.draggingPath = entry.path;
      event.dataTransfer.effectAllowed = 'move';
      event.dataTransfer.setData(ENTRY_DRAG_TYPE, entry.path);
      row.classList.add('me-tree__row--dragging');
    });
    row.addEventListener('dragend', () => {
      this.draggingPath = null;
      row.classList.remove('me-tree__row--dragging');
      this.clearDropTarget();
    });

    if (entry.isExpandable) {
      row.addEventListener('dragover', (event) => {
        if (!this.isEntryDrag(event) || this.isSelfOrDescendant(entry.path)) return;
        event.preventDefault();
        event.stopPropagation();
        event.dataTransfer.dropEffect = 'move';
        this.clearDropTarget();
        row.classList.add('me-tree__row--drop');
      });
      row.addEventListener('dragleave', () => row.classList.remove('me-tree__row--drop'));
      row.addEventListener('drop', (event) => {
        row.classList.remove('me-tree__row--drop');
        if (!this.isEntryDrag(event) || this.isSelfOrDescendant(entry.path)) return;
        event.preventDefault();
        event.stopPropagation();
        this.moveEntry(this.draggingPath, entry.path);
      });
    }

    return row;
  }

  isEntryDrag(event) {
    return (
      this.draggingPath !== null && event.dataTransfer?.types.includes(ENTRY_DRAG_TYPE) === true
    );
  }

  /** A folder cannot receive the thing it already holds, or itself. */
  isSelfOrDescendant(folderPath) {
    const dragged = this.draggingPath;
    if (dragged === null) return true;
    if (folderPath === dragged || folderPath.startsWith(`${dragged}/`)) return true;
    return parentOf(dragged) === folderPath;
  }

  clearDropTarget() {
    for (const row of this.tree.querySelectorAll('.me-tree__row--drop')) {
      row.classList.remove('me-tree__row--drop');
    }
    this.tree.classList.remove('me-sidebar__tree--drop');
  }

  /**
   * The folder a new item belongs in: the selected folder, the folder holding
   * the selected file, or whatever the sidebar is currently rooted at.
   */
  targetFolder(entry = null) {
    const subject = entry ?? (this.selectedPath ? this.entries.get(this.selectedPath) : null);
    if (subject) return subject.isExpandable ? subject.path : parentOf(subject.path);
    // The open document may never have been listed; it is still a file, so its
    // folder is the right place for something new.
    return this.selectedPath ? parentOf(this.selectedPath) : this.root;
  }

  presentMenu(entry, x, y) {
    const folder = this.targetFolder(entry);
    const items = [];

    if (entry && !entry.isDirectory) {
      items.push({
        title: 'Open',
        disabled: !entry.isMarkdown,
        action: () => this.onOpenFile(entry),
      });
      items.push({ separator: true });
    }

    items.push(
      { title: 'New Document…', action: () => this.newDocument(folder) },
      { title: 'New Folder…', action: () => this.newFolder(folder) }
    );

    if (entry) {
      items.push(
        { separator: true },
        { title: 'Rename…', action: () => this.renameEntry(entry) },
        { title: 'Duplicate', action: () => this.duplicateEntry(entry) },
        { separator: true },
        { title: 'Delete…', action: () => this.deleteEntry(entry) }
      );
    }

    showContextMenu(items, x, y);
  }

  async newFolder(parent = this.targetFolder()) {
    const name = await showPrompt({
      title: 'New Folder',
      message: `The folder will be created in ${this.describeFolder(parent)}.`,
      value: 'untitled folder',
      confirmLabel: 'Create',
    });
    if (name === null) return;
    await this.perform(() => api.newFolder(parent, name), parent, (entry) => {
      // Showing it open, even when empty, confirms where it landed.
      this.expanded.add(entry.path);
      this.render();
    });
  }

  async newDocument(parent = this.targetFolder()) {
    const name = await showPrompt({
      title: 'New Document',
      message: `The document will be created in ${this.describeFolder(parent)}.`,
      value: 'Untitled.md',
      confirmLabel: 'Create',
    });
    if (name === null) return;
    await this.perform(
      () => api.newDocument(parent, name),
      parent,
      (entry) => this.onEntryCreated(entry)
    );
  }

  async renameEntry(entry) {
    const name = await showPrompt({
      title: `Rename “${entry.name}”`,
      message: entry.isDirectory
        ? 'Everything inside the folder keeps its place.'
        : 'Images belonging to the document move with it.',
      value: entry.name,
      confirmLabel: 'Rename',
    });
    if (name === null || name === entry.name) return;
    await this.perform(
      () => api.rename(entry.path, name),
      parentOf(entry.path),
      (renamed) => this.onEntryMoved(entry.path, renamed)
    );
  }

  async duplicateEntry(entry) {
    await this.perform(() => api.duplicate(entry.path), parentOf(entry.path));
  }

  async moveEntry(path, destination) {
    const entry = this.entries.get(path);
    if (!entry || destination === null) return;
    await this.perform(
      () => api.move(path, destination),
      destination,
      (moved) => this.onEntryMoved(path, moved)
    );
  }

  async deleteEntry(entry) {
    const confirmed = await confirmAction({
      title: `Delete “${entry.name}”?`,
      message: entry.isExpandable
        ? 'The folder and everything inside it are deleted immediately. This cannot be undone.'
        : 'It is deleted immediately. This cannot be undone.',
      confirmLabel: 'Delete',
    });
    if (!confirmed) return;

    try {
      await api.remove(entry.path);
    } catch (error) {
      showError(error);
      return;
    }

    this.expanded.delete(entry.path);
    this.children.delete(entry.path);
    this.entries.delete(entry.path);
    if (this.selectedPath === entry.path) this.selectedPath = null;
    await this.reload();
    this.onEntryDeleted(entry);
  }

  /**
   * Runs a change, then puts the sidebar back in a state that shows the
   * result: the containing folder open, the new item selected and scrolled to.
   */
  async perform(operation, revealIn, afterwards) {
    let entry;
    try {
      entry = await operation();
    } catch (error) {
      showError(error);
      return;
    }

    if (revealIn) this.expanded.add(revealIn);
    await this.reload();
    await this.reveal(entry.path);
    afterwards?.(entry);
  }

  describeFolder(path) {
    return path === '' ? this.rootName : `“${path.split('/').at(-1)}”`;
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
        this.setChildren(path, payload.entries);
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
          this.setChildren(prefix, payload.entries);
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

/** The workspace root is '', so a top-level item's parent is '' too. */
function parentOf(path) {
  const cut = path.lastIndexOf('/');
  return cut === -1 ? '' : path.slice(0, cut);
}
