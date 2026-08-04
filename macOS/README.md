# Markdown Editor — Product Requirements Document

A dependency-free native macOS Markdown editor built with SwiftUI and AppKit.
The [web build](../Web/README.md) reimplements this same product for the
browser; this document is the specification both builds are held to.

**Status:** Living document. Written retroactively to describe everything the
app supports as of the current `main`.
**Bundle identifier:** `com.kirupa.markdown-editor`
**Platform:** macOS 13.0 or newer
**Repository:** <https://github.com/kirupa/markdown-editor>

> **Maintenance rule:** this PRD is the canonical description of the product.
> Every change that adds, removes, or alters a user-visible capability must
> update the matching requirement here in the same commit, and add a line to
> [Release history](#17-release-history).

---

## Table of contents

1. [Product summary](#1-product-summary)
2. [Goals and non-goals](#2-goals-and-non-goals)
3. [Platform and technical requirements](#3-platform-and-technical-requirements)
4. [Welcome window](#4-welcome-window)
5. [Document lifecycle](#5-document-lifecycle)
6. [Editing modes](#6-editing-modes)
7. [Markdown language support](#7-markdown-language-support)
8. [Formatting commands](#8-formatting-commands)
9. [Images and assets](#9-images-and-assets)
10. [Links](#10-links)
11. [File explorer](#11-file-explorer)
12. [Themes and appearance](#12-themes-and-appearance)
13. [Typography and layout](#13-typography-and-layout)
14. [Keyboard shortcut reference](#14-keyboard-shortcut-reference)
15. [Architecture](#15-architecture)
16. [Build, run, and test](#16-build-run-and-test)
17. [Release history](#17-release-history)
18. [Out of scope / not yet supported](#18-out-of-scope--not-yet-supported)

---

## 1. Product summary

Markdown Editor is a single-window-per-document macOS app for writing and
editing Markdown files. Its defining characteristic is that **the Markdown
source is always the canonical document**. The app offers a rendered,
directly-editable view of that source, but it never converts the document into
a proprietary rich-text model — every keystroke resolves back to exact
Markdown text on disk.

Three surfaces are provided over the same document: a rendered editor, a raw
source editor, and a synchronized side-by-side split of both. A file explorer
sidebar allows browsing and opening files without leaving the app, and a
welcome window offers recent documents at launch.

---

## 2. Goals and non-goals

### 2.1 Goals

| ID | Goal |
| --- | --- |
| G-1 | Edit Markdown with exact text fidelity — what is typed is what is saved. |
| G-2 | Offer WYSIWYG editing without giving up round-trip accuracy to Markdown. |
| G-3 | Feel like a native macOS document app: standard File menu, standard dialogs, standard undo, standard shortcuts. |
| G-4 | Ship with zero third-party dependencies. |
| G-5 | Make image insertion safe and portable, with assets stored next to the document. |
| G-6 | Never fail silently — every file, image, and encoding error is surfaced to the user. |

### 2.2 Non-goals

| ID | Non-goal |
| --- | --- |
| NG-1 | Being a general-purpose CommonMark or GitHub Flavored Markdown reference implementation. |
| NG-2 | Exporting to HTML, PDF, or other formats. |
| NG-3 | Cloud sync, collaboration, or multi-user editing. |
| NG-4 | Plugin or extension support. |
| NG-5 | iOS, iPadOS, or cross-platform support. |

---

## 3. Platform and technical requirements

| ID | Requirement |
| --- | --- |
| P-1 | Minimum deployment target is macOS 13.0. |
| P-2 | Built as a Swift package with `swift-tools-version: 6.0`. |
| P-3 | Uses only SwiftUI, AppKit, Foundation, and UniformTypeIdentifiers. No third-party packages are permitted. |
| P-4 | Ships as an ad-hoc-signed `.app` bundle produced from the package; no Xcode project is required. |
| P-5 | Declares `LSApplicationCategoryType` of `public.app-category.developer-tools` and is high-resolution capable. |
| P-6 | Declares `NSShowAppCentricOpenPanelInsteadOfUntitledFile` as `false` so systems that honor it do not raise an Open panel at launch. |
| P-7 | Ships an `AppIcon.icns` and a `MarkdownDocument.icns`, both drawn from source by a script using only Core Graphics and `iconutil`. |

### 3.1 Package layout

| Target | Kind | Purpose |
| --- | --- | --- |
| `MarkdownEditorCore` | Library | Pure, UI-free logic: Markdown parsing, formatting transforms, image import, file scanning, text encoding, diffing. Fully unit tested. |
| `MarkdownEditor` | Executable | The SwiftUI/AppKit application layer. |
| `MarkdownEditorCoreTests` | Test | Unit tests for `MarkdownEditorCore`. |

The split exists so that all logic that can be tested without a running app
*is* tested without a running app.

---

## 4. Welcome window

The app launches to a landing window instead of an empty untitled document, so
the first decision — new file, existing file, or something recent — is made
before anything is on screen.

### 4.1 When it appears

| ID | Requirement |
| --- | --- |
| W-1 | On a plain launch with nothing to restore, nothing opened from Finder, and no document handed over by another app, the welcome window is shown and centered. |
| W-2 | The welcome window is **not** shown when the app is launched by opening a document, or when macOS restores previously open documents. Those launches go straight to the document, with no momentary appearance of the welcome window. |
| W-3 | Clicking the Dock icon while the app is running with no visible windows shows the welcome window. |
| W-4 | **Window ▸ Welcome to Markdown Editor** shows it at any time, including alongside open documents. |
| W-5 | A **Show this window at launch** checkbox controls W-1. Unchecking it restores the standard macOS launch behavior for document apps. The setting persists in `showsWelcomeWindowAtLaunch` and defaults to on. |

Three AppKit launch paths are covered, because the system picks between them:

1. **The classic untitled-document path,** via `applicationOpenUntitledFile(_:)`.
2. **The app-centric Open panel** that recent macOS releases raise on behalf of
   `DocumentGroup` without ever consulting the delegate. The panel is dismissed
   during `applicationDidFinishLaunching(_:)` before the landing window appears.
   `NSShowAppCentricOpenPanelInsteadOfUntitledFile` is also set to `false` in the
   bundle so systems that honor it never construct the panel at all.
3. **Window restoration,** where AppKit does neither of the above and instead
   reopens the previous session's documents *after* launch finishes — measured at
   roughly a third of a second later on macOS 26. Showing the landing window
   immediately would make it appear and then be replaced, so this path waits for
   `NSApplication.didFinishRestoringWindowsNotification` and then only shows the
   landing window if nothing arrived. That notification is not posted when there
   is nothing to restore, so a short timeout backs it up.

The distinction between paths 2 and 3 is that AppKit only raises its Open panel
when it has nothing to restore, which makes the panel's presence a reliable
signal that the landing window can be shown without waiting.

### 4.2 When it goes away

| ID | Requirement |
| --- | --- |
| W-6 | The welcome window closes automatically as soon as a **newly opened** document window becomes main — whether it came from this window, the File menu, Finder, or Open Recent. |
| W-7 | Activating a document window that was already open does **not** close the welcome window, so opening it deliberately while working is not self-defeating. |
| W-8 | The Open panel raised from this window does not dismiss it. Cancelling that panel leaves the welcome window in place. |
| W-9 | The window can be closed manually. It has no minimize or zoom button and is not resizable. |

### 4.3 Actions

| ID | Requirement |
| --- | --- |
| W-10 | **New Document** creates an untitled document. It is the window's default button, so Return triggers it. |
| W-11 | **Open…** presents the standard document Open panel, filtered to the app's Markdown types. |
| W-12 | Both actions route through the same responder-chain commands as the File menu, so behavior is identical to `⌘N` and `⌘O`. |

### 4.4 Recent documents

| ID | Requirement |
| --- | --- |
| W-13 | The window lists recently opened or saved Markdown documents, most recent first, showing the filename, its containing folder, and the file's modification date. |
| W-14 | Folder paths inside the user's home directory are abbreviated to `~`, matching Finder. Paths elsewhere are shown in full. Long paths truncate in the middle. |
| W-15 | Clicking an entry opens that document. |
| W-16 | Up to **12** entries are shown; up to **40** paths are retained. |
| W-17 | Entries whose file has been deleted, renamed, or moved to an unmounted volume are pruned every time the window is shown, and removed from storage. The list never offers a dead row. |
| W-18 | Only `.md` and `.markdown` paths are ever recorded. |
| W-19 | Right-clicking an entry offers **Show in Finder** and **Remove from Recents**. |
| W-20 | **Clear** empties both this list and the system File ▸ Open Recent menu. |
| W-21 | The list is stored in `recentDocumentPaths` and is authoritative. It seeds itself once from `NSDocumentController.recentDocumentURLs` on first run, so recents from before this feature existed still appear, and a removed entry stays removed afterwards. |
| W-22 | Every document opened by the app is recorded, including files opened from the file explorer sidebar, and each newly saved location. |
| W-23 | With no recents, the panel shows an explanatory empty state rather than a blank area. |

### 4.5 Appearance

| ID | Requirement |
| --- | --- |
| W-24 | The window uses the current theme: tinted sidebar on the left, document-colored panel on the right, themed accent for icons, links, and the checkbox. |
| W-25 | Hovering a recent entry fills it with the theme accent and switches its text to whichever of black or white has the higher measured contrast against that accent. |
| W-26 | The window is 760 × 470 points with a hidden title and full-size content view. |
| W-27 | A **Make Default Markdown App** link appears below the actions only while the app is not already the default handler for Markdown files. It is re-evaluated whenever the app becomes active. |

---

## 5. Document lifecycle

### 5.1 File type

| ID | Requirement |
| --- | --- |
| D-1 | The app owns the Uniform Type Identifier `net.daringfireball.markdown`, conforming to `public.plain-text`, with MIME type `text/markdown`. |
| D-2 | Recognized filename extensions are `.md` and `.markdown`. |
| D-3 | The app registers as `Editor` with handler rank `Owner` for those types, so it can be set as the default Markdown application. |

### 5.2 Finder integration

| ID | Requirement |
| --- | --- |
| D-19 | The app appears in Finder's **Open With** menu for `.md` and `.markdown` files. |
| D-20 | When it is the default handler, double-clicking a Markdown file launches it and opens that file — cold launch included, with no welcome window in the way. |
| D-21 | **Markdown Editor ▸ Make Default Markdown Application** sets the app as the default handler. The item becomes a disabled *Default Markdown Application* once it already is, and is re-checked every time the app becomes active, because Finder's Get Info panel can change it at any time. |
| D-22 | The welcome window offers the same action as a **Make Default Markdown App** link, shown only when the app is not already the default. |
| D-23 | On macOS 14 and newer the change routes through `NSWorkspace.setDefaultApplication(at:toOpen:)`, which asks the user to confirm. macOS 13 falls back to `LSSetDefaultRoleHandlerForContentType`. |
| D-24 | Failure to change the handler is reported with the manual alternative — Get Info ▸ Open with — as the recovery suggestion. |
| D-25 | The app ships an application icon and a distinct Markdown document icon, so `.md` files are identifiable in Finder and the app is identifiable in Open With and the Dock. |

`make install` copies the built bundle to `/Applications` and registers it, which
is what makes these behaviors durable. The `build/` copy is deliberately
unregistered at the same time: leaving both registered lists the app twice in
Open With and lets the association point at a bundle that `make clean` deletes.

### 5.3 Standard document behavior

| ID | Requirement |
| --- | --- |
| D-4 | The app uses SwiftUI's `DocumentGroup` with a `FileDocument`, so New, Open, Save, Save As, Duplicate, Rename, Move To, Revert, and Close are provided by the system with their standard shortcuts and dialogs. |
| D-5 | A new document starts as an **empty Heading 1** — the two characters `# ` — with the caret placed after the marker, so the first keystroke becomes the title. Documents almost always open with one, and the heading is ordinary Markdown, not a mode: deleting the `# ` leaves a blank document. |
| D-6 | Closing a document with unsaved changes presents the standard macOS save prompt. Nothing custom overrides this. |
| D-7 | Each document opens in its own window. |
| D-18 | Launch is intercepted so an empty launch presents the welcome window instead of an untitled document or an Open panel. See [Welcome window](#4-welcome-window). |
| D-26 | The initial caret is applied only to a document that has never been saved *and* whose text is still exactly `# `. Every other document opens with the caret at offset 0. |
| D-27 | The starting heading is not a change: a new document is not dirty and closing it untouched does not prompt. The web build starts a new document identically. |

### 5.4 Text encoding

| ID | Requirement |
| --- | --- |
| D-8 | Documents are read and written as UTF-8. |
| D-9 | If a file begins with a UTF-8 byte-order mark (`EF BB BF`), the BOM is detected, stripped for editing, and **re-emitted on save**. A file that had a BOM keeps it; a file that did not, does not gain one. |
| D-10 | Line endings are never normalized. The bytes between the first and last character are preserved exactly as typed. |
| D-11 | Opening a file that is not valid UTF-8 fails with the message "The file is not valid UTF-8 Markdown." and the recovery suggestion "Convert the file to UTF-8 and try opening it again." |

### 5.5 Autosave

| ID | Requirement |
| --- | --- |
| D-12 | Edits to a document that already exists on disk are autosaved in place after a **1.5 second** debounce following the last keystroke. |
| D-13 | Autosave uses the standard `NSDocument` autosave-in-place operation, so it participates correctly in Versions and does not interfere with the undo stack. |
| D-14 | Any pending autosave is flushed immediately when the application resigns active (for example, when switching to another app). |
| D-15 | A document that has never been saved is **not** autosaved. It has no location on disk, so the user is prompted through the standard save flow instead. |
| D-16 | A pending autosave is cancelled when the editor view disappears. |
| D-17 | Autosave failures are presented to the user through the document's standard error presentation. Autosave never fails silently. |

---

## 6. Editing modes

### 6.1 The three modes

| ID | Requirement |
| --- | --- |
| E-1 | The editor offers exactly three view modes: **Rich Text**, **Markdown**, and **Split**. |
| E-2 | **Split is the default mode** for a newly opened window. |
| E-3 | In Split, the **rendered preview is on the left** and the **raw Markdown source is on the right**. |
| E-4 | Modes are switchable from a segmented control in the toolbar and from **Markdown ▸ Editor View**. `⌘⌥M` cycles Rich Text → Markdown → Split → Rich Text. |
| E-5 | Switching modes preserves the current selection. |

### 6.2 Rich Text mode

| ID | Requirement |
| --- | --- |
| E-6 | The rendered view is **directly editable**, not a read-only preview. Typing, deleting, and selecting all work in place. |
| E-7 | Every edit in the rendered view is translated back into a minimal replacement against the Markdown source, so unrelated parts of the document are never rewritten. |
| E-8 | Markdown that the renderer does not recognize is displayed as literal text rather than being dropped, so no content can be lost by viewing or editing in Rich Text mode. |
| E-9 | Copying from the rendered view places the **underlying Markdown** on the pasteboard, both as plain text and under a private Markdown pasteboard type. |
| E-10 | Pasting into the rendered view prefers the private Markdown type when present, so copy/paste between documents round-trips formatting exactly. Plain text is used otherwise. |
| E-11 | Cut copies the Markdown, then removes the selection as a single undoable operation. |
| E-12 | Undo and redo are registered per logical operation with descriptive action names, and multi-keystroke input method composition is committed as one undo step. |

### 6.3 Split mode synchronization

| ID | Requirement |
| --- | --- |
| E-13 | Scrolling either pane scrolls the other to the equivalent normalized position. |
| E-14 | Moving the selection or caret in either pane moves it to the corresponding location in the other pane, mapped through the render model's source ↔ rendered range mapping. |
| E-15 | Editing in either pane keeps both panes anchored at the selection and **does not cause the other pane to jump**. |
| E-16 | Synchronization is guarded against feedback loops in both directions, and scroll adjustments smaller than 0.5 points are ignored to prevent jitter. |
| E-17 | Synchronization is active only in Split mode. |

### 6.4 Representative source typography

| ID | Requirement |
| --- | --- |
| E-18 | The raw Markdown pane shows every source marker verbatim (`#`, `**`, backticks, and so on) — nothing is hidden. |
| E-19 | Despite showing markers, the source pane renders headings, body text, and code at **the same point sizes the preview uses**, so the two panes in Split keep similar vertical proportions and scroll together meaningfully. |

### 6.5 Standard text behaviors

| ID | Requirement |
| --- | --- |
| E-20 | Both editors enable the standard macOS find panel with incremental searching, so `⌘F`, `⌘G`, and `⇧⌘G` behave as expected. |
| E-21 | Both editors support the full standard AppKit text system: multi-level undo, spell checking, text substitutions, input methods, emoji picker, Services, and all standard navigation and selection keybindings. |

---

## 7. Markdown language support

### 7.1 Block constructs parsed and rendered

| Construct | Syntax accepted | Rendered as |
| --- | --- | --- |
| Headings | `#` through `######`, up to 3 leading spaces, followed by space or tab | Bold text at the heading's point size |
| Paragraphs | Any other text | Body text |
| Block quotes | `>` with optional following space, nestable | Indented text with a left inset |
| Bulleted lists | `-`, `+`, or `*` followed by whitespace | `•` bullet with hanging indent |
| Numbered lists | Digits followed by `.` or `)` then whitespace | Original number preserved, hanging indent |
| Task lists | `- [ ]`, `- [x]`, `- [X]` (also `+` and `*`) | `☐` unchecked, `☑` checked |
| Fenced code blocks | 3 or more backticks **or** tildes, optional language identifier, matching closing fence | Monospaced block on a rounded tinted background |
| Horizontal rules | 3 or more `-`, `*`, or `_`, optionally spaced | Centered `—` |

### 7.2 Inline constructs parsed and rendered

| Construct | Syntax accepted |
| --- | --- |
| Bold | `**text**` or `__text__` |
| Italic | `*text*` or `_text_` |
| Bold + italic | `***text***` or `___text___` |
| Strikethrough | `~~text~~` |
| Underline | `<u>text</u>` |
| Inline code | Backtick runs of any length, opening and closing runs must match; one leading and trailing space is stripped |
| Links | `[label](destination)` and `[label](<destination>)`; label is recursively parsed for inline formatting |
| Images | `![alt](destination)` and `![alt](<destination>)`; rendered as an atomic object placeholder |
| Escapes | Backslash before any ASCII punctuation character |

| ID | Requirement |
| --- | --- |
| M-1 | Emphasis delimiters follow left/right-flanking boundary rules so that `snake_case_words` and mid-word underscores are not misinterpreted as emphasis. |
| M-2 | Backslash escapes are counted for parity, so `\\*` is a literal backslash followed by emphasis while `\*` is a literal asterisk. |
| M-3 | Markdown inside inline code spans is **not** parsed. |
| M-4 | Any syntax the parser does not recognize is preserved verbatim as literal text. |

### 7.3 Source ↔ rendered range mapping

| ID | Requirement |
| --- | --- |
| M-5 | The render model records, for every rendered character, the source range it came from, enabling bidirectional mapping. |
| M-6 | Synthetic characters that have no 1:1 source counterpart (`•`, `☐`, `☑`, `—`, the image placeholder) are interpolated across the source range they represent. |
| M-7 | Atomic spans — currently images — map as a unit, so a selection touching an image selects the whole reference in the source. |

---

## 8. Formatting commands

All commands operate on the Markdown source and return both the new text and
a recalculated selection, so the caret lands somewhere sensible after every
operation.

### 8.1 Inline styles

| Style | Markers written | Notes |
| --- | --- | --- |
| Bold | `**` … `**` | Also recognizes `__` … `__` when toggling off |
| Italic | `*` … `*` | Also recognizes `_` … `_` when toggling off |
| Underline | `<u>` … `</u>` | Markdown has no native underline, so an HTML tag is used |
| Strikethrough | `~~` … `~~` | |
| Inline code | Backticks | Delimiter length is computed as one more than the longest backtick run inside the content, so code containing backticks is escaped correctly |

| ID | Requirement |
| --- | --- |
| F-1 | Applying a style to an empty selection inserts placeholder text already wrapped in markers, with the placeholder selected. |
| F-2 | Applying a style to an existing selection that already carries that style **removes** the markers instead of nesting them. |
| F-3 | Removal detects markers whether they sit inside or immediately outside the selection. |
| F-4 | Toggling one half of a combined `***bold italic***` run unwraps it correctly to the remaining single style. |
| F-5 | Inline code pads with a space when the content itself begins or ends with a backtick or whitespace, per Markdown rules. |

### 8.2 Block styles

| ID | Requirement |
| --- | --- |
| F-6 | Headings accept levels 1–6. Level 0 means "Paragraph" and strips any existing heading markers. Applying a level replaces an existing marker rather than stacking. |
| F-7 | Bulleted lists use `- `. Numbered lists use `N. ` and **renumber sequentially from 1** across the selected lines. Task lists use `- [ ] `. |
| F-8 | Applying a list style to lines that already all carry that style removes the markers. |
| F-9 | Quotes use `> `. Applying to lines that are all already quoted removes the markers. |
| F-10 | Horizontal rules are written as `***` on their own line, with surrounding blank lines added only when needed. |
| F-11 | Fenced code blocks use backtick fences of at least 3, extended to one more than the longest backtick run in the selection. |

### 8.3 Smart list and quote continuation

| ID | Requirement |
| --- | --- |
| F-12 | Pressing Return inside a list item starts the next item automatically, preserving indentation and any enclosing quote markers. |
| F-13 | Numbered lists increment the number on continuation. |
| F-14 | Task lists continue with a fresh unchecked `- [ ] `. |
| F-15 | Pressing Return on an **empty** list item or quote line removes the marker instead of creating another empty item — the standard way to exit a list. |

---

## 9. Images and assets

### 9.1 Assets convention

| ID | Requirement |
| --- | --- |
| I-1 | Images are copied into a folder named **`<document-stem>.assets`** in the same directory as the document. For `post.md` this is `post.assets/`. |
| I-2 | The assets folder is created on demand. |
| I-3 | The document must be saved before an image can be added, because the assets folder location is derived from the document's location. |

### 9.2 Import behavior

| ID | Requirement |
| --- | --- |
| I-4 | **Insert ▸ Image…** (`⌘⌥I`) and the toolbar button open a standard `NSOpenPanel` filtered to supported image types. |
| I-5 | Supported extensions are `bmp`, `gif`, `heic`, `heif`, `jpeg`, `jpg`, `png`, `svg`, `tif`, `tiff`, and `webp`. |
| I-6 | The chosen file is **copied**, never moved or referenced in place, so the document folder is self-contained. |
| I-7 | Filename collisions are resolved by appending `-2`, `-3`, and so on before the extension. An existing `photo.jpg` yields `photo-2.jpg`. Nothing is ever overwritten. |
| I-8 | A relative Markdown reference is inserted at the caret in the form `![stem](folder.assets/file.ext)`, where the alt text defaults to the original filename without its extension. |
| I-9 | The path is percent-encoded per RFC 3986, preserving only alphanumerics and `- . _ ~`. A file named `my image.jpg` is referenced as `my%20image.jpg`. |
| I-10 | Alt text is escaped so that `\`, `[`, and `]` in a filename cannot break the reference. |

### 9.3 Safety and error reporting

| ID | Condition | Message |
| --- | --- | --- |
| I-11 | Document has never been saved | "Save the Markdown document before adding an image." |
| I-12 | Document is not a local file | "Images can only be added to Markdown documents stored on this Mac." |
| I-13 | Source file is missing | "The selected image does not exist: *name*" |
| I-14 | Source is a folder | "The selected item is a folder, not an image: *name*" |
| I-15 | Unsupported or absent extension | "The selected .*ext* file is not a supported image." |
| I-16 | Assets path is a symlink, or a non-directory file already occupies the name | "The assets location is not a regular folder beside the document: *name*" |
| I-17 | Relative path cannot be encoded | "The relative image path could not be encoded: *path*" |

| ID | Requirement |
| --- | --- |
| I-18 | The resolved assets directory must resolve to a real subdirectory of the document's own folder. Symlinked assets folders are rejected so an import can never write outside the document's directory. |

---

## 10. Links

| ID | Requirement |
| --- | --- |
| L-1 | **Insert ▸ Link…** (`⌘K`) prompts for a destination, pre-filled with `https://`. |
| L-2 | The link is written as `[label](destination)`, using the current selection as the label. |
| L-3 | Label text is escaped for `\`, `[`, and `]`. |
| L-4 | Destinations are percent-encoded for the characters that would otherwise break link syntax: space, `\`, `(`, `)`, `<`, and `>`. |

---

## 11. File explorer

| ID | Requirement |
| --- | --- |
| X-1 | A collapsible sidebar shows a folder tree, using a native source-list outline view with system file icons. |
| X-2 | **File ▸ Open Folder…** (`⌘⌥O`) or the header menu's "Choose Folder…" selects the root folder. |
| X-3 | The header shows a dropdown listing the current folder's **ancestor directories** up to the filesystem root, each as a basename-only row, so navigating upward is one click. |
| X-4 | A "show current document folder" button reveals the folder containing the open document and then follows the document as different files are opened. |
| X-5 | A refresh button rescans the tree from disk. |
| X-6 | Hidden and system files are omitted. |
| X-7 | Entries sort expandable folders first, then alphabetically using localized natural-order comparison, so `Folder 2` sorts before `Folder 10`. |
| X-8 | Packages (such as `.app` bundles) and directory symlinks are shown but are not expandable, preventing traversal into bundle internals or symlink cycles. |
| X-9 | Double-clicking a `.md` or `.markdown` file opens it in the app. Double-clicking any other file opens it in the system default application. |
| X-10 | Double-clicking a folder toggles expansion. |
| X-11 | The sidebar is resizable by dragging its divider, between 190 and 420 points, defaulting to 240. |
| X-12 | The divider supports keyboard adjustment in 20-point steps and exposes a standard accessibility adjustable action. |
| X-13 | Double-clicking the divider resets the sidebar to its default width. |
| X-14 | The document area is never squeezed below 520 points; the sidebar yields first. |
| X-15 | Selected rows are drawn with a rounded fill in the active theme's accent color, with the label color chosen automatically for contrast. Non-Markdown files are shown in secondary text color. |

### 11.1 Preview width

| ID | Requirement |
| --- | --- |
| X-16 | The rendered preview has its own draggable width, defaulting to 700 points, clamped between 360 and 1100 (220 minimum inside Split). |
| X-17 | Content **reflows live while the divider is being dragged**, not only on release. |

---

## 12. Themes and appearance

### 12.1 Model

| ID | Requirement |
| --- | --- |
| T-1 | Appearance is defined by two independent axes: a **color** (8 choices) and a **background mode** (Light or Dark), giving 16 combinations. |
| T-2 | The eight colors mirror the theme selector on <https://www.kirupa.com/>: Blue, Yellow, Pink, Green, Purple, Pico-8, Black, and Brown. |
| T-3 | Color values are transcribed from the site's `:root`, `html.theme_<color>`, `html.theme_dark`, and `html.theme_<color>_dark` custom properties. |
| T-4 | The choice persists app-wide in `UserDefaults` under the keys `editorThemeColor` and `editorAppearanceMode`. |
| T-5 | On first launch the background mode follows the macOS system appearance; the color defaults to Blue. |

### 12.2 Customize Theme popover

| ID | Requirement |
| --- | --- |
| T-6 | The toolbar palette button opens a **Customize Theme** popover, modeled on the site's dialog: a Color row, a Background toggle, a live preview, and **Apply** and **Cancel** buttons. |
| T-7 | The popover holds **draft state**. Selections change the in-popover preview only; the document and app are unchanged until Apply is pressed. |
| T-8 | Cancel, `Escape`, or dismissing the popover discards the draft. |
| T-9 | Swatches use the exact fill and border colors from the site's `#themeChooser` rules, drawn as rounded squares with a 3-point border. The active swatch is scaled slightly and glows. |
| T-10 | **Markdown ▸ Theme Color** and **Markdown ▸ Background** apply the same choices immediately from the menu bar, without the Apply step. |

### 12.3 Coverage and contrast

| ID | Requirement |
| --- | --- |
| T-11 | A theme applies to the window canvas, the file explorer, the source editor, the rendered preview, inline code, fenced code block backgrounds, separators, insertion points, and text selection highlight. |
| T-12 | AppKit appearance is set to Aqua or Dark Aqua to match, so system-drawn controls follow the theme. |
| T-13 | In Light mode, sidebar tints are blended 55% toward the page background, because several of the site's raw header colors are too saturated to carry readable label text. |
| T-14 | Selection label color is chosen by computing the WCAG contrast ratio of black and white against the accent color and picking the better one. |
| T-15 | Secondary text is derived from body text rather than fixed, so it stays legible on every themed background. |

---

## 13. Typography and layout

### 13.1 Font sizes

| Element | Rendered preview | Raw Markdown pane |
| --- | --- | --- |
| Heading 1 | 30 pt bold | 30 pt bold monospaced |
| Heading 2 | 25 pt bold | 25 pt bold monospaced |
| Heading 3 | 21 pt bold | 21 pt bold monospaced |
| Heading 4 | 18 pt bold | 18 pt bold monospaced |
| Heading 5 | 16 pt bold | 16 pt bold monospaced |
| Heading 6 | 15 pt bold | 15 pt bold monospaced |
| Body | 15 pt | 15 pt monospaced |
| Code | 13 pt monospaced | 13 pt monospaced |

### 13.2 Block layout

| ID | Requirement |
| --- | --- |
| Y-1 | Body line spacing is 2 points with 7 points between paragraphs. |
| Y-2 | Headings 1–2 reserve 14 points above and 8 below; headings 3–6 reserve 9 above and 8 below. |
| Y-3 | List items use a 5-point first-line indent and a 24-point hanging indent with a matching tab stop, so wrapped lines align under the text rather than the bullet. |
| Y-4 | Block quotes are inset 20 points on the left and 8 points on the right. |
| Y-5 | Fenced code blocks are drawn as **one continuous rounded rectangle** behind the whole block. The first line aligns with every following line — the opening line is not offset. |
| Y-6 | Horizontal rules are centered with 8 points of space above and below. |
| Y-7 | The rendered editor uses 24-point horizontal and 20-point vertical text insets; the source editor uses 18 and 16. |

---

## 14. Keyboard shortcut reference

### 14.1 Provided by the app

| Shortcut | Command |
| --- | --- |
| `⌘B` | Bold |
| `⌘I` | Italic |
| `⌘U` | Underline |
| `⌘K` | Insert Link… |
| `⌘⌥I` | Insert Image… |
| `⌘⌥M` | Cycle Editor View |
| `⌘⌥O` | Open Folder… |

### 14.2 Provided by macOS

`⌘N` New, `⌘O` Open, `⌘S` Save, `⇧⌘S` Save As / Duplicate, `⌘W` Close,
`⌘Z` / `⇧⌘Z` Undo and Redo, `⌘X` / `⌘C` / `⌘V` Cut, Copy, Paste,
`⌘A` Select All, `⌘F` / `⌘G` / `⇧⌘G` Find, Find Next, Find Previous,
plus all standard text navigation and selection.

### 14.3 Menu commands without shortcuts

**Markdown menu:** Editor View, Theme Color, Background, Strikethrough,
Code ▸ Inline Code (Single Line), Code ▸ Fenced Code Block (Multi-Line),
Heading ▸ Paragraph and Heading 1–6, Bulleted List, Numbered List, Task List,
Quote, Horizontal Rule.

**Window menu:** Welcome to Markdown Editor.

**Markdown Editor menu:** Make Default Markdown Application.

### 14.4 Welcome window

`Return` triggers **New Document**, the window's default button.

---

## 15. Architecture

```
Sources/
├── MarkdownEditorCore/          UI-free, fully unit-tested logic
│   ├── MarkdownFormatting       Source-to-source formatting transforms
│   ├── MarkdownRenderModel      Markdown parser + bidirectional range mapping
│   ├── MarkdownImageImporter    Asset folder resolution, copying, referencing
│   ├── MarkdownTextCodec        UTF-8 and BOM handling
│   ├── MarkdownTextDifference   Minimal-replacement diffing
│   ├── RecentDocumentsCatalog   Recent-document ordering, filtering, pruning
│   └── FileTreeScanner          Directory listing and ordering
└── MarkdownEditor/              SwiftUI + AppKit application
    ├── MarkdownEditorApp        DocumentGroup scene, persisted preferences
    ├── MarkdownEditorAppDelegate Launch interception for the welcome window
    ├── MarkdownDocument         FileDocument conformance
    ├── MarkdownEditorView       Layout, panes, dividers, autosave wiring
    ├── MarkdownEditorSession    Shared editing state and command dispatch
    ├── MarkdownEditorCommands   Menu bar commands
    ├── MarkdownFormattingToolbar Toolbar items
    ├── WelcomeWindowController  Landing window hosting and lifecycle
    ├── WelcomeView              Landing window UI
    ├── RecentDocumentsModel     Persisted recent-document store
    ├── DefaultMarkdownHandler   Reads and sets the default Markdown app
    ├── RichTextEditor           Rendered editing surface
    ├── RichMarkdownTextView     NSTextView subclass: pasteboard, code backgrounds
    ├── RichMarkdownStyler       Applies attributes from the render model
    ├── SourceTextEditor         Raw Markdown editing surface
    ├── MarkdownSourceStyler     Representative source typography
    ├── FileExplorer*            Sidebar model, outline view, header
    ├── DocumentAutosaveController Debounced autosave
    ├── EditorColorTheme         Palettes and derived colors
    └── ThemePickerPopover       Customize Theme UI
```

**Key design decisions**

1. *Markdown is the single source of truth.* The rendered view is a projection.
   There is no separate rich-text document model to drift out of sync.
2. *Edits are diffed, not rewritten.* Changing one word produces a minimal
   replacement, so scroll position, selection, and untouched text are stable.
3. *Range mapping is explicit.* The parser emits per-character source offsets,
   which is what makes selection sync and rendered-view editing possible.
4. *Logic lives outside the UI.* Anything testable without an app lives in
   `MarkdownEditorCore`.

---

## 16. Build, run, and test

Requires macOS 13 or newer and a current Apple Swift toolchain. A full Xcode
installation is not required, but the Command Line Tools must be installed.

```bash
git clone https://github.com/kirupa/markdown-editor.git
cd markdown-editor/macOS
make install
```

| Target | Effect |
| --- | --- |
| `make app` | Builds a release binary and assembles an ad-hoc-signed `build/Markdown Editor.app` |
| `make run` | `make app`, then opens the app from `build/` |
| `make install` | `make app`, then installs to `/Applications` and registers it as a Markdown handler |
| `make uninstall` | Removes the installed app and its Launch Services registration |
| `make icons` | Regenerates `Packaging/AppIcon.icns` and `Packaging/MarkdownDocument.icns` |
| `make test` | Runs the unit test suite |
| `make clean` | Cleans the package build directory and removes `build/` |

`Scripts/build-app.sh` builds the executable, assembles the bundle from
`Packaging/Info.plist` and the two `.icns` files, lints the plist, code-signs ad
hoc, and verifies the signature with `codesign --verify --deep --strict`.

`Scripts/install-app.sh` replaces any existing `/Applications/Markdown
Editor.app`, unregisters the `build/` copy, and registers the installed one with
`lsregister`. Set `INSTALL_DIR` to install somewhere else. Use `make run` for
development and `make install` for the copy Finder should open files with.

`Scripts/make-icons.swift` draws both icons with Core Graphics and packs them
with `iconutil`, so there is no asset catalog or design tool in the loop. The
results are committed, so a normal build never runs it.

`Scripts/run-tests.sh` runs `swift test`, adding the Swift Testing framework
search path and rpath from the active Xcode toolchain when the toolchain does
not expose it directly.

### 16.1 Test coverage

82 tests across 7 suites, all in `MarkdownEditorCore`:

| Suite | Tests | Covers |
| --- | --- | --- |
| Markdown formatting | 30 | Every inline and block transform, toggle-off detection, renumbering, list continuation |
| Markdown render model | 24 | Block and inline parsing, boundary rules, escapes, range mapping |
| Recent documents catalog | 10 | Merge order, de-duplication, Markdown filtering, caps, promotion, removal, pruning of missing files, home-relative paths |
| Markdown image importer | 6 | Assets folder naming, collisions, symlink rejection, unsaved documents, unsupported types |
| File tree scanner | 6 | Ordering, hidden files, packages, symlinks |
| Markdown text codec | 3 | UTF-8 round trip, BOM preservation, invalid input |
| Markdown text difference | 3 | Minimal replacement computation |

---

## 17. Release history

| Change | Summary |
| --- | --- |
| Add native Markdown editor app | Document lifecycle, File menu, UTF-8/BOM handling, image import with `.assets` convention, unit tests, app bundling |
| Add WYSIWYG Markdown formatting | Directly editable rendered view, full inline and block formatting, toolbar and menus |
| Add Markdown explorer and resizable panes | File explorer sidebar, single-line and multi-line code commands |
| Refine explorer path dropdown | Ancestor-path menu with basename-only rows |
| Add resizable preview width | Draggable preview width, reveal current document folder |
| Reflow Rich Text during resize | Live reflow while dragging |
| Add split editor and rounded code blocks | Third Split mode; fenced blocks unified into one rounded rectangle |
| Synchronize split editor scrolling | Scroll sync between panes; Split becomes the default mode |
| Synchronize split editor selections | Selection sync; Preview moved left, Markdown right |
| Match source typography to preview | Representative heading and body sizes in the raw Markdown pane |
| Add editor themes and autosave | Initial theme support and debounced autosave-in-place |
| Match theme selector to kirupa.com | Eight site colors on a Light/Dark axis, Customize Theme popover with Apply and Cancel |
| Add welcome window | Landing window at launch with New Document, Open, and a pruned recent-documents list; replaces the launch Open panel |
| Wait for window restoration | Restored documents no longer flash the welcome window on their way in |
| Become a Finder Markdown handler | App and document icons, `make install`, and an in-app way to become the default handler |
| Start new documents on a Heading 1 | A new document opens as an empty Heading 1 with the caret past the marker, matching the web build |

---

## 18. Out of scope / not yet supported

Known gaps, recorded deliberately so they are not mistaken for bugs:

| Area | Status |
| --- | --- |
| Tables | Not parsed. Table source is preserved as literal text. |
| Reference-style links (`[a][b]`) | Not parsed. Only inline `[a](b)` is supported. |
| Indented (4-space) code blocks | Not parsed as code. Use fenced blocks. |
| Footnotes, definition lists, admonitions | Not supported. |
| HTML other than `<u>` | Passed through as literal text, not rendered. |
| Hard line breaks via trailing spaces or `<br>` | Not rendered as breaks. |
| Dragging an image file into the document | Not wired to the import path; use Insert ▸ Image…. |
| Pasting image data from the clipboard | Not wired to the import path. |
| Syntax highlighting inside fenced code blocks | The language identifier is parsed and retained but not colorized. |
| Export to HTML or PDF | Out of scope. |
| Custom Find and Replace UI | Out of scope. The standard macOS find panel with incremental search is enabled instead. |
