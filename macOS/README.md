# Markdown Editor — Product Requirements Document

A dependency-free native macOS Markdown editor built with SwiftUI and AppKit.
The [iOS build](../iOS/README.md) is the same product on iPhone and iPad,
compiled from the same shared Swift source; the [web build](../Web/README.md)
reimplements it for the browser. This document is the specification all three
are held to.

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
| NG-3 | ~~Cloud sync, collaboration, or multi-user editing.~~ **No longer a non-goal, and blocked rather than merely unbuilt.** The stated direction for the product is cloud-first with local copies for offline use, which the web build already implements. A Firebase adapter lives in `Shared/Firebase/`, compiles for macOS, and is verified against a real Firestore ([§16.7](#167-the-native-firestore-adapter-is-verified-against-a-real-firestore)) — but **nothing in this app reaches it**, and a sign-in screen would not work if it did. FirebaseAuth cannot sign in from any build this repository can produce: it needs the macOS data-protection keychain, whose entitlement is restricted and has to be authorized by a provisioning profile, which ad-hoc signing cannot supply ([§16.8](#168-firebaseauth-cannot-sign-in-from-a-build-this-repository-can-produce)). The blocker is that *keychain* and not the signature — the same ad-hoc bundle writes to the file-based keychain without complaint — and FirebaseAuth asks for the data-protection one unconditionally, so it cannot be redirected. So the order is: a real signing identity, then registering an Apple app in the Firebase console (see the root README), then the UI. Multi-user editing of one document remains a non-goal. |
| NG-4 | Plugin or extension support. |
| NG-5 | ~~iOS, iPadOS, or cross-platform support.~~ **Superseded.** This row described the app when it was the only one. There is now an iOS app (`iOS/`), a browser build (`Web/`), a brief for a Windows one (`Windows/`), and a language-neutral fixture set (`Contract/`) that holds them to the same behaviour. What survives of the intent is narrower and still true: this target is native macOS, and nothing here is compromised to make it portable. |

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

### 5.6 Changes made by another app

The document on disk can move underneath the editor at any time — another
editor, a `git checkout`, Dropbox, a shell script. This section says how that
is noticed and what happens next.

| ID | Requirement |
| --- | --- |
| D-28 | While a document with a file is open, the app watches that file and notices when something else writes it. |
| D-29 | The watcher survives an **atomic replacement** — a write to a temporary file followed by a rename over the target, which is how most editors and `git` save. It reports the second such write and every one after it, not only the first. |
| D-30 | The app's own writes are never reported as somebody else's. This holds for autosave (D-12), for **File ▸ Save**, and for a save whose file-system event arrives after further typing. |
| D-31 | If there are **no unsaved edits**, the newer text is applied straight away and a bar says the document was changed by another app. The bar clears itself after a few seconds. |
| D-32 | An applied external revision is a single, named entry on the undo stack, so it can be taken back with `⌘Z`. |
| D-33 | The caret is carried across an applied revision rather than reset to the top, using the same text-difference mapping the split panes use. |
| D-34 | If there **are** unsaved edits, nothing is applied. A bar stays up offering **Reload** (`⇧⌘R`) and **Keep Mine**, and says the unsaved edits are still there. |
| D-35 | **Autosave is suspended while that bar is up.** Without this the notice would be pointless: autosave would overwrite the other app's version a second or two after pointing it out. Choosing Keep Mine resumes it and writes this version. |
| D-36 | **File ▸ Reload from Disk** (`⇧⌘R`) re-reads the file at any time, whether or not anything was reported. It is disabled for a document that has never been saved. |
| D-37 | A file that is deleted while open raises nothing. The document stays open with its text, which is the only remaining copy. |
| D-38 | A file that is briefly unreadable — mid-replacement — raises nothing. The rename that follows is reported instead. |

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
| E-22 | **Typing never moves the page.** Re-styling a pane restores its exact scroll offset — not a fraction of its travel, which shifts whenever the document changes height, which is what typing does. |
| E-23 | A pane reports a scroll position only when it has been fully laid out. Partial layout describes the part measured so far rather than the document, and publishing that threw the reader thousands of points down the page. A pane that cannot answer stays silent instead of guessing; AppKit finishes measuring in the background and it starts answering again on its own. |
| E-24 | A pane receiving a position lays itself out fully before converting it. A newly created pane — one that has just joined a Split — has measured only the screenful it shows, so without this a reader 80% through a document lands at the very top. |
| E-25 | The caret is revealed **after** the scroll offset is restored, never before, or the restore undoes the reveal and leaves the caret off screen. |
| E-26 | Revealing the caret is skipped when it is already fully visible, so ordinary typing does not move the page. A caret straddling the edge of the viewport counts as hidden, not visible. |
| E-27 | A pane publishes a selection change only when the writer caused it. Both panes replace their whole text storage to re-style, on every keystroke, and AppKit announces an intermediate selection part-way through that — measured 19,681 characters from the real caret. Publishing it made the other pane reveal a caret the writer had not moved, so the split lurched down the document and back on every character. Selection changes during a re-style are suppressed, and the settled selection is published once it finishes. |
| E-28 | Catching a pane up with its neighbour happens when the pane **joins** the split, not on every update. SwiftUI calls `updateNSView` for both panes on every keystroke, and the catch-up applied the active pane's normalized *fraction* to a pane showing the same text at a different height — so 20 keystrokes moved the idle pane 40 times, dragging it a little further out of step with each character. The session now distinguishes a pane joining the split from the same pane being updated again, and owes the catch-up afresh only when the view mode changes or a pane leaves and returns. |

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
| Image size | `<img src alt width height>` | Markdown has no syntax for dimensions, so an HTML tag is used. See [`Contract/README.md`](../Contract/README.md) |
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

### 9.4 Images by web address

| ID | Requirement |
| --- | --- |
| I-19 | **Insert ▸ Image…** first asks where the image comes from: **Choose File…** (the import above) or **Image Address…**. |
| I-20 | An address is referenced where it is; nothing is copied and no assets folder is created, so an address works in an unsaved document. |
| I-21 | The address field is single-line and never wraps. A long address scrolls horizontally within the field and the caret stays visible at the end. The Insert ▸ Link… field behaves the same way. |
| I-22 | The reference is written as `![image](address)`, with the alt text left selected so typing replaces it. |

### 9.5 Rendering an image held at a web address

The rendered editor draws remote images for real rather than showing a
placeholder glyph. Styling is synchronous and re-runs on every keystroke, so
the lookup must be instant and the download must not be.

| ID | Requirement |
| --- | --- |
| I-23 | An `http`/`https` image is drawn from an in-memory cache. On a miss the styler draws the placeholder and starts one download; when it arrives the visible editors re-style in place, preserving selection and scroll position. |
| I-24 | Only `http` and `https` are fetched. A `file:` address is refused, so the fetching path stays purely a network path and never becomes a second, less careful way to read the disk. Local files are the local reader's job (I-52). |
| I-25 | An address is downloaded at most once per launch. A failure is recorded as a failure, so a broken address costs one request rather than one request per keystroke, and continues to render the placeholder. |
| I-26 | A download over **25 MB** is abandoned. The limit is enforced while streaming, not from `Content-Length` alone, since a server may omit it. |
| I-27 | Downloaded bytes must decode as an image. A server answering an error page with HTTP 200 is treated as a failure, not as an image. |
| I-28 | A cached remote image supplies the natural size for **Insert ▸ Image Size…**, so an address can be resized proportionally like a local file. Before it has loaded, the size cannot be measured and the app says so. |
| I-29 | The cache is not evicted; entries live for the lifetime of the process. A text editor references few enough images for this to be the simpler correct choice. |

### 9.6 Keeping typing responsive on an illustrated document

Styling re-runs on **every keystroke** and rebuilds every attachment in the
document, so without a cache each character typed re-read and re-decoded every
picture on the page. Measured on forty photo-sized references: **65.7 ms per
keystroke, of which 64.6 ms was the images** — about 15 fps, which is felt as
lag rather than seen as a glitch. With the cache the same document styles in
**4.0 ms**.

| ID | Requirement |
| --- | --- |
| I-30 | A local image is decoded once and held in memory, so styling an illustrated document costs about what styling its prose costs. |
| I-31 | The cache is keyed on the file's **modification date and size**, not its path alone. A picture edited in another app is read again rather than drawn from its old self. Size is part of the key because a timestamp is coarse enough that a generated or scripted image can be rewritten within the same second. |
| I-32 | Entries are costed by **pixel area**, not bytes on disk, since an image is far larger decoded than compressed — a 34 MB photo is roughly 48 MB of pixels. The ceiling is **192 MB**. |
| I-33 | Unlike the remote cache (I-29) this one **evicts**, and releases everything under system memory pressure. A long illustrated document could otherwise hold more memory than the rest of the app together. Eviction only costs a re-read; the cache is an optimisation with a correct fallback. |
| I-34 | A file that is missing, unreadable, or not decodable as an image yields nothing and is not remembered as anything, so a broken reference draws the placeholder and starts working the moment a real picture replaces it. |


### 9.7 Selecting and resizing a picture

A picture in the rendered editor is an object, not a character to type over. It
can be clicked to select, and dragged by a corner to resize.

| ID | Requirement |
| --- | --- |
| I-35 | Clicking a picture in the rendered editor selects it. The selection is the single attachment character, so every command that acts on a selection acts on the picture. |
| I-36 | A selected picture is drawn with a thin frame and four corner handles. AppKit's own selection band is suppressed while a picture is selected: it is painted over the whole line fragment, which is taller than the picture, so it showed a coloured strip below the frame that lined up with nothing. |
| I-37 | Dragging a corner resizes the picture. **The aspect ratio is always preserved** — the corner follows whichever axis the pointer moved further along, and the other is derived. |
| I-38 | A resize is written into the source as `<img src="…" alt="…" width="W" height="H">`, the one spelling GitHub honours, matching **Insert ▸ Image Size…**. |
| I-39 | A picture cannot be dragged below **24 pt** on its shorter side, so it can always be grabbed again. |
| I-40 | Clicking the middle of a picture selects it, but dragging from the middle still selects text. Only the corner handles claim a drag. |
| I-47 | Clicking a picture **focuses the pane it is in**. The image path deliberately does not call `super.mouseDown`, so `NSTextView` never takes first responder by itself. Without this the resize is resolved against whichever pane already had focus — in Split view, the Markdown pane — and rewrites a *different* image, or reports "no image at the selection". |
| I-48 | A resize is committed against the source offset **the handles were actually drawn around**, passed through with the size, rather than re-derived from the focused pane's caret. If that offset no longer holds an image — the document was reloaded from disk mid-drag — the commit falls back to the live selection. |
| I-49 | The handles follow the picture when the document **reflows**. Re-wrapping the text above an image moves it without changing the selection or the document, so a window resize or a width-gripper drag would otherwise leave the frame over blank text and still take the drag. |
| I-50 | A resize that is **refused** leaves the picture at the size the document says, not the size the drag abandoned it at. A drag previews by changing the attachment's bounds and nothing else, so only a re-render puts it back — and a refused commit is exactly the case that does not re-render. |

### 9.8 What the pointer says

The pointer is the only part of this the user sees before committing to a
gesture, so it has to be accurate before the mouse goes down.

| ID | Requirement |
| --- | --- |
| I-41 | Over a picture the pointer is the **arrow**, not the I-beam. `NSTextView` claims its whole surface for the I-beam, which over a picture reads as "type here"; a picture is an object to click and drag. |
| I-42 | Over a corner handle the pointer is a **diagonal resize** cursor matching that corner's diagonal. The two corners on one diagonal show the same shape and the two diagonals differ. `NSCursor.frameResize(position:directions:)` is used on macOS 15 and later; earlier systems get an equivalent drawn in `DiagonalResizeCursor.swift`. |
| I-43 | The shape shown, the click accepted, and the corner dragged are all decided by **one** function, `EditorImageGeometry.handleHitRect`. They previously disagreed: the pointer changed over the drawn 9 pt square while clicks were accepted over a 15 pt one, leaving a 3 pt ring where the pointer promised a resize that did not happen. |
| I-44 | The pointer target is the drawn handle **widened**, not the drawn handle. A 9 pt square is a small thing to hit; the target is widened by `handleSlop` on each side, and where two widened targets overlap on a small picture the nearer corner wins so neither becomes unreachable. |
| I-45 | Cursor rects are re-registered when the picture moves, is resized, is scrolled, or the document is re-rendered. They are cached by AppKit, so without this a picture keeps the pointer of wherever it used to be. |
| I-46 | The matching cursor is held for the whole drag and released when it ends, including when the gesture leaves the handle — which it does immediately. |
| I-51 | The held cursor is released even when the drag ends by the **view going away** — the window closing with the mouse down, or SwiftUI rebuilding the representable — in which case no `mouseUp` ever arrives. `NSCursor`'s stack is process-wide, so a stranded push leaves the diagonal arrow over every other app. |

#### Where a picture actually is

`NSLayoutManager.location(forGlyphAt:)` does **not** return the text baseline
for an attachment. It returns the picture's own bottom-left corner, with
`NSTextAttachment.bounds.origin` already folded in. Applying that offset a
second time is wrong by exactly the offset — the renderer sets
`bounds.origin.y = -4`, so every handle sat 4 pt below the corner it was
holding. `EditorImageGeometry.attachmentRect` therefore takes the attachment's
**size**, not its bounds, so the origin cannot be passed in at all.

### 9.9 Which pictures actually draw

A picture that does not resolve is not a *broken* picture. The renderer
substitutes a placeholder symbol, so the line still looks deliberate — but it
is no longer the reader's picture, and nothing anywhere says so. Everything
downstream then looks broken for the wrong reason: resizing a placeholder is
meaningless, and the obvious report is "I cannot select my image".

| ID | Requirement |
| --- | --- |
| I-52 | A picture is read from wherever the document says it is: beside the document, in a subfolder, **above** the document (`../images/photo.png`), or at an absolute path. Percent-encoded and plainly-written spaces both resolve. |
| I-53 | Reading is not governed by the assets containment rule. That rule (I-18) is about **writing**: an import must not put a file outside the document's folder. Applying it to reading protected nothing — the app can already open anything its reader can, and a document displayed on its own reader's screen discloses nothing to anybody — while silently replacing legitimate pictures with a placeholder. The `../` layout it rejected is what static site generators and most note-taking folders produce. |
| I-54 | A destination that resolves to something which is not a decodable image draws the placeholder and nothing else. It is never executed, never fetched, and never reported anywhere. |
| I-55 | A click on a picture is checked against the **real editor hierarchy**, not a bare text view. The app layers a floating explorer, a centred preview column, a gripper and a toolbar around the text, and any of them covering the picture would swallow the click while every geometry check still passed. `make check-editor-clicks` asserts that a click on the picture reaches the rendered pane, a click on a corner reaches the resize handle, and a click on ordinary text still reaches the text. |
| I-56 | The pointer check **proves it can see each cursor before trusting its verdict**. `NSCursor.arrow.image` and `NSCursor.iBeam.image` come back as empty 0x0 images unless an `NSApplication` exists, while `pointingHand` and `frameResize` load without one. A cursor that will not load scores zero against every sample and hands the verdict to whichever candidate did load, so the check reported "pointing hand" for every I-beam it ever saw — including over plain text, where the answer was never in doubt. The check now builds an application first and asserts every candidate has an image. |
| I-57 | The pointer over a picture is a **pointing hand**, over the resize corners a **diagonal resize**, and over text an **I-beam**. Two things are needed together and neither is sufficient alone, both measured on real pixels: the picture's cursor rect must be registered **before** `super.resetCursorRects()`, because AppKit keeps the earlier claim on a region and NSTextView's `super` claims the whole surface for the I-beam; and `cursorUpdate` must set the shape from a tracking area, because the rect alone never reaches the screen. Removing either was measured to put the I-beam back at 0.96 confidence. The hand is used rather than the arrow because the arrow only says "not text", where the hand says the picture can be picked up. `make check-image-layout` guards the rect ordering by reading the source, since nothing else can see a reorder. |
| I-58 | Hovering a picture draws a **faint outline** and shows the **resize corners**, without a click. The frame used to appear only once a picture had been selected, so the thing telling you a picture can be resized only appeared after you had already guessed that it could. The outline is suppressed for the selected picture, which has a frame of its own — two rectangles around one picture reads as a bug. |
| I-59 | A picture can be **dragged between lines**. A press stays a click until it has travelled 4pt, so selecting with an unsteady hand cannot rewrite the document. Past that a **horizontal rule** marks the boundary it would land on, a **gap opens** to show it fitting there, and a translucent copy follows the pointer. The gap is an `NSTextContainer` exclusion path, not an edit: previewing a move must not touch the document. Releasing moves the Markdown as one undoable edit named *Move Image*. |
| I-60 | A picture always lands as a **block of its own**, separated by a blank line either side, and never spliced into a word. Inserting at the nearest character is what the first version did, and a real drag aimed at the gap above a paragraph produced `Ome![photo](a.png)ga paragraph.` The drop point is snapped to a line boundary in the view *and* in `MarkdownFormatting.moveImage`, so neither half can reintroduce it alone. |
| I-61 | Anywhere on the picture's **own line** is not a destination: both edges of that line are the place it already occupies, so a drop a pixel below it is a no-op rather than a rewrite. Lifting a picture out takes its line with it when the line held nothing else, and collapses the blank lines left behind — no blank line at the start, one newline at the end, one blank line in the body — so moving a picture does not add a paragraph break each time. The destination is measured before the removal, so offsets after it shift by what was taken; the insertion offset is clamped, because an uncorrected offset is an out-of-bounds insert and therefore a crash rather than a misplaced picture. |

`boundingRect(forGlyphRange:in:)` is not the picture either: it returns the
glyph's *line box*, as tall as the tallest thing on the line plus line spacing,
so it claims blank space above and below that a click would wrongly accept.

Both rules are asserted against pixels drawn by a real text view in
`make check-image-handles`, across seven baseline offsets on both axes.

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

### 11.1 Staying out of the way

The explorer is a tool for finding a document, not part of writing one, so it
is closed unless it is asked for.

| ID | Requirement |
| --- | --- |
| X-18 | The explorer is **closed by default**. A toolbar button in the leading position and **View ▸ Show/Hide File Explorer** (`⌃⌘S`) toggle it. |
| X-19 | The explorer **floats over** the document rather than taking a column from it, so opening and closing it never moves the text being written. Where a picture and a caret sit on screen does not depend on whether the explorer happens to be open. |

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

### 13.3 A calm page

The editor is for writing, so the writing is what should be visible. Everything
else is either quiet or absent until it is asked for.

| ID | Requirement |
| --- | --- |
| Y-8 | The rendered preview is **centred in the window** and its position does not depend on the explorer. The explorer floats above the page (X-19) rather than pushing it, so opening one does not slide the other. |
| Y-9 | The width gripper is drawn only on hover, and is findable by reaching for the edge whether or not it is drawn. A permanent rule with three dots on it is furniture the document has to compete with. |
| Y-10 | Chrome is drawn in the quietest weight that still reads: hairline separators, secondary-colour glyphs, and no fill behind a control that is not active. |

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
| `⌃⌘S` | Show / Hide File Explorer |

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

The Markdown engine and the styling live in `../Shared`, a Swift package this
app and the [iOS app](../iOS/README.md) both compile. Only the AppKit interface
layer below is macOS-specific.

```
../Shared/Sources/
├── MarkdownEditorCore/          UI-free, fully unit-tested logic
│   ├── MarkdownFormatting       Source-to-source formatting transforms
│   ├── MarkdownRenderModel      Markdown parser + bidirectional range mapping
│   ├── MarkdownImageImporter    Asset folder resolution, copying, referencing
│   ├── MarkdownTextInsertion    Caret-relative literal insertion
│   ├── MarkdownTextCodec        UTF-8 and BOM handling
│   ├── MarkdownTextDifference   Minimal-replacement diffing
│   ├── RecentDocumentsCatalog   Recent-document ordering, filtering, pruning
│   └── FileTreeScanner          Directory listing and ordering
└── MarkdownEditorUI/            Cross-platform presentation
    ├── PlatformTypes            AppKit/UIKit aliases and portable colour blending
    ├── PlatformTextView         NSTextView and UITextView conformances
    ├── EditorColorTheme         Palettes and derived colors
    ├── MarkdownTypography       Shared type scale
    ├── RichMarkdownStyler       Applies attributes from the render model
    ├── MarkdownSourceStyler     Representative source typography
    ├── MarkdownDocument         FileDocument conformance
    └── EditorViewMode           The three modes and their symbols

Sources/MarkdownEditor/          SwiftUI + AppKit application, macOS only
├── MarkdownEditorApp            DocumentGroup scene, persisted preferences
├── MarkdownEditorAppDelegate    Launch interception for the welcome window
├── MarkdownEditorView           Layout, panes, dividers, autosave wiring
├── MarkdownEditorSession        Shared editing state and command dispatch
├── MarkdownEditorCommands       Menu bar commands
├── MarkdownFormattingToolbar    Toolbar items
├── WelcomeWindowController      Landing window hosting and lifecycle
├── WelcomeView                  Landing window UI
├── RecentDocumentsModel         Persisted recent-document store
├── DefaultMarkdownHandler       Reads and sets the default Markdown app
├── RichTextEditor               Rendered editing surface
├── RichMarkdownTextView         NSTextView subclass: pasteboard, code backgrounds,
│                                where a picture is, and what the pointer says
├── MarkdownImageHandleOverlay   Selection frame, corner handles, resize drag
├── DiagonalResizeCursor         Diagonal resize pointers for macOS 13–14
├── SourceTextEditor             Raw Markdown editing surface
├── EditorColorThemeAppKit       NSAppearance for a theme
├── FileExplorer*                Sidebar model, outline view, header
└── ThemePickerPopover           Customize Theme UI
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
5. *Platforms share source rather than being ported to.* iOS compiles the same
   `Shared/` package. Everything AppKit and UIKit disagree about is named in one
   file, `PlatformTypes.swift`.

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
| `make check-scroll` | Drives real AppKit text views and asserts the "never jump" scroll rules |
| `make check-session` | Compiles the real session against recording panes: which pane may move which, and what happens when another app rewrites the open file |
| `make check-image-handles` | Renders real attachments and finds them by pixel: proves the picture rect is the drawn picture and not its line box, and guards the baseline-offset rule across seven offsets |
| `make check-image-layout` | The same geometry through the **real** `RichMarkdownStyler`, plus the pointer shape at each place it matters, the clicks that select a picture, dragging a picture to a new place in the document, and the four ways a resize used to go wrong: focus, reflow, a refused commit, and a cursor stranded by teardown |
| `make check-editor-clicks` | Hosts the **real SwiftUI editor**, opens a document off disk, and asks the window which view a click on a picture would actually reach — the one check that can see a floating explorer or gripper covering the preview |
| `make check-image-cursors` | Opt-in. Drives the real mouse across a real screen and identifies the pointer from screen pixels. Needs `MDE_ALLOW_SCREEN_CONTROL=1`, an idle machine, and an **unlocked screen** — `screencapture -R` and `-l` both fail behind the lock screen while full-screen capture still succeeds, so a locked machine looks like a broken check. Its first assertion is that it can see every cursor it is able to name — see I-56 |
| `make clean` | Cleans the package build directory and removes `build/` |

`Scripts/build-app.sh` builds the executable, assembles the bundle from
`Packaging/Info.plist` and the two `.icns` files, lints the plist, code-signs ad
hoc, and verifies the signature with `codesign --verify --deep --strict`.

It also copies any `<Package>_<Target>.bundle` SwiftPM left beside the
executable into `Contents/Resources`, which is where `Bundle.module` looks. No
shared target declares `resources:` today, so this copies nothing — that is the
point of it. The first target to gain a resource, or the first dependency that
ships one, would otherwise build and sign cleanly and then trap on launch
inside the generated `Bundle.module`, with nothing in the build output naming
the cause. `iOS/Scripts/build-app.sh` does the same, into the bundle root,
because an iOS app bundle is flat. Both were checked by temporarily giving
`MarkdownEditorUI` a resource and confirming it arrived in each app.

`Scripts/install-app.sh` replaces any existing `/Applications/Markdown
Editor.app`, unregisters the `build/` copy, and registers the installed one with
`lsregister`. Set `INSTALL_DIR` to install somewhere else. Use `make run` for
development and `make install` for the copy Finder should open files with.

Both `install-app.sh` and `uninstall-app.sh` ask a running copy to quit, then
**wait up to ten seconds and refuse** if it is still there. Neither forces the
removal. A quit that does not complete usually means the app is holding an
unsaved-changes sheet, and deleting the bundle at that moment destroys the app
the person is being asked about and leaves them answering a dialog belonging to
something no longer on disk.

`Scripts/make-icons.swift` draws both icons with Core Graphics and packs them
with `iconutil`, so there is no asset catalog or design tool in the loop. The
results are committed, so a normal build never runs it.

`Scripts/run-tests.sh` runs `swift test` against the **`../Shared` package**,
adding the Swift Testing framework search path and rpath from the active Xcode
toolchain when the toolchain does not expose it directly. The tests live with
the code they cover, so this one command covers the iOS build's engine too.

### 16.1 Test coverage

417 tests across 31 suites, in the shared package:

| Suite | Tests | Covers |
| --- | --- | --- |
| Markdown formatting | 42 | Every inline and block transform, toggle-off detection, renumbering, list continuation |
| Cloud workspace | 39 | Firestore tree reads and writes, moves, and the prefix filter a range query needs |
| Markdown render model | 31 | Block and inline parsing, boundary rules, escapes, range mapping |
| Remote images | 29 | Which addresses are fetched, the transfer ceiling enforced against a stubbed server, decoding, failure caching |
| Image tags | 25 | `<img …>` parsing and writing, liberal attribute forms, proportional sizing |
| Moving an image | 14 | Moving a picture's Markdown, the offset correction a forward move needs, dropping on itself, HTML tags, sizes surviving the move, and a move that undoes itself |
| Local image cache | 12 | Serving unchanged files from memory, re-reading a picture edited underneath us, the pixel-cost budget, and unreadable files |
| Editor scroll geometry | 18 | When a pane's figures may be trusted, fraction ↔ offset conversion, and the recorded numbers from the typing-jump bug |
| Markdown text codec invariants | 14 | Byte-exact round trips over the corpus, line endings, byte order marks, nine shapes of malformed UTF-8 |
| Cloud paths | 14 | Stems, extensions, parents, descendancy, collision numbering |
| Editor color themes | 13 | All sixteen palettes: WCAG contrast for body, secondary, selected and code text; sRGB resolution; storage round trips |
| Rich Markdown styler | 11 | The styled string matches the model's length, no attribute run escapes it, proportional image sizing |
| External change watching | 18 | Reporting another app's writes without ever reporting our own, including atomic replacement |
| External document change | 13 | The decision itself: adopt, hold, or stay quiet, and what autosave may do while a notice is up |
| Editor image geometry | 11 | Where a picture is, where its handles are, which corner a point belongs to, and the aspect-ratio vote |
| Editor pane geometry | 11 | Pane widths, centring, and the minimums each layout has to respect |
| Image handle source guards | 3 | That the pointer, the click, and the drag all still go through one rect function, and that a pushed cursor is popped |
| Recent documents catalog | 10 | Merge order, de-duplication, Markdown filtering, caps, promotion, removal, pruning of missing files, home-relative paths |
| New document | 10 | Heading 1 seeding |
| Platform types | 9 | AppKit/UIKit parity; portable colour blending within 1/255 of `NSColor.blended` on every colour the app displays |
| Markdown text insertion | 8 | Caret placement, clamping stale selections, UTF-16 offsets |
| Markdown render model invariants | 8 | Every span addresses real text, both mappings stay in bounds, every prefix and suffix renders safely |
| Markdown formatting invariants | 7 | Seventeen commands over every corpus selection: bounds, surrogate pairs, clamping, involution |
| Markdown image importer | 6 | Assets folder naming, collisions, symlink rejection, unsaved documents, unsupported types |
| Local image resolution | 11 | Which paths in a real document actually draw the reader's picture: beside, below, above, absolute, spaced and percent-encoded — and which correctly draw nothing |
| File tree scanner | 6 | Ordering, hidden files, packages, symlinks |
| Cross-platform contract | 5 | The exported fixtures still describe the compiled Swift |
| Markdown source styler | 4 | Styling is not undoable, and survives a text view that resets its undo manager mid-edit |
| Markdown text codec | 3 | UTF-8 round trip, BOM preservation, invalid input |
| Markdown text difference | 3 | Minimal replacement computation |
| Editor view mode | 2 | The three layouts round-trip through storage and have distinct icons |

### 16.2 What the three kinds of test are each for

The suites above are not all the same kind of thing, and the distinction is
what makes them worth keeping.

**Example tests** say what specific Markdown should do. They are readable, they
document intent, and they are where a new feature's behaviour is pinned.

**Invariant tests** say what must be true of *everything*. They run every
command over every selection of every document in the shared corpus — about
7,667 combinations for formatting alone — and assert properties rather than
outputs: a returned selection is always inside the text it belongs to, never
splits an emoji, and never discards the document. They are cheap to run and
they cover input nobody thought to write down, including every prefix and
suffix of every corpus document, which is what the renderer actually sees while
somebody is still typing.

**The contract fixtures** pin exact output for 8,180 formatting cases.

Each covers what the others cannot, and this was measured rather than assumed.
Shortening strikethrough's closing marker from `~~` to `~` is invisible to the
involution test — add and remove read the same table, so the text still
round-trips perfectly — and invisible to the safety invariants, because nothing
is out of bounds. The fixtures catch it, because the bytes changed. Conversely,
removing the clamp from `sourceRange(for:)` passes every fixture and crashes
the invariant run outright.

### 16.3 What the invariants deliberately do not assert

Two properties are scoped rather than universal, and both are recorded here
rather than being quietly narrowed.

Toggling an inline style twice restores the text — but only where the toggle
has one obvious answer. Wrapping `and *ligature` in italics does not: the
selection already contains an unclosed marker. Nor does adding a backtick
immediately before a ``` fence, where the new delimiter merges into the fence
and lengthens it. These are ambiguities in Markdown, not defects in this
implementation, so the check covers selections whose text and immediate
neighbours are free of marker characters — 645 combinations of the case a
writer actually hits. The ambiguous selections are still covered by every
safety invariant; only the question of what the text should settle to is set
aside.

Text that *begins* with U+FEFF cannot survive a round trip as a character,
because the bytes a leading zero-width no-break space encodes to are the same
three bytes as a byte order mark. Every UTF-8 editor resolves that the same
way. The file still round-trips byte for byte, which is the property that
matters, and there is a test that says so.

### 16.4 Scroll checks

`make check-scroll` is separate from the suite because what it checks is not
reachable from one. Every scroll bug this app has had lived in AppKit — a clip
view with no height, a document frame reporting only the part laid out so far,
a caret reveal undone by a later restore — and every one of them passed the
unit tests. `Scripts/check-scroll.swift` builds real `NSTextView`s configured
the way the editor configures them and asserts the behaviour directly: 22
checks over three document sizes.

The checks are mutation-tested. Removing the targeted layout fails 6, removing
the receiving pane's layout pass fails 2, revealing the caret before restoring
the offset fails 1, treating a partly visible caret as visible fails 1, and
publishing selection changes made while the text storage is being replaced
fails 1.

The last of those pins a platform behaviour rather than a rule of our own.
Replacing a text view's storage makes AppKit move the selection before the
intended one is put back, and it announces that intermediate value through the
delegate exactly as it announces a real caret move — measured at character
102,890 while the caret sat at 35. Both panes re-style on every keystroke and
publish selection changes to the other pane, which reveals them, so an
unguarded delegate threw the other pane most of the way down the document and
back on every character typed.

One trap is worth stating, because it made an earlier version of these checks
worthless. `NSTextView` never shrinks its frame — once it has been laid out it
keeps that height — so re-styling an already-measured pane cannot lose the
scroll offset and proves nothing. The pane that loses it is one that has not
been measured yet, which is what a document being opened finds. The checks
start from that state deliberately.

The remote-image suite talks to a stubbed `URLProtocol` rather than the network,
because the rules that matter are inside the transfer. An earlier version tested
only the pure helpers around it, and a mutation run showed what that was worth:
deleting the size check from the streaming loop left all 235 tests green. Eight
mutants are now killed, including that one, ignoring the HTTP status, an
off-by-one on the ceiling, accepting a `file:` URL, and never recording a
failure.

Two things that cost time there and are worth knowing before adding to it.
Swift Testing runs a suite's tests **in parallel**, so a shared `reset()` on the
stub table wipes stubs another test has just registered — each test uses a URL
of its own instead. And `file:///etc/passwd` is refused by the *host* check, not
the scheme check, so a test using only that form cannot tell whether the scheme
check exists; `file://localhost/etc/passwd` is the one that proves it.

The local image cache is mutation-tested the same way, and two of the four runs
are worth recording because the first version of the tests did not kill them.

Keying the cache on the path alone — the stale-image bug the whole design exists
to avoid — fails 3. Costing every entry the same, which would turn the 192 MB
ceiling into "192 million pictures", fails 1, but only after a test was added
that puts two images into a cache sized for one; asserting on the cost function
alone never checked that its answer reached the cache. Dropping the size from
the key fails 1, and that one took two attempts: the first version read the
file's modification date and set it back, which does **not** round-trip — the
filesystem keeps nanoseconds `Date` does not reproduce, so the key changed for a
reason unrelated to size and the test passed no matter what the key contained.
Pinning both writes to an explicit whole second makes the timestamps genuinely
identical, so only size can tell the two files apart. Never reading from the
cache at all fails 2.

### 16.5 Testing a build without touching real documents

`MDE_DEV_BUNDLE=1 ./Scripts/build-app.sh` builds the same app under a different
identity: `com.kirupa.markdown-editor.dev`, named **Markdown Editor (Dev)**, and
with `CFBundleDocumentTypes` removed.

This is not cosmetic. The installed copy and the `build/` copy otherwise share
one `CFBundleIdentifier`, and macOS keys **saved window state** on it, so
launching a test build restored whichever real documents the installed copy last
had open — into a build that autosaves. Removing the document types also stops
Launch Services handing the dev build a real `.md` file, and `open -a "$PWD/build/…"`
rather than `open -n` keeps a launch from starting a second copy of the
*installed* app.

Any script here that launches the app uses it. Use it for anything manual too.

### 16.6 Split-pane coordination checks

`make check-session` covers `MarkdownEditorSession` — the object that decides
when one pane is allowed to move the other. It lives in the app's executable
target, which no test target can import, so it went untested for a long time.
That is how E-28 got in. `Scripts/run-session-checks.sh` compiles the real app
sources, minus the `@main` entry point, together with
`Scripts/check-session.swift`, linking against the object files SPM has already
built for the shared package. 30 checks.

Fifteen of those cover the split panes. The other fifteen cover [§5.6](#56-changes-made-by-another-app),
against real files in a temporary directory rather than a double: the harness
writes to them the way a real editor saves — a temporary file renamed over the
target — because that is the case a naive watcher gets wrong. Two suites, one
for changes made by another app (noticed, applied, named and undoable, the
banner's state, a *second* write still noticed, a clash not applied silently,
autosave held, Keep Mine resuming it, Reload from Disk) and one for the inverse,
that the app's own saves are never mistaken for somebody else's (an announced
save, an unannounced save that matches the screen, an event arriving late, and
a genuine change still reported afterwards).

What the checks pin down is the distinction the bug turned on: `attach` is
called from SwiftUI's `updateNSView`, which runs for **both** panes on **every
keystroke**, and it was re-running the catch-up meant for a pane joining the
split. So the checks assert both halves — typing moves neither pane, and a pane
that genuinely joins a split is still aligned exactly once. They also assert
that suppressing the redundant work did not reach real scrolling and real caret
moves, which are how the panes track each other at all.

Mutation-tested: restoring the original per-update alignment fails 4, dropping
the reset when the view mode changes fails 1, dropping it when a pane detaches
fails 1, and never pruning the identities of panes that were freed fails 1.

That last one is not hypothetical. Telling panes apart means holding their
identity, the session holds panes *weakly* because they are deallocated without
`detach`, and an address that has been freed gets reused — so a pane allocated
where a dead one used to be is taken for one that has already caught up, and
opens out of step. The check allocates a pane, drops it without detaching, and
allocates another; with the pruning removed the replacement lands on the dead
pane's address and is never aligned. Identities are pruned to the live panes
wherever the weak list is already being compacted.

Worth knowing if you extend this: the catch-up applies a normalized *fraction*,
and the two panes render the same text at different heights, so re-applying it
is not idempotent — each repetition drags the idle pane further out of step.
That is why "it runs more often than needed" was a correctness bug rather than
a performance one.

The external-change half is mutation-tested too: neutering the branch that
recognises an unannounced save by its matching the screen fails 2, and making
`isSavingSuspended` always `false` fails 1. Each kills exactly the checks it
should, and the control passes 30/30 restored.

One limit, stated plainly because the harness is easy to mistake for more than
it is: **§5.6 has never been watched working in the running app.** These checks
drive the real session object against real files, which is the strongest thing
available without a screen, but they do not draw the banner, and nothing has
confirmed that AppKit delivers the events to a window the way it does to a test
process. What is verified is the decision, the monitor, the wiring from the
session, and the effect on the document's text and undo stack.

---

### 16.7 The native Firestore adapter is verified against a real Firestore

`Shared/Firebase/run-emulator-checks.sh` runs `FirestoreNodeStore` against an
emulated Firestore. 31 checks.

The Swift suite covers the cloud *decisions* — path arithmetic, subtree moves,
collisions — against an in-memory double, which is what keeps it fast and
offline. What a double cannot answer is whether the adapter speaks Firestore
correctly, and that is what these cover: the field names it writes (`type`, not
`kind` — the Swift property and the stored field deliberately differ, because
the field name is what `firestore.rules` validates and what the web build
writes), whether the range query in `subtree` needs its separator filter,
whether a batch is atomic, and whether a listener fires.

It runs **unauthenticated**, against permissive rules in
`Shared/Firebase/emulator/`, for two reasons.

The first is forced. FirebaseAuth persists its session to the macOS
data-protection keychain, which requires the `keychain-access-groups`
entitlement. That entitlement is restricted — it needs a provisioning profile,
so ad-hoc signing cannot grant it, and a binary that claims it anyway is
SIGKILLed at exec. A SwiftPM executable therefore cannot sign in at all;
`signInAnonymously()` fails with `SecItemAdd (-34018)`.

The second is that it should have been this way regardless. The rules are one
artifact shared by every client and are already verified by
`Web/firebase/check-rules.mjs` against the real rules engine, cross-account
refusals included. Asserting them here too would test Google's rules evaluator
twice and this adapter zero times. `FirestoreNodeStore` takes a uid as a plain
string and puts it in the document path, so the collection paths exercised are
the shipped ones with no one signed in — and one check covers the adapter's own
half of that separation, that a second uid cannot name the first one's
documents.

Two findings came out of writing it. The listener check needs a **second
Firebase client**, not just a second store: `watchNode` drops any snapshot with
`hasPendingWrites`, and a listener without `includeMetadataChanges` gets no
further snapshot when the server acknowledges a write whose data has not
changed, so a client cannot observe its own write at all. A check that wrote
through the same store would have been testing nothing. That behaviour is what
the sync policy rests on, so it is now asserted in both directions rather than
assumed. And the batch check forces its refusal with Firestore's own
1,048,487-byte property limit rather than a rules violation, so it keeps
working whatever the rules say.

Mutation-tested: dropping the separator filter fails 2, renaming the `parent`
field fails 1, renaming `type` fails 1, dropping the uid from the document path
fails 1, and removing the local-echo guard fails 1. A reworded comment survives.

Needs a JDK and the Firebase CLI, so it is not part of `make test`; the script
exits 2 with a hint if either is missing.

---

### 16.8 FirebaseAuth cannot sign in from a build this repository can produce

`Shared/Firebase/Scripts/check-keychain.sh` answers one question, and the
answer decides whether a cloud sign-in screen is worth building at all.

FirebaseAuth persists its session to the macOS **data-protection keychain**,
which requires the `keychain-access-groups` entitlement. That entitlement is
*restricted*: it has to be authorized by a provisioning profile, and a
provisioning profile requires an Apple Developer Program team. Ad-hoc signing
— which is what [P-4](#3-platform-and-technical-requirements) specifies and
what `Scripts/build-app.sh` does — cannot grant one.

The obvious hope was that this was a property of an unbundled binary rather
than of the app, since `firebase-emulator-check` is a bare SwiftPM executable
and the shipping app is a signed bundle with an identifier. It is not. The
script runs the same `signInAnonymously()` three ways against the Auth
emulator, and prints all three because the comparison is the point:

| Form | Result |
| --- | --- |
| Bare executable | `SecItemAdd (-34018)`, "a required entitlement isn't present" |
| Ad-hoc-signed `.app`, exactly as `build-app.sh` signs it | the same `-34018` |
| `.app` claiming `keychain-access-groups`, ad-hoc signed | **SIGKILL at exec**, exit 137 |

So there is no arrangement of bundle, identifier, and ad-hoc signature that
works, and presenting the entitlement the error asks for makes it worse rather
than better — the process does not reach `main`.

#### What exactly is refusing us

This is the real gate on native cloud support, and a larger one than the
Firebase console step previously recorded as the only blocker. Three identical failures say something is missing, but not *what*, and the two
candidate causes have very different fixes: if an ad-hoc signature cannot reach
the keychain **at all**, only an Apple account will do; if only the
data-protection keychain refuses, the fix might be to ask for the other one and
need no account at all. macOS has two — the legacy file-based keychain, which
has no entitlement requirement, and the data-protection keychain, opted into
per query with `kSecUseDataProtectionKeychain`.

`keychain-kind` writes the same item to both, from one process, so the only
difference between the two calls is that flag. It is Security-framework only —
no Firebase, no emulator, no network — so it re-runs against any signature in a
second:

| Signature | Data-protection | File-based |
| --- | --- | --- |
| Ad-hoc-signed `.app` | `-34018` | **writes and reads back** |
| Ad-hoc + `com.apple.security.app-sandbox` | `-34018` | **writes and reads back** |

**The signature is not the problem.** The same bundle that FirebaseAuth cannot
use is perfectly able to persist a keychain item; it is the data-protection
keychain specifically that is closed. The sandbox row is there because
`app-sandbox` is the one relevant entitlement that is *not* restricted — ad-hoc
signing can grant it, and a sandboxed app gets an implicit keychain access
group. If that group were sufficient, native sign-in would need no Apple account
whatsoever. It is not sufficient.

That leaves the obvious question: if the file-based keychain works, can
FirebaseAuth be pointed at it? **No.** It sets
`kSecUseDataProtectionKeychain = true` unconditionally, at both of the two
places it builds a query — `AuthKeychainServices.genericPasswordQuery` and
`AuthStoredUserManager.keychainQuery` — with no option, no initializer
parameter, and no environment variable. Those two lines are the entire surface,
and they are not configurable. Worth writing down so the next person does not
spend an afternoon looking for a flag that does not exist.

And one more hope, since the failure happens while *persisting* the session
rather than while authenticating: if the network half of sign-in completed and
only the keychain write failed, `currentUser` would still be usable for the
current launch. That would be a very different product — cloud support with a
"sign in every launch" limitation, rather than no cloud support — so it is
worth asking rather than assuming. The probe checks `currentUser` after the
throw, and:

    NOTE no user survived the failure.
    => the sign-in is lost entirely, not merely unpersisted.

FirebaseAuth treats the keychain write as part of the sign-in transaction and
unwinds the whole thing. There is no degraded mode to fall back to.

#### What would actually settle it

What it needs is a **real signing identity** — one whose provisioning profile
can authorize the entitlement. The probes above narrow what such a test has to
grant: not a signature as such, but a **keychain access group** for the
data-protection keychain.

Precisely how much of an Apple account that takes is **not measured here**, and
the difference matters enough not to guess: Xcode's automatic signing issues a
development certificate from a *Personal Team* for a free Apple ID, which may
well be enough for a local build, and a paid Apple Developer Program membership
certainly is. This machine has neither — `security find-identity -v -p
codesigning` reports zero identities and there are no provisioning profiles —
so the signed case could
not be tried, and this section will not claim an answer it does not have.

What *is* measured is that no amount of ad-hoc signing works, which is what
[P-4](#3-platform-and-technical-requirements) currently specifies, and that the
blocker is the keychain kind rather than the signature. Somebody with a signing
identity should re-run the script before any of this is built on.

What is *not* affected: `FirestoreNodeStore` itself, which needs no keychain
and is verified in [§16.7](#167-the-native-firestore-adapter-is-verified-against-a-real-firestore).
The plumbing is sound; it is the front door that cannot open. Nor is the web
build affected, which does not use the Apple SDK.

The probe is kept rather than deleted because the finding is load-bearing and
re-deriving it is slow. It is not part of `make test` — it needs a JDK and the
Firebase CLI, and it is a one-off answer to a one-off question.

One trap worth recording, since it cost an hour: the first version of the probe
blocked the main thread on a semaphore while waiting for FirebaseAuth's
completion handler, which is delivered **on the main queue**. That deadlocks,
and a deadlock presents as a hung network call — the stack shows a live
`NSURLConnectionLoader` thread and nothing about keychains. The probe uses an
async `@main` instead.

---

## 17. Release history

| Change | Summary |
| --- | --- |
| Draw the picture the document points at | A picture kept **above** the document — `../images/photo.png`, the layout every static site generator and most note folders produce — silently did not draw. The renderer applied the *assets containment* rule to reading, but that rule is about writing: an import must not put a file outside the document's folder. Reading was never the same act, and the app can already open anything its reader can, so the check protected nothing and cost the picture. What made it hard to see is that an unresolved picture is not a broken one: a placeholder symbol takes its place, so the line still looks deliberate, and the visible symptom is the unrelated-sounding "I cannot select my image". Every styler test until now passed `documentURL: nil`, so resolution had never been exercised once; there are now 11 tests over the path shapes real documents use, and they distinguish the reader's picture from the placeholder by aspect ratio rather than by the mere presence of an attachment. See [§9.9](#99-which-pictures-actually-draw). |
| Make a resize land on the picture you dragged | Four faults behind image resizing, all found by review rather than by use. Clicking a picture never focused the pane it was in — the image path returns before `super.mouseDown`, so `NSTextView` never took first responder — and the commit then resolved the target through *whichever pane had focus*, which in Split view is the Markdown pane. A resize could therefore rewrite a **different image** or refuse outright. The commit now carries the source offset the handles were drawn around. The handles also never moved on **reflow**, so a window resize or a width drag left them over blank text while still taking the drag; and a **refused** resize left the picture at the size the drag abandoned it at, because a drag previews by changing the attachment's bounds and only a re-render puts them back. Finally, a drag ended by the view going away stranded a pushed `NSCursor` — a process-wide stack, so the diagonal arrow leaked into every other app. See [§9.7](#97-selecting-and-resizing-a-picture), [§9.8](#98-what-the-pointer-says). |
| A calmer page, and pictures you can pick up | The explorer is closed by default (`⌃⌘S`) and floats over the document instead of taking a column, so opening it no longer slides the text. The rendered preview is centred in the window and the width gripper appears only on hover. A picture can be **clicked to select and dragged by a corner to resize**, always proportionally, written back as the `<img …>` spelling GitHub honours. See [§9.7](#97-selecting-and-resizing-a-picture), [§11.1](#111-staying-out-of-the-way), [§13.3](#133-a-calm-page). |
| Make the pointer tell the truth over a picture | The pointer is now the arrow over a picture and a matching diagonal resize over each corner, instead of an I-beam everywhere and one crosshair on all four. Three faults sat underneath: the shape changed over the drawn 9 pt handle while clicks were accepted over a 15 pt one, leaving a 3 pt ring where the pointer promised a resize that did not happen; the rects were never re-registered when a picture moved or scrolled; and the picture's own rectangle was wrong. `location(forGlyphAt:)` already folds in `NSTextAttachment.bounds.origin`, so applying it again put every handle 4 pt below the corner it was holding — `attachmentRect` now takes a size, so the origin cannot be passed at all. Measured against drawn pixels across seven baseline offsets on both axes. See [§9.8](#98-what-the-pointer-says). |
| Notice when another app changes the open document | The editor watches its file and says so when something else writes it. With nothing unsaved it applies the newer text and shows a self-clearing bar; the caret is carried over and it lands on the undo stack as one entry named *Refresh*. With unsaved edits it applies nothing, shows a bar offering **Reload** (`⇧⌘R`) or **Keep Mine**, and **suspends autosave until one is chosen** — otherwise the notice would be pointless, because autosave would overwrite the other app's version a second later. **File ▸ Reload from Disk** (`⇧⌘R`) re-reads on demand. The hard part is the 1.5-second autosave: the app's own writes must never come back as somebody else's, including a write whose event lands after further typing. The monitor also re-arms across atomic replacement — a temp file renamed over the target, which is how most editors and `git` save — because a watcher that misses that reports the first external save and is deaf forever after. See [§5.6](#56-changes-made-by-another-app). |
| Narrow the keychain blocker to the keychain, not the signature | The three `-34018` failures said something was missing but not what, so a second Firebase-free probe (`keychain-kind`) writes the same item to both macOS keychains from one process. The ad-hoc-signed bundle writes to the **file-based keychain** perfectly well and is refused only by the **data-protection** one — so the signature was never the problem. Adding `com.apple.security.app-sandbox`, the one relevant *unrestricted* entitlement, does not help either, which rules out the only fix that would have needed no Apple account. FirebaseAuth cannot be redirected: it sets `kSecUseDataProtectionKeychain` unconditionally at both of the two places it builds a query. And there is no degraded "sign in every launch" mode to fall back on — no `currentUser` survives the throw, so the sign-in is lost rather than merely unpersisted. Sharpens the open question in [§16.8](#168-firebaseauth-cannot-sign-in-from-a-build-this-repository-can-produce) from "does signing help" to "does a Personal Team profile grant a keychain access group". |
| Establish why native cloud sign-in is blocked | FirebaseAuth cannot sign in from any build this repository can produce: it needs the macOS data-protection keychain, whose entitlement is restricted and must be authorized by a provisioning profile. Measured three ways — bare executable, ad-hoc-signed `.app`, and an `.app` claiming the entitlement, which is SIGKILLed at exec. Corrects [NG-3](#22-non-goals) and the root README, both of which named the Firebase console step as the only thing outstanding. See [§16.8](#168-firebaseauth-cannot-sign-in-from-a-build-this-repository-can-produce). |
| Verify the native Firestore adapter against a real Firestore | `Shared/Firebase/run-emulator-checks.sh` runs `FirestoreNodeStore` against an emulated Firestore — 31 checks over field names, the subtree filter, batch atomicity, listener delivery, and per-account isolation. Closes the half of NG-3 that said the cloud path had never been exercised on any native build; the sign-in UI and the Firebase console step remain. See [§16.7](#167-the-native-firestore-adapter-is-verified-against-a-real-firestore). |
| Ship resources if a target ever declares one | Both no-Xcode build scripts now copy the `<Package>_<Target>.bundle` SwiftPM emits for a target with `resources:` — into `Contents/Resources` on the Mac, the bundle root on iOS, which is where `Bundle.module` looks on each. Nothing declares a resource today, so both copy nothing; a target that gained one would previously have built and signed cleanly and trapped on launch. Verified by temporarily giving `MarkdownEditorUI` a resource and confirming it reached both apps. |
| Keep typing responsive on an illustrated document | Local images are decoded once and kept in memory instead of being re-read from disk on every keystroke. A document of forty photo-sized references styled in 65.7 ms per character, about 15 fps; it now styles in 4.0 ms. The cache is keyed on modification date and size, so a picture edited in another app is read again rather than drawn stale, and it is costed by pixel area against a 192 MB ceiling so an illustrated document cannot outgrow the rest of the app. |
| Stop the idle pane drifting on every keystroke | The split no longer nudges the pane you are not typing in. Catching a pane up with its neighbour is meant to happen when it joins the split, but it ran on every SwiftUI update — twice per keystroke — and it applies a normalized fraction between panes of different heights, so it is not idempotent. Measured at 40 unwanted moves over 20 keystrokes, now 0. `make check-session` compiles the real session against recording panes and asserts which pane may move which. |
| Stop the panes jumping while typing in the preview | Typing in the rendered pane no longer makes the split jump. Re-styling replaces the whole text storage on every keystroke, and AppKit announces an intermediate selection while it does — measured 19,681 characters from the real caret. Both panes published that as though the writer had moved the caret, so the other pane scrolled most of the way down the document and back on every character. Selection changes made during a re-style are now suppressed, and the settled selection is published once the re-style finishes. iOS already guarded this; only the macOS panes did not. |
| Expand the regression net | 317 tests across 23 suites, up from 262 across 17. Adds property-based suites that run every formatting command over every selection of every corpus document, render and style every prefix and suffix of that corpus, hold all sixteen palettes to WCAG contrast thresholds, and check the read/write path is byte-exact against nine shapes of malformed UTF-8. Every new suite is mutation-tested. |
| Stop the editor jumping while typing | Typing near the top of a document no longer throws the page down and back. A pane now restores its exact scroll offset rather than a fraction of its travel, withholds its position until it is fully laid out, measures itself before applying one, and reveals the caret only after the offset is restored — and only when the caret is not already visible. `make check-scroll` asserts the behaviour against real AppKit views. |
| Draw images held at a web address | An image referenced by `https://…` renders as the real picture instead of a placeholder glyph, in both the rendered and split editors, and can be measured for proportional resizing. The address and link fields no longer wrap a long URL. |
| Sized images and insert by address | Insert ▸ Image asks for a file or a web address; Insert ▸ Image Size… (⇧⌥⌘I) sets a proportional width and height on the image at the caret. The size is written as `<img …>`, the one spelling GitHub honours. |
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
| Share the Swift core between platforms | Core and styling moved to `../Shared` and compiled by both native apps; `NSColor`'s Generic RGB blending reproduced portably for UIKit; no user-visible change on macOS |

---

## 18. Out of scope / not yet supported

Known gaps, recorded deliberately so they are not mistaken for bugs:

| Area | Status |
| --- | --- |
| Tables | Not parsed. Table source is preserved as literal text. |
| Reference-style links (`[a][b]`) | Not parsed. Only inline `[a](b)` is supported. |
| Indented (4-space) code blocks | Not parsed as code. Use fenced blocks. |
| Footnotes, definition lists, admonitions | Not supported. |
| HTML other than `<u>` and `<img>` | Passed through as literal text, not rendered. |
| Hard line breaks via trailing spaces or `<br>` | Not rendered as breaks. |
| Dragging an image file into the document | Not wired to the import path; use Insert ▸ Image…. |
| Pasting image data from the clipboard | Not wired to the import path. |
| Syntax highlighting inside fenced code blocks | The language identifier is parsed and retained but not colorized. |
| Export to HTML or PDF | Out of scope. |
| Custom Find and Replace UI | Out of scope. The standard macOS find panel with incremental search is enabled instead. |
| Resizing a picture by an edge or by keyboard | Only the four corners resize, and only by dragging. There is no side handle (which would not preserve the aspect ratio) and no keyboard equivalent; **Insert ▸ Image Size…** (`⇧⌥⌘I`) covers the exact-numbers case. |
| Selecting more than one picture | Selection is one attachment character, so pictures cannot be multi-selected or resized together. |
| Pointer shapes verified on every run | `make check-image-layout` asserts what `pointerCursor` answers at each place that matters, which is deterministic. Whether AppKit then *shows* that shape is a separate question, and one this app got wrong for a long time while the in-process checks passed — see I-57. `make check-image-cursors` settles it against real screen pixels, currently 8 of 8, but it drives the real mouse and so is opt-in and not part of any suite. |
