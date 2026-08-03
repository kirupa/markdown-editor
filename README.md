# Markdown Editor

A Markdown editor that treats the source file as the document, built twice:
once as a native macOS app, and once for the browser.

Both builds edit the *same* Markdown the same way. Rendering is an editable
projection of the source, not a replacement for it — so text you didn't touch
comes back byte for byte, and a folder written by one build opens in the other
with every image still resolving.

| | [macOS](macOS/) | [Web](Web/) |
| --- | --- | --- |
| Built with | SwiftUI + AppKit | ES modules + PHP |
| Dependencies | none | none |
| Files live | anywhere on disk | in a server-side workspace folder |
| Get started | `cd macOS && make install` | `Web/serve.sh` |
| Requirements | macOS 13+, Swift toolchain | PHP 8.1+ |

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
- **Sixteen themes** — eight kirupa.com colors on a light/dark axis
- **Autosave**, undo that moves in meaningful units, and a welcome screen with
  recent documents

Each build's README is a full product requirements document:
[macOS](macOS/README.md) · [Web](Web/README.md).

## Repository layout

```
macOS/    The native app: Swift package, app bundle scripts, icons, PRD
Web/      The browser app: PHP backend, ES modules, PRD
```

## How the two stay in step

The web build's Markdown core is a direct port of the macOS build's, and the
port is *verified* rather than trusted:

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
macOS/Scripts/run-tests.sh      # 82 tests — the Swift core
php Web/tests/php/run.php       # 32 tests — the PHP backend
open http://127.0.0.1:8000/tests/   # 83 tests — the browser client
```
