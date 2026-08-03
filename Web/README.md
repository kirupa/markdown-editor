# Markdown Editor for the Web — Product Requirements Document

The browser build of [Markdown Editor](../macOS/README.md). Same product, same
Markdown semantics, same keyboard shortcuts, same themes — served by PHP with
nothing installed on the host but PHP itself.

**Status:** Living document, kept in step with the macOS PRD.
**Requires:** PHP 8.1 or newer, and a browser released in the last two years.
**Dependencies:** none. No Composer, no npm, no bundler, no build step.
**Repository:** <https://github.com/kirupa/markdown-editor>

> **Maintenance rule:** every change that adds, removes, or alters a
> user-visible capability must update the matching requirement here, add a line
> to [Release history](#16-release-history), and — when the behavior is shared —
> stay consistent with the [macOS PRD](../macOS/README.md).

---

## Table of contents

1. [Product summary](#1-product-summary)
2. [Goals and non-goals](#2-goals-and-non-goals)
3. [Platform and hosting requirements](#3-platform-and-hosting-requirements)
4. [Parity with the macOS build](#4-parity-with-the-macos-build)
5. [The workspace](#5-the-workspace)
6. [Welcome screen](#6-welcome-screen)
7. [Document lifecycle](#7-document-lifecycle)
8. [Editing modes](#8-editing-modes)
9. [Markdown language support and formatting](#9-markdown-language-support-and-formatting)
10. [Images and assets](#10-images-and-assets)
11. [File explorer](#11-file-explorer)
11a. [Managing files and folders](#11a-managing-files-and-folders)
12. [Themes, typography, and layout](#12-themes-typography-and-layout)
13. [Keyboard shortcut reference](#13-keyboard-shortcut-reference)
14. [Architecture](#14-architecture)
15. [Run, deploy, and test](#15-run-deploy-and-test)
16. [Release history](#16-release-history)
17. [Out of scope / not yet supported](#17-out-of-scope--not-yet-supported)

---

## 1. Product summary

Markdown Editor for the Web is a single-page editor for Markdown files stored on
a server. As on macOS, **the Markdown source is always the canonical document**.
The rendered view is an editable projection of that source: edits made visually
are translated back into source text, and every character the author did not
touch survives byte for byte.

| ID | Requirement |
| --- | --- |
| WG-1 | The Markdown source is the document. Rendering never rewrites source the author did not edit. |
| WG-2 | Files are read and written as UTF-8, preserving a byte order mark if the file had one. |
| WG-3 | The app is one HTML page, a handful of ES modules, two stylesheets, and one PHP endpoint. |
| WG-4 | No action fails silently. Every server and client error is presented in a modal alert with a recovery suggestion. |
| WG-5 | The editor never requires a build step, package manager, or rewrite rules. |

---

## 2. Goals and non-goals

### Goals

| ID | Goal |
| --- | --- |
| WG-6 | Reproduce the macOS editor's behavior closely enough that the same PRD describes both. |
| WG-7 | Deploy by copying a folder onto any PHP host. |
| WG-8 | Keep the Markdown logic *provably* identical to the macOS build rather than approximately similar (see [§4](#4-parity-with-the-macos-build)). |
| WG-9 | Work with the keyboard alone, and remain usable with a screen reader. |

### Non-goals

| ID | Non-goal |
| --- | --- |
| WNG-1 | Multi-user editing, accounts, or authentication. One workspace, and whoever can reach it. Accounts are planned by way of Firebase rather than built here. |
| WNG-2 | Real-time collaboration or conflict resolution. |
| WNG-3 | A database. State is the filesystem plus `localStorage`. |
| WNG-4 | A JavaScript framework or a CSS framework. |
| WNG-5 | Server-side rendering of Markdown. Rendering happens in the browser, from the same code the tests exercise. |

---

## 3. Platform and hosting requirements

| ID | Requirement |
| --- | --- |
| WP-1 | PHP 8.1 or newer with the standard library. No extensions beyond a default build are used. |
| WP-2 | Runs under Apache, nginx + PHP-FPM, PHP's built-in server, or any host that can execute a `.php` file. |
| WP-3 | Needs no URL rewriting. Every request is either a real file or `api.php?action=…`. |
| WP-4 | Needs no writable directory other than the workspace folder itself. |
| WP-5 | The browser must support ES modules, `contenteditable`, `beforeinput`, and CSS custom properties. |
| WP-6 | Client code is served as-is. Nothing is minified, transpiled, or bundled, so what runs is what is in the repository. |

---

## 4. Parity with the macOS build

The two builds share no runtime code — one is Swift, the other JavaScript — so
parity is *demonstrated* rather than assumed.

| ID | Requirement |
| --- | --- |
| WX-1 | `render-model.js` is a line-by-line port of `MarkdownRenderModel.swift`, and `formatting.js` of `MarkdownFormatting.swift`, preserving structure and naming so the two can be diffed by eye. |
| WX-2 | Ports rely on the fact that Swift's `NSString` offsets and JavaScript string indices are both UTF-16 code units, so every range in the Swift source is already correct in JavaScript with no conversion. |
| WX-3 | The ports were validated by differential testing against the compiled Swift: 14,148 formatting cases (every command against a corpus of documents and selections) and 41 documents through the render model, comparing rendered text, every style span, and every source ↔ rendered range mapping. Zero mismatches. |
| WX-4 | `themes.css` is **generated** by compiling the app's real `EditorColorTheme.swift` and printing the resulting colors, so derived values — blends, WCAG-contrast text picks — cannot drift. See `tools/generate-theme-css.swift`. |
| WX-5 | The JavaScript suites assert the same expectations as the Swift suites, and both builds' tests must pass before a change ships. |

### Deliberate differences

These follow from the platform and are intentional.

| ID | Difference |
| --- | --- |
| WX-6 | Documents live in a server-side **workspace** folder rather than anywhere on disk ([§5](#5-the-workspace)). |
| WX-7 | Open and Save As use in-page prompts over workspace-relative paths, because the web has no `NSOpenPanel`/`NSSavePanel` for server files. |
| WX-8 | Adding an image uses a file input (or drag-and-drop, or paste), and the file is uploaded to the server rather than copied locally. |
| WX-9 | Images in the rendered view load through `api.php?action=asset`, since the browser cannot read a workspace path directly. |
| WX-10 | Recent documents, editor mode, sidebar state, pane widths, and theme live in `localStorage` instead of `UserDefaults`. |
| WX-11 | There is no "become the default handler" flow; that is a Finder concept. |
| WX-12 | `⌘W` closes the document, not the browser tab, which no page may do. |

---

## 5. The workspace

Everything the editor can see lives under one folder. This is the security
boundary and it is enforced on the server, not in the client.

| ID | Requirement |
| --- | --- |
| WW-1 | The workspace root is `~/kirupaMarkdown`, or the path in the `MARKDOWN_EDITOR_WORKSPACE` environment variable. |
| WW-1a | The folder is created on first run if it is not there, and seeded with the starter documents in `Web/seed`. Seeding happens only at creation, so an existing folder is never written into. |
| WW-1b | The default sits in the home directory rather than in the checkout, so updating the editor cannot touch documents and the folder can be moved into a sync service. Where there is no usable home directory, `Web/kirupaMarkdown` is used instead. |
| WW-2 | Every path from the client is workspace-relative. Absolute paths are rejected. |
| WW-3 | Paths are normalized before use: `.` segments are dropped, `..` segments are resolved, and repeated separators collapse. Any path that resolves outside the root is rejected. |
| WW-4 | Resolution is performed against the *real* path of the parent directory, so a symlink pointing outside the workspace cannot be used to escape it — while still allowing paths for files that do not exist yet. |
| WW-5 | Only `.md` and `.markdown` files may be opened, read, or written as documents. |
| WW-6 | If the workspace folder is missing or unreadable, the page itself says so, with the path and how to fix it, instead of failing inside a request the author cannot see. |
| WW-7 | Rejections are explicit errors with recovery text — never a silent empty result. |
| WW-8 | The workspace root may itself be a symlink, so it can point at a folder managed by a sync client. The root resolves to the real folder; escaping it still fails. |
| WW-9 | A workspace at iCloud Drive's root is displayed as *iCloud Drive*, not as the internal `com~apple~CloudDocs` folder name. |

### Putting the workspace in cloud storage

Because documents are plain files, syncing them is a matter of where the
workspace points — there is nothing to export or migrate.

```bash
MARKDOWN_EDITOR_WORKSPACE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Notes" Web/serve.sh
MARKDOWN_EDITOR_WORKSPACE="$HOME/Dropbox/Notes" Web/serve.sh
```

A symlink works too, which is convenient on a server:

```bash
ln -s "$HOME/Dropbox/Notes" ~/kirupaMarkdown
```

Two things to know before relying on it:

- **A hosted deployment needs no sync at all.** Put the app on one machine and
  every device reaches the same files through a browser. Sync is only worth
  setting up when you also want the macOS app, or offline access to the files.
- **Two devices editing the same document at the same time will produce a
  conflict copy.** Autosave writes 1.5 seconds after typing stops, so the window
  is small but real. The editor does no merging; the sync client's conflict file
  is what you get. See [WNG-2](#2-goals-and-non-goals).

---

## 6. Welcome screen

| ID | Requirement |
| --- | --- |
| WV-1 | On launch the editor shows a welcome overlay with New Document, Open…, and a list of recent documents. |
| WV-2 | Recent documents are workspace-relative paths held in `localStorage`, most recent first, with duplicates collapsed. |
| WV-3 | Each row shows the file name and the containing folder, so two `index.md` files are distinguishable. |
| WV-4 | The list is capped at the same limit the macOS build uses. |
| WV-5 | A recent entry that no longer exists is removed from the list when opening it fails, and the failure is reported. |
| WV-6 | A "Show this window at launch" checkbox persists the preference; when off, the editor opens straight into an untitled document. |
| WV-7 | `File ▸ Open Recent…` reopens the welcome overlay at any time, and it can be dismissed without choosing anything. |
| WV-8 | The overlay is themed like the rest of the app. |

---

## 7. Document lifecycle

| ID | Requirement |
| --- | --- |
| WD-1 | **New** (`⌘N`) starts an untitled empty document. |
| WD-2 | **Open** (`⌘O`) prompts for a workspace-relative path; clicking a file in the explorer opens it directly. |
| WD-3 | **Save** (`⌘S`) writes UTF-8 to the document's path. An untitled document prompts for a path first. |
| WD-4 | **Save As** (`⇧⌘S`) always prompts, and the entered path must end in `.md` or `.markdown`. |
| WD-5 | **Close** (`⌘W`) returns to an untitled document. |
| WD-6 | Any action that would abandon unsaved edits — New, Open, Close, opening from the explorer or the welcome list — first asks *Do you want to save the changes you made to …?* with **Don't Save**, **Cancel**, and **Save**. Cancel, and dismissing with `Escape`, abort the action and leave the document untouched. |
| WD-7 | If the Save triggered from that prompt is itself cancelled or fails, the original action is abandoned too. Unsaved work is never lost to a dialog. |
| WD-8 | Leaving the page with unsaved changes triggers the browser's own confirmation. |
| WD-9 | **Autosave:** edits to a document that already has a path are written 1.5 seconds after typing stops, and immediately when the tab is hidden. Untitled documents are never written without a path. |
| WD-10 | The status bar shows the document name, an "Edited" marker while dirty, and the result of the last save. |
| WD-11 | A byte order mark present when the file was read is written back; one that was absent is never added. |
| WD-12 | Undo (`⌘Z`) and Redo (`⇧⌘Z`) operate on the source text. Consecutive typing within 600 ms coalesces into one undo step, so undo moves in meaningful units. |

---

## 8. Editing modes

| ID | Requirement |
| --- | --- |
| WE-1 | **Rich Text** (`⌃⌘1`) — edit the rendered document directly. |
| WE-2 | **Side by Side** (`⌃⌘2`, the default) — rendered on the left, raw Markdown on the right, both editable. |
| WE-3 | **Markdown** (`⌃⌘3`) — raw source with representative typography. |
| WE-4 | The chosen mode persists across reloads. |
| WE-5 | In Rich Text, markers (`**`, `#`, `` ` ``) are hidden and the styling they describe is shown instead. |
| WE-6 | Editing the rendered view maps the change back through the source ↔ rendered range mapping and rewrites only the affected source range. |
| WE-7 | An image is one atomic, non-editable unit: the caret cannot enter it, and deleting it removes the whole `![…](…)`. |
| WE-8 | In Side by Side, scrolling either pane scrolls the other to the same normalized position, without feedback loops. |
| WE-9 | In Side by Side, moving the caret or selection in one pane mirrors it into the other through the same range mapping. |
| WE-10 | Formatting commands apply to whichever pane last had focus, so clicking a toolbar button never redirects the edit. |
| WE-11 | The Markdown pane shows every marker verbatim while giving headings, body text, and code their representative sizes and weights — size and weight only, matching `MarkdownSourceStyler`. |
| WE-12 | Copy and cut place Markdown source on the clipboard from either pane; paste inserts text as Markdown. |
| WE-13 | Input Method Editor composition is left alone until it commits, so non-Latin input works normally. |
| WE-14 | The rendered and source panes always contain exactly the text the model says they should. This is asserted by tests that compare the DOM's plain text against the model, and round-trip every character offset through the DOM. |

---

## 9. Markdown language support and formatting

The supported language is exactly the macOS build's — see
[macOS PRD §7](../macOS/README.md#7-markdown-language-support). Summarized:

ATX headings 1–6, paragraphs, hard line breaks, `**bold**`, `*italic*`,
`~~strikethrough~~`, `<u>underline</u>`, `` `inline code` ``, fenced code blocks,
block quotes, bulleted, numbered, and task lists, links, images, horizontal
rules, and backslash escapes.

Every formatting command is available from the toolbar, the menu bar, and a
keyboard shortcut, and every one of them toggles:

| ID | Requirement |
| --- | --- |
| WF-1 | Inline styles (bold, italic, underline, strikethrough, inline code) wrap the selection, or insert an empty pair with the caret between the markers. |
| WF-2 | Applying an inline style to text that already has it removes the markers. |
| WF-3 | Headings replace whichever heading level a line already has; applying the same level again returns the line to body text. |
| WF-4 | List commands convert every line the selection touches, and re-number numbered lists from 1. |
| WF-5 | Applying the same list type again removes the markers. |
| WF-6 | Block quote prefixes each selected line with `> `, and toggles off. |
| WF-7 | Code block wraps the selection in fences on their own lines, and toggles off. |
| WF-8 | Horizontal rule inserts `---` on its own line. |
| WF-9 | Link prompts for a URL and wraps the selection, or inserts `[](url)` with the caret positioned to type the text. |
| WF-10 | Every command preserves the selection sensibly — text stays selected, and an inserted empty pair leaves the caret between the markers. |
| WF-11 | The toolbar highlights the inline styles, heading level, and list type active at the caret, and updates as the caret moves. |
| WF-12 | Commands operate on the source through the same pure functions the macOS build uses, so a command applied in either build produces byte-identical text. |

---

## 10. Images and assets

| ID | Requirement |
| --- | --- |
| WI-1 | Imported images are copied into `<document-stem>.assets/` beside the document — `post.md` uses `post.assets/`. |
| WI-2 | The inserted reference is relative: `![alt](post.assets/photo.png)`. |
| WI-3 | Images can be added from the toolbar, `Insert ▸ Add Image…` (`⇧⌘I`), drag-and-drop onto either pane, or paste. All four paths run the same import. |
| WI-4 | Multiple files dropped or chosen at once are imported in order. |
| WI-5 | Supported formats: BMP, GIF, HEIC, HEIF, JPEG, JPG, PNG, SVG, TIF, TIFF, WEBP. Anything else is refused by name and by content. |
| WI-6 | Alt text defaults to the file's base name. |
| WI-7 | A name already taken in the assets folder gets `-2`, `-3`, … before the extension. An existing file is never overwritten. |
| WI-8 | Spaces and other characters that are unsafe in a URL are percent-encoded in the reference, while the file on disk keeps its original name. |
| WI-9 | The reference is inserted at the caret, or replaces the selection, in whichever pane has focus. A dropped image lands where it was dropped, including in the empty space beside a line. |
| WI-10 | An image cannot be imported into an untitled document; the editor says so and offers to save first. |
| WI-11 | If `<document-stem>.assets` exists but is a file or a symlink, the import is refused rather than following it. |
| WI-12 | Uploads are validated on the server: extension allowlist, real image content, and containment inside the workspace. A client that lies is rejected. |
| WI-13 | Rendered images load through `api.php?action=asset`, which serves only image extensions from inside the workspace, with `X-Content-Type-Options: nosniff`. |
| WI-14 | An image that cannot be loaded shows a labeled placeholder rather than a broken-image icon — and that placeholder contributes no characters to the document text. |

---

## 11. File explorer

| ID | Requirement |
| --- | --- |
| WL-1 | A sidebar lists the workspace tree, expandable folders first, then everything else, each alphabetical and case-insensitive. |
| WL-2 | Folders expand lazily; a folder's children are fetched the first time it opens. |
| WL-3 | Hidden entries — names beginning with `.` — are not listed. |
| WL-3a | A symlink is listed, but it cannot be expanded, so the tree can never wander outside the workspace by following one. Packages such as `Foo.app` are listed and not expandable for the same reason: they are directories the user means as files. |
| WL-4 | Markdown files open on click. Non-Markdown files report that they cannot be opened. |
| WL-5 | The current document's row is selected, and the tree expands to reveal it. |
| WL-6 | A Reveal button re-expands to the current document; a Refresh button re-reads the tree from disk. |
| WL-7 | The header is a dropdown listing the current folder and each ancestor up to the workspace root; choosing one re-roots the tree. |
| WL-8 | The sidebar can be hidden (`⌃⌘S`), and its width dragged; both persist. |
| WL-9 | Selection colors are derived from the active theme so the selected row is legible in all sixteen theme combinations. |

---

## 11a. Managing files and folders

The macOS build leaves this to Finder, which is one Cmd-Tab away. A browser has
no such neighbour, so the sidebar has to be a file manager too — otherwise the
workspace is a folder nobody can reorganize without leaving the app.

| ID | Requirement |
| --- | --- |
| WM-1 | The sidebar header has **New Document** and **New Folder** buttons; both are also in the File menu (`⌃⌘N` and `⇧⌘N`). |
| WM-2 | Right-clicking a row opens a context menu: Open, New Document…, New Folder…, Rename…, Duplicate, Delete…. Right-clicking empty space offers the two New items for the folder on screen. |
| WM-3 | New items are created in the selected folder, in the folder holding the selected file, or at the sidebar root — and the prompt names which. |
| WM-4 | A new document with no extension gets `.md`. It is created empty and opened immediately. |
| WM-5 | Names are validated on the server and refused with a reason: no slashes, no leading period, no control characters, not `.` or `..`, not empty, 255 bytes at most, valid UTF-8. |
| WM-6 | Creating, renaming, moving, or duplicating onto a name that already exists is refused. Nothing is ever overwritten. |
| WM-7 | Renaming a Markdown document to a name with no extension keeps the original one. Renaming it to a *different* extension is refused, because the editor could no longer open it. |
| WM-8 | A document's `<stem>.assets` folder follows it through a rename or a move, and the image references inside the document are rewritten to match — in both the percent-encoded and plain spellings. A duplicate gets its own copy of the folder. If the destination assets name is taken, the whole operation is refused and nothing moves. |
| WM-9 | The open document survives all of this. Renamed or moved, it follows the file. Deleted, its text stays on screen and becomes unsaved, and Save offers the path it used to have — deleting a file in the sidebar can never take away work still in front of you. |
| WM-10 | A row can be dragged onto a folder, or onto empty space to reach the root. The destination highlights, and a folder cannot be dropped into itself or its own descendants. |
| WM-11 | Delete asks first, says whether a folder takes its contents with it, and says it cannot be undone — there is no Trash on a server. A document's `.assets` folder is deliberately *not* deleted with it; it holds original images, and it is visible in the sidebar to remove separately. |
| WM-12 | Every operation acts on the item itself, never on what a symbolic link points at. Deleting a link removes the link; the folder behind it is untouched. |
| WM-13 | Duplicates are named `name-2`, then `name-3`, matching how imported images avoid collisions ([I-8](#10-images-and-assets)). Folders are copied recursively. |
| WM-14 | After any change the sidebar reopens the containing folder, selects the new item, and scrolls it into view. |

---

## 12. Themes, typography, and layout

| ID | Requirement |
| --- | --- |
| WT-1 | Eight colors — Blue, Yellow, Pink, Green, Purple, Pico-8, Black, Brown — on an independent Light/Dark axis: sixteen combinations, transcribed from kirupa.com. |
| WT-2 | `View ▸ Customize Theme…` opens a popover with color swatches, a Light/Dark toggle, a live preview, and **Cancel** / **Apply**. |
| WT-3 | The popover holds *draft* state: the preview updates as choices are made, Apply commits, Cancel restores what was active. |
| WT-4 | Each swatch is drawn in its own theme's colors. |
| WT-5 | The theme applies to the entire app — canvas, sidebar, both editor panes, inline code, fenced code, selection, and the welcome overlay. |
| WT-6 | The theme persists across reloads and is applied before first paint, so there is no flash of the wrong theme. |
| WT-7 | The theme is two attributes on `<html>`; `themes.css` does the rest. Nothing recolors elements in JavaScript. |
| WT-8 | Headings, body text, and code use the same size scale as the macOS build, in both panes. |
| WT-9 | A fenced code block is drawn as one continuous rounded rectangle behind all of its lines, not one box per line. |
| WT-10 | The rendered pane is centered within a readable measure whose width is draggable and persists. |
| WT-11 | Horizontal rules render as a centered em dash, matching the macOS build. |
| WT-12 | The sidebar divider and the pane divider are drag handles with `separator` roles. |

---

## 13. Keyboard shortcut reference

`⌘` is Command on macOS and Control elsewhere.

| Shortcut | Action |
| --- | --- |
| `⌘N` | New |
| `⌘O` | Open… |
| `⌃⌘N` | New Document in Folder… |
| `⇧⌘N` | New Folder… |
| `⌘S` | Save |
| `⇧⌘S` | Save As… |
| `⌘W` | Close document |
| `⌘Z` / `⇧⌘Z` | Undo / Redo |
| `⌘A` | Select All |
| `⇧⌘I` | Add Image… |
| `⌘K` | Link… |
| `⌃⌘H` | Horizontal Rule |
| `⌘B` / `⌘I` / `⌘U` | Bold / Italic / Underline |
| `⌃⌘K` | Strikethrough |
| `⌘E` / `⇧⌘E` | Inline Code / Code Block |
| `⌘0` | Body |
| `⌘1` … `⌘6` | Heading 1 … 6 |
| `⇧⌘7` / `⇧⌘8` / `⇧⌘9` | Bulleted / Numbered / Task list |
| `⌃⌘Q` | Block Quote |
| `⌃⌘1` / `⌃⌘2` / `⌃⌘3` | Rich Text / Side by Side / Markdown |
| `⌃⌘S` | Show File Explorer |

---

## 14. Architecture

```
Web/
├── serve.sh                   Local preview: php -S, nothing else
├── deploy.sh                  Publish to a shared PHP host over FTPS
├── bootstrap.php              A nine-line autoloader — no Composer
├── seed/                      Starter documents, copied into a new workspace
├── src/                       The server
│   ├── Workspace.php          Path resolution and the security boundary
│   ├── WorkspaceError.php     Message + recovery suggestion, as JSON
│   ├── DocumentStore.php      UTF-8 read/write, BOM handling, .md validation
│   ├── FileTree.php           One directory level, sorted, filtered
│   ├── FileManager.php        Create, rename, move, duplicate, delete
│   ├── ImageImporter.php      Upload validation, assets folder, collisions
│   └── Api.php                One dispatch table for every action
├── public/                    The document root
│   ├── index.php              The only page
│   ├── api.php                The only endpoint
│   ├── icon.svg
│   ├── css/
│   │   ├── themes.css         Generated from EditorColorTheme.swift
│   │   └── app.css            Layout, typography, components
│   ├── app/
│   │   ├── core/              Ported from Swift; no DOM, no network
│   │   │   ├── range.js               NSRange arithmetic
│   │   │   ├── render-model.js        ← MarkdownRenderModel.swift
│   │   │   ├── formatting.js          ← MarkdownFormatting.swift
│   │   │   ├── text-difference.js     ← TextDifference.swift
│   │   │   └── recent-documents.js    ← RecentDocumentsCatalog.swift
│   │   ├── dom-text.js        Text ↔ DOM offset mapping
│   │   ├── api.js             fetch wrapper; every failure becomes an ApiError
│   │   ├── document.js        Document state, undo stack, autosave
│   │   ├── ui/                Surfaces, renderers, explorer, toolbar, menus,
│   │   │                      welcome, theme popover, dialogs, context menu
│   │   └── main.js            Wiring: commands, modes, panes, startup
│   └── tests/                 The browser test page and the JS suites
└── tests/
    ├── run.mjs                Optional node runner for the same suites
    └── php/                   Server-side suites
```

| ID | Requirement |
| --- | --- |
| WA-1 | `app/core/` is pure: no DOM, no network, no globals. It is the ported Swift core and is tested in isolation. |
| WA-2 | The server is stateless. Every request is resolved against the workspace from scratch. |
| WA-3 | `api.php?action=…` is the entire protocol: `config`, `tree`, `read`, `exists`, `write`, `create`, `newDocument`, `newFolder`, `rename`, `move`, `duplicate`, `delete`, `upload`, `asset`. |
| WA-4 | Reads are GET; anything that writes requires POST. |
| WA-5 | Errors are `{ "error": …, "recovery": … }` with a non-200 status, and the client turns every one into a modal alert. |
| WA-6 | Both editor panes are the same `EditorSurface` controller, parameterized by a projection that says how to render, how to read text, and how to map ranges. The rendered and source panes differ only in that object. |
| WA-7 | An edit is applied by diffing the surface's text against what the model expects, mapping that difference to a source range, and replacing it — so the browser's own editing behavior is used, but the source stays canonical. |
| WA-8 | `Workspace::resolve()` follows symlinks and is used for reading *through* a path; `Workspace::resolveEntry()` resolves every ancestor but leaves the final component alone, and is used for acting *on* an item. Renaming or deleting through the first would operate on a link's target instead of the link. |

---

## 15. Run, deploy, and test

### Local preview

```bash
git clone https://github.com/kirupa/markdown-editor.git
cd markdown-editor
Web/serve.sh
```

Then open <http://127.0.0.1:8000/>. The first run creates `~/kirupaMarkdown`
with a couple of starter documents and opens it; after that the folder is yours,
and the editor leaves it alone. Pass a port as the first argument, and point
`MARKDOWN_EDITOR_WORKSPACE` somewhere else to edit a different folder:

```bash
MARKDOWN_EDITOR_WORKSPACE=~/Documents/Notes Web/serve.sh 9000
```

### Deploying

If you control the document root, there is almost nothing to do:

1. Copy `Web/` to the server.
2. Point the document root at `Web/public`.
3. Make sure the workspace folder is writable by the web server. It is created
   on first request if it is missing.
4. There is no step 4. No build, no install, no configuration file.

Only `Web/public` needs to be reachable. `Web/src`, `Web/bootstrap.php`,
`Web/seed`, and `Web/tests` are read by PHP but never served.

#### On shared hosting, where you cannot move the document root

Most shared hosts give you one document root and a URL subdirectory. The app
splits in two: what has to be reachable goes under the document root, and
everything else — including the documents — goes above it, where the web server
will not serve it however it is asked.

```
~/markdown-editor/        bootstrap.php, src/, seed/     ← above the document root
~/kirupaMarkdown/         the documents                  ← above the document root
~/public_html/markdown/   index.php, api.php, app/, css/ ← served, at /markdown/
```

Two `SetEnv` lines in `.htaccess` are the whole configuration:

```apache
SetEnv MARKDOWN_EDITOR_HOME /home/you/markdown-editor
SetEnv MARKDOWN_EDITOR_WORKSPACE /home/you/kirupaMarkdown
```

`Web/deploy.sh` does all of this over FTPS, including generating that
`.htaccess`. It takes its settings from the environment and its password from
`~/.netrc`, so no host name and no credential is ever written into the
repository. Run it with `--dry-run` first to see exactly what would be sent.

| ID | Requirement |
| --- | --- |
| WS-1 | `MARKDOWN_EDITOR_HOME` tells the two public entry points where the rest of the app lives. Unset, they use the layout in this repository, so a normal install needs no configuration. |
| WS-2 | Settings are read from `getenv()` *and* `$_SERVER`. `SetEnv` reaches only the second on some CGI and LiteSpeed builds, and `putenv` reaches only the first — reading one would work locally and fail on a host. |
| WS-3 | `deploy.sh` uploads from a staging copy containing only the files it lists, so a local edit, a test fixture, or a scratch document cannot reach the server by accident. `tests/` is never deployed. |
| WS-4 | The deployment is self-configuring: the generated `.htaccess` names the paths the app was actually installed at, so it cannot drift from them. |
| WS-5 | `deploy.sh` uses `lftp` when it is present, because `mirror --delete` stops a redeploy leaving the previous version's files behind, and falls back to `curl`, which is on every machine. |
| WS-6 | **The editor has no accounts, no sessions, and no permissions of its own.** Anyone who can reach the URL can read, change, and delete every document in the workspace. |
| WS-7 | Setting `MDE_HTPASSWD` puts the whole install behind HTTP Basic Auth, as a stopgap for a workspace that should not be open. Leaving it unset deploys the app to anyone who finds the URL, which is the right choice only for a workspace whose contents are meant to be public. |
| WS-8 | Whether or not there is a password, the deployment still contains itself: the classes, the starter documents, and every document live above the document root, `.htaccess` refuses `.md` files and directory listings under the served folder, and the workspace boundary ([§5](#5-the-workspace)) is enforced on every request. An open install can be edited by anyone; it still cannot be read *around*. |

### Tests

| Command | Covers |
| --- | --- |
| Open `/tests/` in a browser | The full client suite, including the DOM tests. Needs only PHP. |
| `node Web/tests/run.mjs` | The same client suites minus the DOM ones. Node is optional and used only for a fast terminal loop. |
| `php Web/tests/php/run.php` | Workspace path safety, document read/write, file tree, file management, image import and its content validation, and how settings are read from the environment. |

| ID | Requirement |
| --- | --- |
| WY-1 | The client suites are the source of truth for the ported core and run in the browser, so the environment under test is the one that ships. |
| WY-2 | The browser page and the node runner import the same list of modules, so they cannot disagree about what "the test suite" is. |
| WY-3 | The PHP suite runs without PHPUnit or any other dependency. |
| WY-4 | Path-traversal, symlink-escape, invalid-UTF-8, mislabeled-image, and scriptable-SVG rejection are covered by tests, not just by inspection. |
| WY-5 | The DOM tests assert the invariant everything else rests on: each surface's text equals the model's text exactly, and every character offset round-trips through the DOM. |
| WY-6 | The environment lookup is tested against `$_SERVER` as well as `getenv`, because that difference is invisible locally and breaks a deployment. |
| WY-7 | File management is covered by tests that assert what must *not* happen: renaming or deleting a symlink leaves its target alone, a folder cannot be moved into itself, nothing is overwritten, and the workspace root cannot be renamed or deleted. |

---

## 16. Release history

| Change | What shipped |
| --- | --- |
| Published build | A split layout for hosts that cannot repoint the document root, and `Web/deploy.sh` to publish over FTPS ([§15](#15-run-deploy-and-test)). |
| File management | A default `~/kirupaMarkdown` workspace, created and seeded on first run, plus create, rename, move, duplicate, and delete for files and folders from the sidebar ([§11a](#11a-managing-files-and-folders)). |
| Repository restructure | macOS and Web builds separated into `macOS/` and `Web/`. |
| Web build, initial release | The full editor: welcome screen, document lifecycle with autosave, three editing modes with a WYSIWYG rendered surface, every formatting command, image import from four sources, the file explorer, all sixteen themes, the menu bar and its shortcuts — on a PHP-only backend with no dependencies. |

---

## 17. Out of scope / not yet supported

Inherited from the macOS build:

- Tables, footnotes, definition lists, and other extended Markdown syntax
- Nested lists beyond a single level of markers
- Setext (underlined) headings
- Reference-style links and images
- Export to HTML, PDF, or anything else
- Spell checking beyond the browser's own
- Find and replace

Specific to the web build:

- Multiple documents open at once
- Undoing a file operation — delete is final ([WM-11](#11a-managing-files-and-folders))
- Moving files by dragging them out of, or into, the operating system's file manager
- Any form of authentication. Basic Auth at the web server is the stopgap
  ([WS-7](#15-run-deploy-and-test)); real accounts are intended to arrive with a
  Firebase integration, which is also what would make more than one person's
  workspace possible
- Offline use; the editor needs the server to read and write files
