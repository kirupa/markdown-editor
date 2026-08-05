# Markdown Editor

A Markdown editor that treats the source file as the document, built for the
Mac, for iPhone and iPad, and for the browser.

All three edit the *same* Markdown the same way. Rendering is an editable
projection of the source, not a replacement for it — so text you didn't touch
comes back byte for byte, and a folder written by one build opens in the others
with every image still resolving.

| | [macOS](macOS/) | [iOS](iOS/) | [Web](Web/) |
| --- | --- | --- | --- |
| Built with | SwiftUI + AppKit | SwiftUI + UIKit | ES modules + PHP |
| Dependencies | none | none | none |
| Files live | anywhere on disk | Files and iCloud Drive | in a workspace folder, `~/kirupaMarkdown` by default |
| Get started | `cd macOS && make install` | open `iOS/MarkdownEditor.xcodeproj` | `Web/serve.sh` |
| Publish it | — | — | `Web/deploy.sh` to any PHP host |
| On a phone | — | native, iPhone and iPad | a thumb-first layout, `⌃⌘M` or automatic |
| Requirements | macOS 13+, Swift toolchain | iOS 17+, Xcode | PHP 8.1+ |

## What it does

- **Three editing modes** — rendered, side by side, or raw Markdown — with the
  rendered view fully editable and the two panes synchronized
- **A complete formatting toolbar and menu bar**: headings, bold, italic,
  underline, strikethrough, inline and fenced code, bulleted, numbered, and task
  lists, block quotes, links, and horizontal rules — all toggling, all with the
  standard shortcuts
- **Images** dragged, pasted, or chosen, copied into `<document>.assets/` beside
  the file and referenced relatively, with collisions resolved rather than
  overwritten
- **A file explorer** with lazy expansion, reveal, and an ancestor path dropdown
- **File management**, in the web build: create, rename, duplicate, drag to move,
  and delete files and folders from the sidebar — with a document's images
  following it through a rename, and its references rewritten to match
- **Sixteen themes** — eight kirupa.com colors on a light/dark axis
- **Autosave**, undo that moves in meaningful units, and a welcome screen with
  recent documents

Each build's README is a full product requirements document:
[macOS](macOS/README.md) · [iOS](iOS/README.md) · [Web](Web/README.md).

The iOS build is newer than the other two and does not have all of it yet — no
file explorer, no split-pane sync, no cloud storage. Its README records the
gaps explicitly, along with what has and has not been verified by actually
running it on a simulator.

## Using it across devices

There is nothing to migrate. A document is a `.md` file, its images sit in a
`<stem>.assets/` folder beside it, and image references are relative — so a
folder is self-contained and can live anywhere.

- **macOS** — save into iCloud Drive, Dropbox, OneDrive, or Google Drive and
  keep working. The app isn't sandboxed, so any folder you can reach works, and
  it's built on the standard document system, so writes coordinate with the sync
  client rather than racing it.
- **iOS** — the system document browser reaches iCloud Drive and every other
  Files provider, and documents are edited in place rather than copied in.
- **Web** — point `MARKDOWN_EDITOR_WORKSPACE` at the same synced folder, or
  symlink `~/kirupaMarkdown` to it.
- **Or skip syncing entirely** — host the web build once and every device
  reaches the same files through a browser. `Web/deploy.sh` publishes to a
  shared PHP host, including the layout that keeps your documents above the
  document root. The editor has no accounts of its own, so put it behind the
  web server's own authentication before pointing it at anything private.

The one caveat: editing the same document on two devices at once produces a
conflict copy, because neither build merges. Details in
[Web/README.md § 5](Web/README.md#5-the-workspace).

## Where storage is going: cloud-first

The intended end state is one storage model everywhere — **Firestore is the
document store, and every device keeps an offline copy of what it has opened**.
Local files stop being an alternative destination and become the cache.

This is a direction, not a description. Where it actually stands today:

| Build | Talks to Firestore | Offline copy |
| --- | --- | --- |
| Web | Yes, but as an opt-in alternative to the PHP workspace, which is still the default | Yes, for documents opened on the device |
| macOS | **No.** Local `.md` files only | n/a |
| iOS | **No.** Local `.md` files only | n/a |

So one of three builds has a cloud path, and it is the one that is not the
default. Getting the rest of the way needs, in order:

1. **Enable Cloud Storage and publish the security rules.** Console work, and
   the only steps nobody can do from this repository. Until the bucket exists no
   image in cloud mode can be uploaded, fetched, or tested even once, and until
   the rules are published the database is readable and writable by anyone with
   the API key. Both were re-checked on 5 August 2026 and both are still
   outstanding — with the exact commands to repeat the checks — in
   [Web/README.md § 11b](Web/README.md#setup-steps-that-cannot-be-done-from-this-repository).
2. **Verify the cloud path against the real backend.** Every cloud decision is
   tested against an in-memory Firestore; not one byte has been written to the
   real one. Making Firestore the default while that is true would be reckless.
3. **Make cloud the default in the web build**, with local demoted to a fallback
   for anyone not signed in.
4. **Add Firestore to the native builds.** This is the largest piece, and it
   carries a decision worth making deliberately rather than by drift: it means
   adding the Firebase Apple SDK, reversing this project's no-third-party-
   dependencies rule. The alternative — Firestore's REST API over `URLSession`,
   keeping the rule intact — cannot subscribe to changes, so live updates would
   become polling, and the offline cache would have to be written by hand. The
   SDK is almost certainly the right trade, but it is a real reversal and should
   be an explicit choice.

### How images fit

Images are the one part of the data that does **not** live in Firestore. They go
to a **Cloud Storage bucket**, with Firestore holding only a pointer:

```
Firestore   users/{uid}/nodes/{id}     type: 'asset', storagePath, url, contentType
Storage     users/{uid}/<path>#<ts>    the actual bytes, 10 MB cap
```

Firestore's 1 MiB document limit is what decides this. Base64 inflates bytes by
about a third, so storing an image inline would cap it near 700 KB while eating
the same budget the document text needs — too small for an ordinary screenshot.

The Markdown itself never contains a Storage URL. It keeps the relative
`<stem>.assets/name.png` reference that all four builds already write, and the
URL is resolved when the document renders. That is what keeps a document
portable between them.

The catch worth knowing: **Firestore's offline persistence does not extend to
Storage.** Documents opened on a device are available offline; their images are
not, unless the browser happens to have them in its HTTP cache. Closing that
gap needs an explicit image cache, and it cannot be built yet because the bucket
does not exist. Both points are recorded in
[Web/README.md § 11b](Web/README.md#working-offline).

## Repository layout

```
Shared/   The Swift core and styling, compiled by both native apps
macOS/    The Mac app: SwiftUI + AppKit, bundle scripts, icons, PRD
iOS/      The iPhone and iPad app: SwiftUI + UIKit, Xcode project, PRD
Web/      The browser app: PHP backend, ES modules, PRD
```

## How the three stay in step

Two different mechanisms, because only two of the three can share Swift.

**macOS and iOS share source.** The Markdown parser, the range mapping, the
formatting commands, the image importer, the type scale, and all sixteen
palettes are the same files, in `Shared/`, compiled once per platform. They
cannot drift, because there is nothing to drift from.

That sharing turned up something worth knowing: `NSColor.blended` does not
interpolate in sRGB — it converts to Apple's Generic RGB (different primaries,
gamma 1.8), mixes, and converts back, so black halfway to white is 0.573 rather
than 0.5. UIKit has no equivalent, and a naive sRGB blend was off by up to
46/255. The portable implementation reproduces AppKit to within 1/255 on every
colour the app displays, which is asserted by test. It matters beyond iOS,
because `themes.css` is generated by compiling that same Swift.

**The web build is a port, and the port is verified rather than trusted:**

- `render-model.js` and `formatting.js` are line-by-line ports of their Swift
  counterparts, relying on the fact that Swift `NSString` offsets and JavaScript
  string indices are both UTF-16 code units
- They were differential-tested against the compiled Swift — 14,148 formatting
  cases and 41 documents through the render model, comparing output text, every
  style span, and every range mapping, with zero mismatches
- `Web/public/css/themes.css` is *generated* by compiling the app's real
  `EditorColorTheme.swift`, so derived colors cannot drift

## Tests

```bash
macOS/Scripts/run-tests.sh      # 113 tests — the shared Swift core, both apps
php Web/tests/php/run.php       # 71 tests — the PHP backend
open http://127.0.0.1:8000/tests/   # 207 tests — the browser client
```
