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
4. [Parity with the native builds](#4-parity-with-the-native-builds)
5. [The workspace](#5-the-workspace)
6. [Welcome screen](#6-welcome-screen)
7. [Document lifecycle](#7-document-lifecycle)
8. [Editing modes](#8-editing-modes)
9. [Markdown language support and formatting](#9-markdown-language-support-and-formatting)
10. [Images and assets](#10-images-and-assets)
11. [File explorer](#11-file-explorer)
11a. [Managing files and folders](#11a-managing-files-and-folders)
11b. [Cloud storage and accounts](#11b-cloud-storage-and-accounts)
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
| WG-8 | Keep the Markdown logic *provably* identical to the macOS build rather than approximately similar (see [§4](#4-parity-with-the-native-builds)). |
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

## 4. Parity with the native builds

The [macOS](../macOS/README.md) and [iOS](../iOS/README.md) apps share their
Markdown engine as compiled Swift source, so they cannot drift from each other.
This build shares no runtime code with either — one side is Swift, the other
JavaScript — so its parity is *demonstrated* rather than assumed.

| ID | Requirement |
| --- | --- |
| WX-1 | `render-model.js` is a line-by-line port of `MarkdownRenderModel.swift`, and `formatting.js` of `MarkdownFormatting.swift`, preserving structure and naming so the two can be diffed by eye. |
| WX-2 | Ports rely on the fact that Swift's `NSString` offsets and JavaScript string indices are both UTF-16 code units, so every range in the Swift source is already correct in JavaScript with no conversion. |
| WX-3 | The ports were validated by differential testing against the compiled Swift: 14,148 formatting cases (every command against a corpus of documents and selections) and 41 documents through the render model, comparing rendered text, every style span, and every source ↔ rendered range mapping. Zero mismatches. |
| WX-4 | `themes.css` is **generated** by compiling the app's real `EditorColorTheme.swift` and printing the resulting colors, so derived values — blends, WCAG-contrast text picks — cannot drift. See `tools/generate-theme-css.swift`. That file now lives in `../Shared`; moving it was verified by regenerating this CSS and confirming it came out byte-identical. |
| WX-13 | The generated blends are AppKit's, which are computed in Apple's Generic RGB space rather than sRGB — black halfway to white is `0.573`, not `0.5`. This is a property of the palette, not of macOS, so the CSS is correct for every build. |
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
| WD-1 | **New** (`⌘N`) starts an untitled document on an empty **Heading 1** line, with the caret already inside it. Pressing Return there drops to a body paragraph, because a heading is not a list and has nothing to continue. Almost every document opens with a title, so the common shape needs no formatting command at all; the heading is ordinary text and deleting the `# ` leaves a blank document. |
| WD-2 | **Open** (`⌘O`) prompts for a workspace-relative path; clicking a file in the explorer opens it directly. |
| WD-3 | **Save** (`⌘S`) writes UTF-8 to the document's path. An untitled document prompts for a path first. |
| WD-4 | **Save As** (`⇧⌘S`) always prompts, and the entered path must end in `.md` or `.markdown`. |
| WD-5 | **Close** (`⌘W`) returns to an untitled document. |
| WD-6 | Any action that would abandon unsaved edits — New, Open, Close, opening from the explorer or the welcome list — first asks *Do you want to save the changes you made to …?* with **Don't Save**, **Cancel**, and **Save**. Cancel, and dismissing with `Escape`, abort the action and leave the document untouched. |
| WD-7 | If the Save triggered from that prompt is itself cancelled or fails, the original action is abandoned too. Unsaved work is never lost to a dialog. |
| WD-8 | Leaving the page with unsaved changes triggers the browser's own confirmation. |
| WD-9 | **Autosave:** edits to a document that already has a path are written 1.5 seconds after typing stops, and immediately when the tab is hidden. Untitled documents are never written without a path. |
| WD-13 | A save records the text it actually sent, captured before the request, not the text on screen when the reply arrives. Anything typed while a save is in flight stays unsaved and schedules another one. Reading the text again afterwards used to cost a skipped autosave; with [live updates](#live-updates) it would cost those keystrokes, because a revision is told apart from this browser's own echo by comparing against the last text saved. |
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
| WE-15 | The three modes are chosen with icons rather than words — a page, two panes, and the Markdown mark. They sit left of the formatting controls in a bar those controls already fill, and at that size three words crowd out the tools people reach for far more often. Each keeps its full name as its accessible name and shows it, with the shortcut, on hover, so nothing is only available to someone who recognises the picture. |
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
| WI-15 | `Add Image` first asks where the image comes from: **Choose File…** copies a file in beside the document (WI-3 … WI-13), **Image Address…** references one that is already on the web. Drag-and-drop and paste still go straight to the file route, since they already carry a file. |
| WI-16 | An image referenced by address is not copied or uploaded; the document points at the original URL. The address is percent-encoded so a space in it cannot break the reference, and a second prompt collects the alt text. |
| WI-17 | Clicking a rendered image selects it and opens a size panel under it, with width and height fields and a Reset button. Clicking elsewhere, or typing, clears the selection. |
| WI-18 | Editing either dimension derives the other from the image's own pixel size, so the aspect ratio is preserved. The number typed is kept exactly; the derived one is rounded, and never to zero — a very wide, very short image must not vanish. |
| WI-19 | A size is written as HTML: `<img src alt width height>`. Markdown has no syntax for dimensions, so this is the one place a reference changes form. Adding a size converts `![alt](path)` to a tag; Reset converts it back. The convention and the evidence behind it are in [`Contract/README.md`](../Contract/README.md). |
| WI-20 | Converting back to Markdown percent-encodes the path. An HTML attribute holds `my file.png` happily, but the same text in Markdown is not an image at all — GitHub renders it as literal text and the picture is lost. |
| WI-21 | An explicit size overrides the default display cap, bounded only by the width of the pane. A stale selection can never corrupt the document: if the recorded range is not exactly one image reference, the text is left untouched. |

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

## 11b. Cloud storage and accounts

Documents can live in one of two places, and the editor never guesses which.

| ID | Requirement |
| --- | --- |
| WR-1 | The welcome screen offers both storage options at once, with the active one marked **In use**. Where a document is saved is the one thing here that is hard to undo if it is not what you expected, so it is never a click away from being visible. |
| WR-2 | **On this server** is the default and works with no account: files in the workspace folder, exactly as before this section existed. Everything in [§5](#5-the-workspace) and [§11a](#11a-managing-files-and-folders) describes it. |
| WR-3 | **Your Google account** is the recommended option: sign in with Firebase Authentication and every document is stored in Firestore under that account, reachable from any device that signs in. |
| WR-4 | Switching storage closes the open document rather than carrying it across. A document from one place shown while saves go to the other is worse than closing it. |
| WR-5 | The status bar always says which storage is in use — `This device`, or `Cloud · your@email`. |
| WR-6 | Storage can also be switched from **File ▸ Connect Google Account…** and **File ▸ Use Files On This Device**. |
| WR-7 | Switching storage goes through the same unsaved-changes prompt as any other command that closes a document ([WD-6](#7-document-lifecycle)). |
| WR-8 | The remembered choice is restored at launch. Cloud is only restored if Firebase says the session is still valid; it never opens a sign-in window during boot, because an unrequested pop-up is blocked anyway. An expired session falls back to local storage and says so, rather than starting on an error. |
| WR-9 | Recent documents and the Saved for Later list are kept separately per storage mode. The same path names different documents in each, so one shared list would offer to open files that are not there. Local keeps the original keys, so an existing install loses nothing. |
| WR-10 | The Firebase SDK is only downloaded when an account is actually used. A local-only session fetches nothing from a CDN. |
| WR-11 | Every cloud failure is reported with a recovery step, never swallowed ([G-6](#2-goals-and-non-goals)). A closed sign-in window, a blocked pop-up, an unauthorised domain, a missing provider, unpublished rules, and a disabled Storage bucket each say what specifically to do. |

### How documents are stored

Firestore has no folders, so a tree is a reading of a `path` field on a flat
collection of nodes:

    users/{uid}/nodes/{documentId}      documentId = encodeURIComponent(path)

| Field | Meaning |
| --- | --- |
| `type` | `file`, `folder`, or `asset` |
| `path` | Workspace-relative path — the identity of the node |
| `parent` | The containing folder's path, `''` at the root |
| `name` | The last path component |
| `text`, `hasByteOrderMark`, `size` | Documents only |
| `storagePath`, `url`, `contentType` | Images only; the bytes live in Cloud Storage |

| ID | Requirement |
| --- | --- |
| WR-12 | Listing a folder is an equality query on `parent`, sorted in the client. Adding `orderBy` would make it a composite query that Firestore refuses to serve until an index is built by hand, so the app would not work the moment it was deployed. |
| WR-13 | Subtree operations use a range query on `path`, then **filter the result**. `path >= 'Notes'` also matches `Notes 2/Out.md` and `Notes.md`, because a range over strings knows nothing about separators — without the filter, renaming a folder would silently drag its similarly named siblings along. |
| WR-14 | Writes are committed in batches of 500, Firestore's limit. A batch is atomic; several are not, so every create is ordered before the delete it replaces. An interruption mid-move leaves documents duplicated rather than lost. |
| WR-15 | Naming rules match the local build exactly, verified against PHP's own output: duplicates become `stem-2.ext`, `PATHINFO` splits on the last dot wherever it is, and entries sort folders-first then `strnatcasecmp` order. |
| WR-16 | A document's `<stem>.assets` folder follows it through a rename, move, or duplicate, and the image references inside the document are rewritten — the same behaviour as [WM-8](#11a-managing-files-and-folders). A duplicated document gets its own copy of the image bytes, so deleting one cannot blank the other. |
| WR-17 | Deleting a document leaves its assets folder behind, as the local build does: it holds originals that may exist nowhere else. |
| WR-18 | Images go to Cloud Storage under `users/{uid}/`, capped at 10 MB. Firestore's 1 MiB document limit makes storing them inline too restrictive. Opening a document loads its image URLs first, so the renderer — which resolves image sources synchronously — has them ready. |
| WR-29 | **An image is uploaded with a real `image/*` content type, derived from its extension rather than taken on trust.** A `File` can arrive with an empty `type` — a drag from some applications, a paste, or a handle built by a script — and an upload with no type is stored as `application/octet-stream`, which the Storage rule refuses. The extension has already been checked against the accepted list by that point, so deriving the type from it is safe, and a declared type is only kept when it is itself an `image/*`. Without this, adding an image against published rules fails with a bare permission error and looks to the user like nothing happened. The same rule is applied identically by the native builds. |
| WR-30 | **The image URL cache follows a rename.** Image sources have to resolve synchronously ([WR-18](#11b-cloud-storage-and-accounts)), so URLs are cached by path when a document is read. Renaming a document or a folder moves the model in place without re-reading it, so every cached URL must be re-keyed at the same moment — including the sibling `<stem>.assets` folder, which is *not* a descendant of the document and so is missed by any subtree walk. Otherwise every image in a renamed document breaks until the page is reloaded. |
| WR-31 | **The client refuses an image that reaches the 10 MB limit, not one that exceeds it.** `storage.rules` allows `request.resource.size < 10 * 1024 * 1024`, so a file of exactly 10,485,760 bytes is refused by the server. Checking `>` accepted it here and then failed on upload with a bare permission error — the single outcome the client-side check exists to prevent. The native builds always drew the line correctly; this was the web build disagreeing with both them and the rule, and it only became reachable when the rules were published. |

### Live updates

A document open in a cloud account follows the account, not this browser. Both
phones and both laptops show the same thing without anyone reloading.

| ID | Requirement |
| --- | --- |
| WC-1 | Changes made elsewhere arrive on their own, through Firestore listeners rather than polling. A document saved on a phone appears on the laptop that has it open, and a file created on one device appears in the other's sidebar. |
| WC-2 | **Unsaved edits are never overwritten.** If a revision arrives while there are unsaved changes on screen, it is refused and the status bar says *Changed elsewhere — your edits are kept*. The document stays dirty, so the next save writes this browser's version: last write wins, and the person actually typing is the one who wins it. Everything else here is a convenience; this is the requirement the feature has to earn. |
| WC-3 | An adopted revision is one undo step, not a new history. `⌘Z` puts your text back, marks the document unsaved, and autosave sends it out again — so *no, mine* is a keystroke. An arriving change would otherwise be the only edit in the editor that could not be taken back. |
| WC-4 | A document deleted or moved on another device detaches: the text stays on screen and becomes permanently unsaved, so the next Save asks where to put it. This is the same path a local delete already used ([WF-9](#11a-managing-files-and-folders)). |
| WC-5 | This browser's own saves are silent. A write is recognised by comparing against the last text saved ([WD-13](#7-document-lifecycle)) rather than against the text on screen, which is what makes autosave-while-typing quiet: at that moment the two legitimately differ, and comparing against the screen would report every autosave as a change from another device. |
| WC-6 | Only what is on screen is watched: the open document, its images, and the folders the sidebar has expanded. The listener is the same equality query [WR-12](#11b-cloud-storage-and-accounts) already issues, so watching a folder costs what listing it once cost, needs no composite index, and grows with what is visible rather than with the size of the account. Collapsing a folder or closing a document detaches its listener. |
| WC-7 | **Local storage has no live channel, deliberately.** PHP on shared hosting offers no push, and polling the server on a timer would spend requests on a workspace only this browser can reach. The local backend answers the same three watch calls with a no-op, so nothing above it needs to know which storage is in use. |
| WC-8 | Watching is restarted when storage is switched, and stopped on the way out, so signing out cannot leave a listener running against the previous account. |

### Working offline

Cloud mode keeps a copy of what it has seen on the device, so losing the
network is not the same as losing the documents.

| ID | Requirement |
| --- | --- |
| WR-23 | Firestore is opened with a **persistent local cache** in IndexedDB, not the in-memory default. `getFirestore()` caches only for the life of the tab, so a reload with no signal would show an empty workspace — in cloud mode the server holds the only copy. Opened this way, a reload offline opens the same documents. |
| WR-24 | **The cache holds what this device has opened, not the whole account.** Firestore caches documents this client has read or written. A document written on another device and never opened here is not available offline. Calling the local copy a full backup would be wrong, and it is worth being plain about which half is true. |
| WR-25 | Edits made offline are queued locally and sent when the network returns. Firestore's writes resolve against the local cache immediately, so the editor behaves the same whether or not there is a connection, and [WC-2](#11b-cloud-storage-and-accounts) still decides who wins when a queued write meets a newer one. |
| WR-26 | **Images have a cache of their own,** because Firestore's persistence covers Firestore documents and nothing else — Cloud Storage objects are ordinary HTTPS downloads with no offline layer. Without one, an offline document opened with its text intact and every picture broken, which reads as damage rather than as unavailability. Image bytes are kept in IndexedDB and served as `blob:` URLs, so a document that has been opened once renders completely with no network. |
| WR-33 | **Entries are keyed by download URL, not by the path of the image.** Two things follow, and both are the reason for the choice. Renaming a document moves its images and the backend already carries each URL across, so a rename needs no cache bookkeeping at all. And a download URL carries a token that changes when the bytes behind it are replaced, so a replaced image *misses* rather than serving the picture it replaced: the cache cannot go stale, only empty. |
| WR-34 | **A miss is never a missing image.** If the bytes are not on the device, `imageURL` returns the download URL exactly as before, so the picture loads whenever the network is there. The cache can only improve on the previous behaviour, never fall short of it. |
| WR-35 | Bytes already on the device are adopted *before* a document is returned, so it renders complete rather than filling in afterwards. Bytes that are **not** there are downloaded in the background and not waited for: a miss only matters offline, and offline the download would fail anyway — blocking every document open on fetching its images would spend something real to buy something hypothetical. |
| WR-36 | An uploaded image is offline-ready immediately, cached from the bytes in hand rather than downloaded back from the server it was just sent to. |
| WR-37 | Deleting an image drops its bytes and releases its `blob:` URL. A browser that cannot store the bytes at all — private browsing, no quota, no IndexedDB — still renders normally for the session; only the offline guarantee is lost. |
| WR-38 | Cached images make the network cheaper as well as optional: an image is fetched once per device rather than once per document open. |
| WR-27 | Persistence is genuinely unavailable in some browsers — private browsing in parts of Safari and Firefox, and anywhere IndexedDB is switched off. That falls back to the in-memory cache with a console warning: offline support stops working, the editor still opens. Refusing to start would be the wrong trade. |
| WR-28 | The multi-tab manager is used, so two tabs of the editor share one cache. Without it only the first tab gets persistence and the others silently run without. |

### Where the image bytes live

Worth stating plainly, because it is the one piece of user data that is *not*
in Firestore.

| | Documents | Images |
| --- | --- | --- |
| Stored in | Firestore, `users/{uid}/nodes/{id}` | Cloud Storage, `users/{uid}/<path>#<timestamp>` |
| Firestore holds | the Markdown text itself | an `asset` node: `storagePath`, `url`, `contentType` |
| Size limit | 1 MiB per Firestore document, refused above ~900 KB | 10 MB per image, enforced in the client *and* in `storage.rules` |
| Offline | yes, once opened ([WR-23](#11b-cloud-storage-and-accounts)) | yes, once opened ([WR-26](#11b-cloud-storage-and-accounts)) |
| Governed by | `Web/firebase/firestore.rules` | `Web/firebase/storage.rules` |

Storing images inline in Firestore was considered and rejected: base64 inflates
bytes by about a third, against a hard 1 MiB document limit, which would cap an
image at roughly 700 KB *and* spend the same budget the document text needs. It
would buy offline images for free, which is the one real argument for it, but at
a size limit low enough to reject ordinary screenshots. That argument is now
spent anyway: [WR-26](#working-offline) buys offline images without the limit.

The Cache Storage API looks like the closer fit than IndexedDB for caching
downloads, and was rejected for a specific reason: the browser does not consult
it for an `<img src>` unless a service worker sits in front of every request.
A service worker brings its own scope, update lifecycle, and deployment story —
a large commitment for something needed in exactly one place. IndexedDB hands
back the bytes and the caller decides what to do with them.

The Markdown text never contains a Storage URL. It keeps the same relative
`<stem>.assets/name.png` reference the local and native builds write, and the
URL is resolved at render time from the `asset` node. That is what lets the same
document open in any of the four builds, and what lets a download URL be
rotated without rewriting anyone's prose.



`Web/public/app/cloud/config.js` contains the real Firebase configuration,
committed to a public repository on purpose. A Firebase web API key is an
identifier, not a credential: it names the project so the SDK knows where to
send requests, and every client that loads the app must have it. It grants
nothing on its own. [Google documents this
directly](https://firebase.google.com/docs/projects/api-keys).

What actually controls access is the Security Rules, which ship beside it:

- `Web/firebase/firestore.rules`
- `Web/firebase/storage.rules`

Both scope every document to the account that owns it, structurally — ownership
is the path, so it cannot be got wrong per-document. There is no rule that lets
one account reach another's documents.

### Setup steps that cannot be done from this repository

These are Firebase console actions. Until they are done, the cloud option will
fail, and it will say which of these is missing. They are kept here, done, so the
checks stay repeatable — a rule can be edited in the console at any time.

**Everything the web build needs is done, re-checked against the live project on
6 August 2026:** the rules are published, the Storage bucket exists, Google sign-in
is enabled, and `www.kirupa.com` is an authorised domain. One step remains, and it
affects the native builds only — registering an Apple app. The commands are below so
every check can be repeated rather than taken on trust.

| ID | Step |
| --- | --- |
| WR-32 | **Register an Apple app** under Project settings ▸ Your apps, with bundle ID `com.kirupa.markdown-editor`, and paste its app ID into `Shared/Firebase/Sources/MarkdownEditorFirebase/FirebaseConfiguration.swift`. **Outstanding — this is the only one left, and it affects the native builds only.** A Firebase app ID belongs to a registered app; the value there now is this project's *web* app ID with `web` changed to `ios`, which is well-formed and is not a real app. It is checked before sign-in opens a browser, so the native apps report the missing console step rather than a generic OAuth failure. One registration covers both the macOS and iOS apps, which share a bundle ID. Nothing in the web build is affected. |
| WR-19 | **Publish the security rules.** `firebase deploy --only firestore:rules,storage`, or paste both files into the console. **Done — verified 6 August 2026.** An unauthenticated REST call carrying only the public API key now returns `403 PERMISSION_DENIED` where it previously returned `200` and an empty result: `curl "https://firestore.googleapis.com/v1/projects/kirupa-markdown/databases/(default)/documents/users/probe/nodes?key=<apiKey>"`. An unauthenticated write returns `403` as well, and both an object read and a bucket list on Cloud Storage return `403`. The database is no longer open. |
| WR-20 | **Enable the Google sign-in provider** under Authentication ▸ Sign-in method. **Done — confirmed 6 August 2026.** `curl -X POST "https://identitytoolkit.googleapis.com/v1/accounts:createAuthUri?key=<apiKey>" -H 'Content-Type: application/json' -d '{"providerId":"google.com","continueUri":"https://www.kirupa.com/markdown/"}'` returns a real `authUri` carrying the project's OAuth client ID. A disabled provider answers `OPERATION_NOT_ALLOWED` instead — which is still what anonymous and email/password return, so neither of those is available as a fallback. |
| WR-21 | **Add the authorised domains** under Authentication ▸ Settings: `www.kirupa.com` for the published build, and `127.0.0.1` for local preview if you reach it by IP. `localhost` is allowed by default, but `127.0.0.1` is a different host string to Firebase — reaching the preview at `http://localhost:8000` avoids needing this. **`www.kirupa.com` is done — confirmed 6 August 2026** by the same call as [WR-20](#setup-steps-that-cannot-be-done-from-this-repository): it accepted that origin as a `continueUri`, which an unauthorised domain is refused for. |
| WR-22 | **Enable Cloud Storage** for the project, or image upload will fail. **Done — the bucket exists as of 6 August 2026.** `curl "https://firebasestorage.googleapis.com/v0/b/kirupa-markdown.firebasestorage.app/o"` now answers `403` rather than `404`; a bucket that does not exist answers `404`, which is still what the `.appspot.com` spelling returns, confirming `.firebasestorage.app` is the right name and that it is the one both builds are configured with. `403` is the expected answer to an unauthenticated list and is what publishing [WR-19](#11b-cloud-storage-and-accounts) will make permanent. No bucket CORS configuration is needed: the upload endpoint already answers a cross-origin preflight with `access-control-allow-origin: *`. |

### What has not been verified

Honest limits on the testing behind this section:

- The Google sign-in round trip cannot run in headless Chrome, and no test
  writes to the real database. Sign-in against the real project, and reading
  and writing real documents in a real Google account, remain **unverified**.
  What is no longer unverified is everything underneath that: the store, the
  queries, batch atomicity, and live delivery all now run against a real
  Firestore in the emulators ([WY-19](#tests), [WY-20](#tests)), including a
  genuine two-client test of `onSnapshot`. What is left is the identity
  provider, not the data path.
  What is checked directly is that every symbol the app imports from the pinned
  SDK is actually exported by it ([WY-14](#tests)) — a real check now, run by
  `Web/tools/check-firebase-sdk.mjs`, rather than the one-off inspection this
  previously described.
- What *is* verified: the rules themselves, by Firebase's own engine in the
  emulators ([WY-17](#tests)) — 29 checks, thirteen mutants killed. That closes
  the gap this section described for several revisions as unclosable. It was
  recorded as blocked on the live project having only Google sign-in enabled,
  which is true and is beside the point: the emulators run the same engine on
  the same files and hand out tokens freely. The block was never tested, only
  assumed.
- What *is* verified besides: the pinned SDK loads and initialises against this
  project,
  the store adapter builds against a real Firestore handle, the backend answers
  `config()` identically to the local one, and the cloud backend passes 30 tests
  against an in-memory Firestore that enforces the same query semantics —
  including the prefix-boundary case in [WR-13](#11b-cloud-storage-and-accounts),
  proven by mutation testing to fail when that filter is removed.
- Local storage is proven untouched by this change: the file tree, document
  reads, and image URLs all still work through the new façade.
- Offline persistence is verified at the seam and not beyond it. Five tests
  assert that Firestore is opened with a persistent, multi-tab cache and that an
  unavailable IndexedDB falls back rather than failing — mutation tested, four
  of them fail if the persistent cache is removed. What no test covers is a real
  browser reloading with the network off, because that needs a signed-in account
  against a live database, which is the same thing blocking everything else here.

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

## 12a. Mobile layout

A phone cannot use the desktop chrome. A menu bar is a row of hover targets, the
toolbar is twenty ~30px buttons on one line, the sidebar is docked, and the
status bar spends a row on text nobody taps. `View ▸ Mobile Layout` (`⌃⌘M`)
swaps all of it for an arrangement built for a touch screen — the *same*
commands, not a reduced editor: a two-row header, the explorer as a drawer, and
sheets in place of menus.

| ID | Requirement |
| --- | --- |
| WB-1 | A single Mobile Layout toggle replaces the menu bar, the desktop toolbar, and the status bar with a two-row header: a slim top bar and, docked beneath it, the formatting row. Nothing about the open document changes. |
| WB-2 | The choice persists in `localStorage` and survives a reload at any window size. |
| WB-3 | With no stored choice, the layout is guessed once from the device: a viewport ≤ 820px wide **or** a coarse pointer. After the user chooses, the guess never overrides them again. |
| WB-4 | The top bar holds, left to right: a **Files** button, the document name (with a `•` while unsaved), **Undo**, the **theme** picker, a **save this file for later** checkbox, and an overflow button. |
| WB-5 | The formatting row spans the header's full width and scrolls horizontally: paragraph style, bold, italic, underline, strikethrough, inline code, bulleted / numbered / task list, quote, code block, link, image, horizontal rule. Buttons show the styles active at the caret, exactly as the desktop toolbar does. |
| WB-6 | The app is sized to the space the keyboard leaves, measured through `visualViewport` rather than assumed, so nothing is left underneath the keys and the browser never scrolls the page to reveal the caret. The top of the header stays clear of the notch via `env(safe-area-inset-top)`, and the end of a document clears the home indicator via `env(safe-area-inset-bottom)`. |
| WB-7 | The overflow button opens a bottom sheet with Rich Text / Markdown, New Document, Save, and **Desktop Layout** — the way back out once there is no menu bar. |
| WB-8 | The **save for later** checkbox adds the open document to a list that is separate from recents. Recents reorder and age out, so simply using the editor would lose whatever you meant to return to; this list only changes when asked, is not capped, and keeps its order. |
| WB-9 | The checkbox is disabled for an untitled document, which has no path to remember. |
| WB-10 | A saved document that is renamed or moved keeps its place in the list; one that is deleted, or whose folder is deleted, is dropped from it. |
| WB-11 | Saved documents appear as their own section above Recent Documents on the welcome screen, and the welcome panel — a fixed 760 × 470 two-column card — stacks into one column on a narrow or short viewport instead of squeezing the document list off-screen. |
| WB-12 | The file explorer becomes an overlay drawer opened from the Files button and dismissed by tapping outside it. Its state is transient and does not overwrite the desktop sidebar preference. |
| WB-13 | Side by Side is unavailable, since a phone has no room for two columns; entering the mobile layout switches to Rich Text and leaving it restores Side by Side. |
| WB-14 | Every control is at least 36 × 36px, and buttons do not take focus, so a formatting tap acts on the live selection and does not dismiss the keyboard. |
| WB-28 | Keeping focus means cancelling `mousedown` and nothing else. A tap synthesizes `mousedown` before `click`, so cancelling it holds the selection on touch as well as with a mouse. Cancelling `touchstart` or `pointerdown` looks like the same idea and is not: it suppresses the whole compatibility chain, so `click` never fires and the control is dead on a phone. That is registered in one shared helper (`ui/keep-focus.js`) with one test, rather than re-derived at each button. |
| WB-29 | A control that keeps focus must still be draggable, because most of the formatting row's width is buttons and the row is scrolled by dragging along it. Cancelling `touchstart` would swallow that drag as well as the click. |
| WB-17 | The viewport is pinned: no pinch zoom, no double-tap zoom, and no dragging or rubber-banding the page behind the app. The app already fills the screen and every scroll happens inside a pane, so panning the page only slid the docked header out of reach. |
| WB-18 | Pinning takes three mechanisms because none alone is enough — the viewport meta tag for Android, `touch-action` for double-tap and pinch, and cancelled `gesture*` events plus two-finger drags for iOS Safari, which has ignored `user-scalable=no` since iOS 10. The `touch-action` is set on `<html>`, since the effective value is the intersection of an element's and all its ancestors'. |
| WB-19 | Leaving mobile restores the original meta tag and drops the listeners, so a phone deliberately switched to Desktop Layout keeps pinch zoom — the cramped desktop chrome is where zoom is actually wanted. |
| WB-20 | The formatting row is docked as the header's second row, directly beneath the top bar and directly above the document, and it stays there. Controls beyond the screen's width scroll horizontally, and the partly visible control at the edge is the affordance. |
| WB-21 | The row opts back into horizontal panning (`touch-action: pan-x`, which the root's `pan-x pan-y` permits — a root of `pan-y` would have intersected to allow nothing) and contains its own overscroll so a fling along it cannot pan the page or trigger a back-navigation. |
| WB-16 | A document scrolls all the way to its end with room to spare. The editor surface sizes to its content rather than to the pane, so its bottom padding lands at the end of the scroll range instead of inside a fixed frame where overflowing text scrolls straight past it. |
| WB-22 | Nothing focusable in the mobile layout uses text under 16px — not the editing surfaces, not the paragraph-style menu, not a field in any sheet, dialog, or the welcome panel. iOS Safari zooms the whole page in when you focus text smaller than that, and it does so regardless of `user-scalable=no`. Mobile body text is therefore 16px rather than the desktop 15px. |
| WB-23 | WB-22 exists because that one zoom is the cause of two symptoms that look unrelated: once the page is zoomed the layout viewport is wider than the screen, so the page slides sideways, and the fixed formatting bar is positioned against a viewport that no longer matches the screen, so it lands somewhere other than where it was put. Neither symptom is horizontal overflow — there is none at any iPhone width, even with unbreakable 90-character words and long bare URLs. |
| WB-24 | The formatting row does not move when the keyboard opens or closes. Its position is not a function of the keyboard, the accessory row above it, or the home indicator, so there is nothing to get wrong. |
| WB-25 | The `<html>` element carries a single `data-me-layout="mobile"` flag owned by the layout controller. The sheets, dialogs, and welcome panel render as siblings of the app root rather than inside it, so a rule scoped to the app cannot reach their controls; anything that must apply everywhere hangs off this flag. |
| WB-26 | The formatting row is docked in the header rather than floating above the keyboard, because the bottom of a phone screen is not a place a web page can rely on. The platform stacks its own furniture there — on iOS the keyboard's AutoFill and dismiss row, and the home indicator — a page cannot reserve space above it, and `visualViewport` does not reliably report it. Anything floating at the bottom ends up behind something. The header is the one region the platform leaves alone. |
| WB-27 | Docking costs the thumb-reach that put the tools at the bottom in the first place. That is the accepted trade: tools that are slightly further away beat tools that are partly unreachable, and the top of the screen is where a phone user already expects a document's controls. |
| WB-15 | Every mobile control calls the same command table the menus and desktop toolbar use, and all keyboard shortcuts keep working. There is no second implementation of any command. |

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
| `⌃⌘M` | Mobile Layout |

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
│   │   │   ├── recent-documents.js    ← RecentDocumentsCatalog.swift
│   │   │   └── saved-documents.js     Save-for-later list arithmetic
│   │   ├── dom-text.js        Text ↔ DOM offset mapping
│   │   ├── api.js             The storage contract; forwards to a backend
│   │   ├── backends/
│   │   │   ├── local.js               PHP: fetch, and no-op watchers
│   │   │   └── firestore.js           Cloud: the same shapes out of Firestore
│   │   ├── cloud/             Firebase: config, lazy SDK load, auth, store
│   │   ├── live.js            What to do when the server says it changed
│   │   ├── document.js        Document state, undo stack, autosave
│   │   ├── ui/                Surfaces, renderers, explorer, toolbar, menus,
│   │   │                      welcome, theme popover, dialogs, context menu,
│   │   │                      mobile bars and overflow sheet
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
| WA-9 | Storage is one interface with two implementations behind `api.js`, so nothing above it knows whether a document is on the server or in an account — including the watch calls, which the local backend answers with a no-op ([WC-7](#live-updates)). |
| WA-10 | What to do with a revision from elsewhere is a pure function of the model's state and the revision, separate from the subscription that delivers it. Every outcome — adopt, defer, detach, ignore — is decided in code reachable without a network, a DOM, or a timer, because that decision is where someone's work is at stake and it must be testable exhaustively. |
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
| WS-9 | A deploy places `app/` and `css/` under `v/<content-hash>/` and writes `asset-base.php` beside `index.php`, so every module URL changes together. A query string only versions the URLs the page writes; the imports *inside* a module are static paths no query string reaches, and a cache holding a new `main.js` against a stale `welcome.js` loads a module graph that fails outright. Relative imports inherit the versioned directory, so this needs no build step. |
| WS-10 | The hash is of the contents, so an unchanged deploy re-uses the directory and nothing is re-downloaded, and `mirror --delete` removes the previous one. |
| WS-11 | `.htaccess` marks `.php` no-cache — the page naming the assets must never outlive them — and denies `asset-base.php`, which is data for `index.php` rather than a page. |
| WS-8 | Whether or not there is a password, the deployment still contains itself: the classes, the starter documents, and every document live above the document root, `.htaccess` refuses `.md` files and directory listings under the served folder, and the workspace boundary ([§5](#5-the-workspace)) is enforced on every request. An open install can be edited by anyone; it still cannot be read *around*. |

### Tests

| Command | Covers |
| --- | --- |
| Open `/tests/` in a browser | The full client suite, including the DOM tests. Needs only PHP. |
| `node Web/tests/run.mjs` | The same client suites minus the DOM ones, plus the rules-conformance suite, which reads the `.rules` files and so cannot run in the browser. Node is optional and used only for a fast terminal loop. |
| `php Web/tests/php/run.php` | Workspace path safety, document read/write, file tree, file management, image import and its content validation, and how settings are read from the environment. |
| `Web/firebase/run-rules-checks.sh` | The security rules, evaluated by Firebase's own engine in the emulators ([WY-17](#tests)). Needs a JDK and the Firebase CLI, so it is not part of the suite. |
| `Web/firebase/run-cloud-checks.sh` | The real cloud store against a real Firestore, and against the in-memory double the suite runs on ([WY-19](#tests)). Same requirements. |
| `node Web/tools/check-firebase-sdk.mjs` | Every symbol the app imports from the pinned Firebase build is actually exported by it. Needs the network, so it is not part of the suite; run it after changing `FIREBASE_VERSION`. |

| ID | Requirement |
| --- | --- |
| WY-1 | The client suites are the source of truth for the ported core and run in the browser, so the environment under test is the one that ships. |
| WY-2 | The browser page and the node runner import the same list of modules, so they cannot disagree about what "the test suite" is. Two lists are environment-specific and named as such: the DOM tests need a browser, and the rules-conformance tests need to read files from the repository. |
| WY-3 | The PHP suite runs without PHPUnit or any other dependency. |
| WY-4 | Path-traversal, symlink-escape, invalid-UTF-8, mislabeled-image, and scriptable-SVG rejection are covered by tests, not just by inspection. |
| WY-5 | The DOM tests assert the invariant everything else rests on: each surface's text equals the model's text exactly, and every character offset round-trips through the DOM. |
| WY-6 | The environment lookup is tested against `$_SERVER` as well as `getenv`, because that difference is invisible locally and breaks a deployment. |
| WY-7 | File management is covered by tests that assert what must *not* happen: renaming or deleting a symlink leaves its target alone, a folder cannot be moved into itself, nothing is overwritten, and the workspace root cannot be renamed or deleted. |
| WY-10 | Gesture locking is verified by performing the gesture, not by reading a property, and always against a control: the same synthesized 2.5× pinch and horizontal drag must leave mobile at scale 1 and offset 0 *and* must still zoom and pan the desktop layout. Without the control case a harness that silently fails to dispatch anything looks like a pass. |
| WY-9 | Layout regressions are checked by measuring geometry, not by reading the DOM: the last block of a scrolled-to-the-end document must sit above the pane's bottom edge, in every editor mode and both layouts. Assertions on structure alone passed while a bar covered the text. |
| WY-8 | The saved-for-later list is pure list arithmetic in its own module, so ticking an already-ticked box, a rename, a delete, and a hand-edited `localStorage` value are all covered by unit tests rather than by clicking. |
| WY-12 | Every branch that can lose work is mutation-tested, not merely covered: the guard is removed, the suite must go red, and the guard is put back. Thirteen mutants across the live-update path — adopting over unsaved edits, dropping the echo check, recording the wrong text as saved, forgetting to claim a watcher slot — are each killed by a named test, and a no-op mutant is included to prove the harness can still report a survivor. |
| WY-13 | The live-update tests run against an in-memory Firestore whose watchers behave like the real ones, delivering current contents the moment a listener attaches. That attach snapshot is the source of the only two hazards found in this feature, so a double that skipped it would have hidden both. |
| WY-11 | Touch behaviour is verified by tapping, never by calling `element.click()`. A programmatic click invokes the handler directly and passes whether or not a real tap ever reaches it, which is how every button in the mobile layout came to be dead while every assertion passed. The check that a control does not cancel the events a tap depends on is a unit test, because `dispatchEvent` produces untrusted events that never synthesize a click and so cannot reproduce the failure in a DOM test. |
| WY-14 | The pinned Firebase build is checked against the symbols the app imports from it, by `Web/tools/check-firebase-sdk.mjs`. This is the one failure the suite structurally cannot reach: every cloud test runs against an in-memory double, deliberately, so the real SDK is never loaded and a symbol it stopped exporting would pass everything and break only in a browser after signing in. The symbol list is read out of `app/cloud/` rather than written down, so it cannot drift from what the app does — 23 symbols across auth, Firestore, and Storage at the time of writing. Mutation tested: adding an import the SDK does not export makes it fail. |
| WY-15 | **The in-memory Firestore refuses what the published rules refuse**, so every write in every test is checked against them rather than only against what the client needs. Before the rules were published any write passed, which meant a write the server would reject could pass the entire suite — and the rules were published against code that was already written and already tested. Mutation tested: dropping `parent` from a folder write turns 10 tests red, and renaming the `asset` type to one the rules do not list turns 7 red. |
| WY-16 | **The transcription of the rules is checked against the rules files themselves**, because a transcription that drifts from its source reports conformance that is no longer being checked. The type list, the required fields, both size limits, the image-size *comparison operator*, and the deny-by-default catch-all are all read out of `Web/firebase/*.rules` at test time. Mutation tested: changing the text limit, loosening the image comparison to `<=`, or opening the catch-all each turns the suite red. |
| WY-17 | **The rules are also evaluated, not only transcribed.** [WY-16](#tests) checks that the numbers in `Web/firebase/*.rules` still match the client's; it cannot check whether a rule does what it says. `Web/firebase/run-rules-checks.sh` starts the Firestore, Storage and Auth emulators and puts 29 checks through Firebase's own rules engine over plain HTTP — no test library and no Firebase SDK, so the no-dependencies rule ([WY-3](#tests)) still holds. It covers ownership in both directions, every required field, every accepted and rejected node type, both deny-by-default catch-alls, and each of the three limits *from both sides of its edge*, which is the class of defect a transcription cannot reach. Mutation tested: thirteen mutants — loosening a `<` to `<=` in any of the three limits, dropping an ownership clause, removing the type allow-list, narrowing `create, update` to `create`, and opening either catch-all — are each killed, against a green control. |
| WY-18 | The rule checks sign in through the **Auth emulator**, which issues ID tokens to anyone that asks. This is the whole reason they exist: the live project has only the Google provider enabled ([WR-20](#setup-steps-that-cannot-be-done-from-this-repository)), so a script cannot obtain a token for it, and for several revisions that was recorded here as making the rules unverifiable. It made them unverifiable *against the live project*. The emulators run the same engine on the same files under a `demo-` project id, which the CLI never takes to the network. |
| WY-19 | **The in-memory double is checked against a real Firestore.** Every cloud test runs against `support/memory-store.js`, deliberately — it is what makes the backend's decisions testable offline. The cost is that those tests are worth exactly what the double's resemblance to Firestore is worth, and nothing measured it. `Web/firebase/run-cloud-checks.sh` puts the same sequences through the double and through the shipped `firestore-store.js` against an emulated Firestore, and compares. It also covers what only a real Firestore has: that the range query in `subtreeOf` genuinely over-matches, so its filter is load-bearing rather than decoration; that a batch is refused whole when one write in it breaks the rules, which is what the create-before-delete ordering rests on; and that a multi-batch commit loses nothing. Thirteen checks, four mutants killed, with a no-op mutant surviving to prove the harness can still report one. |
| WY-20 | **Live updates are verified between two independent clients.** `watchChildren` and `watchNode` had only ever run against a double that announces changes synchronously from the object that stored them, which is not evidence that anything is delivered. The checks open a second Firebase app with its own Firestore instance and its own cache, signed in as the same account, so a write through it reaches the first client the way a phone reaches a laptop — through the server. Attach snapshot, a new document, an edit, and a deletion are each waited for. This closes the gap [§11b](#what-has-not-been-verified) recorded as unverifiable. |
| WY-21 | The app imports Firebase from a pinned CDN URL, which node will not resolve, so the checks map that one prefix onto a fetched copy with a resolve hook (`sdk-boot.mjs`) rather than changing the app or reimplementing its loader. The app's own modules are what run, including `loadFirebase`'s caching and `openFirestore`'s fallback when persistence is unavailable — which in node it always is, so [WR-25](#working-offline)'s fallback is exercised on every run rather than only reasoned about. |

---

## 16. Release history

| Change | What shipped |
| --- | --- |
| Cloud path run against a real Firestore | The store, the queries, batch atomicity and live updates now run against an emulated Firestore, and the in-memory double the whole suite depends on is compared against it ([WY-19](#tests), [WY-20](#tests)). Live delivery is tested between two independent clients, which is the two-device case that had never been exercised. Four mutants killed against a no-op control. Two survivors on the first sweep were both real findings: a local write reaches a listener **not at all** — there is no second, confirmed snapshot, so a check allowing one passed whether the echo skip worked or not — and the emulator does not enforce Firestore's 500-write batch limit, so that constant is guarded by reading it out of the source instead. The comment in `firestore-store.js` describing a later server echo was wrong and has been corrected. |
| Rules evaluated, not just transcribed | The security rules are now checked by Firebase's own engine in the emulators — 29 checks, thirteen mutants killed ([WY-17](#tests), `Web/firebase/run-rules-checks.sh`). This had been recorded for several revisions as impossible because the live project allows only Google sign-in; the Auth emulator hands out tokens freely, and the constraint had never actually been tested. It found one thing no transcription could: past Firestore's 1,048,487-byte property cap a write fails `400 INVALID_ARGUMENT` rather than `403`, and because the rules count *characters* it is the client's UTF-8 **byte** check that keeps documents out of that band ([Contract/README.md](../Contract/README.md#the-firestore-data-model)). |
| Remote images on the native builds | An image referenced by web address drew as a placeholder glyph on macOS and iOS, because only local files were ever loaded. Both now download and draw it. **The web build was never affected** — a browser loads `<img src>` itself — so nothing here changed, but the rules the native builds now follow are written down in [Contract/README.md](../Contract/README.md#drawing-an-image-held-at-a-web-address) so a fourth port does not repeat the bug. |
| Sized images and insert by address | Add Image now asks first: browse for a file, or paste a web address. A selected image can be given a width and a height that stay in proportion. A size is written as `<img …>` because GitHub renders `![alt](a.png =300x200)` as literal text — see [Contract/README.md](../Contract/README.md#how-an-image-carries-a-size) for the evidence. Shipped on all three builds in the same change; the shared core is byte-identical, so a document sized on a phone opens sized in a browser. |
| Rules published | The Firestore and Storage rules are live, so the database is no longer readable by anyone with the API key ([WR-19](#setup-steps-that-cannot-be-done-from-this-repository)). Publishing them made one latent disagreement reachable: the web build accepted an image of exactly 10 MB that the rule refuses ([WR-31](#11b-cloud-storage-and-accounts)). The in-memory Firestore now enforces the rules on every write, and the transcription is checked against the rules files themselves ([WY-15](#tests), [WY-16](#tests)). |
| Cloud images | The Storage bucket now exists, and the two things that would have stopped an image reaching it were fixed before it was tried: an upload with no content type was refused by the Storage rule ([WR-29](#11b-cloud-storage-and-accounts)), and the image URL cache did not follow a rename, so images in a renamed document broke until reload ([WR-30](#11b-cloud-storage-and-accounts)). Both apply to the native builds too. |
| Offline images | Cloud Storage objects are now cached on the device and served as `blob:` URLs, so a cloud document opened once renders completely with no network ([WR-26](#working-offline)…[WR-38](#working-offline)). Firestore's persistent cache covers Firestore documents only, so before this an offline document opened with its text intact and every picture broken. Entries are keyed by download URL, which makes a rename free and makes a replaced image miss rather than serve the picture it replaced. Verified in a real browser with real IndexedDB, the network cut by the debugger, and a control proving it was actually off. |
| Offline cloud documents | Firestore now opens with a persistent, multi-tab local cache, so a cloud workspace survives a reload with no network and edits made offline are queued and sent on reconnect ([§Working offline](#working-offline)). Firestore was previously opened the default way, which caches only for the life of the tab. Images are not covered ([WR-26](#working-offline)), and the two console steps blocking the rest of the cloud path were re-checked and are still outstanding ([WR-19](#setup-steps-that-cannot-be-done-from-this-repository), [WR-22](#setup-steps-that-cannot-be-done-from-this-repository)). |
| Live updates | Cloud documents and folders now update on every signed-in device as they change, without a reload, and unsaved edits are never overwritten by one ([§Live updates](#live-updates)). The mode switch became icons ([WE-15](#8-editing-modes)), and a new document now starts on a Heading 1 line ([WD-1](#7-document-lifecycle)). |
| Touch controls | Every button in the mobile layout was inert on a real phone — header icons, popovers, formatting, image insert — and the formatting row could not be scrolled by dragging along it. The buttons cancelled `touchstart` to hold the editor's selection, which also suppresses the `click` a tap generates ([WB-28](#12a-mobile-layout), [WB-29](#12a-mobile-layout)). |
| Cloud storage | Documents can be stored in a Google account through Firebase Authentication and Firestore, chosen from the welcome screen or the File menu, with local files still the default and unchanged ([§11b](#11b-cloud-storage-and-accounts)). |
| Docked tools | The formatting bar moved from floating above the keyboard to the header's second row, where the platform's own bottom furniture cannot cover it ([WB-20](#12a-mobile-layout), [WB-26](#12a-mobile-layout)). |
| iOS zoom | Focusing any text under 16px made iOS Safari zoom the page in, which slid it sideways and pushed the formatting bar under the keyboard's controls. Nothing focusable is under 16px now ([WB-22](#12a-mobile-layout)). |
| Pinned viewport | Mobile no longer pans or zooms ([WB-17](#12a-mobile-layout)). |
| Document end | The last lines of a document sat under the formatting bar with no way to scroll to them ([WB-16](#12a-mobile-layout)). |
| Asset versioning | Deployed assets moved under `v/<hash>/` after a CDN cached one module and not another, breaking the live page ([WS-9](#15-run-deploy-and-test)). |
| Mobile layout | An arrangement with no menu bar: a top bar carrying Undo, the theme picker, and a save-for-later checkbox, a formatting bar, the explorer as a drawer, and a responsive welcome screen ([§12a](#12a-mobile-layout)). |
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
- Sharing a document, or any collaboration. Cloud storage is per-account and
  private to it ([§11b](#11b-cloud-storage-and-accounts))
- Collaborative editing. Cloud documents do update live on every signed-in
  device ([§Live updates](#live-updates)), but two people typing in the same
  document at the same moment are not merged: whole revisions replace whole
  revisions, and unsaved edits win over an arriving one until they are saved
  ([WC-2](#live-updates))
- Live updates for documents stored on the server. That is a deliberate
  limit of a PHP-only backend, not an oversight ([WC-7](#live-updates))
- Migrating documents between local and cloud storage. Switching mode changes
  which documents exist, it does not copy them ([WR-4](#11b-cloud-storage-and-accounts))
- Sign-in providers other than Google
- Offline use for documents stored **on the server**. The PHP backend needs the
  server to be reachable. Cloud documents *do* work offline once they have been
  opened on the device ([WR-23](#11b-cloud-storage-and-accounts))
- Pre-caching images the device has **not** opened. Image bytes are kept for
  offline use once a document has been opened ([WR-26](#11b-cloud-storage-and-accounts)),
  which is the same bargain Firestore's own cache strikes
  ([WR-24](#11b-cloud-storage-and-accounts)): the device holds what it has seen,
  not the whole account
- A native app shell for phones; the mobile layout ([§12a](#12a-mobile-layout))
  is the browser page rearranged, not a packaged app
- Syncing the saved-for-later list between devices — it lives in `localStorage`,
  so it is per-browser until there are accounts
- Enlarging the text on a phone. Pinning the viewport ([WB-17](#12a-mobile-layout))
  removes pinch zoom, and there is no in-app text size control to replace it, so
  the mobile build currently offers no way to make text bigger. Mobile body text
  is 16px rather than the desktop 15px ([WB-22](#12a-mobile-layout)), but that is
  a fixed floor set to stop iOS auto-zoom, not an adjustable size. Desktop Layout
  is the only workaround. A text size preference is the fix
