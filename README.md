# Markdown Editor

A dependency-free native macOS editor for UTF-8 `.md` and `.markdown` files.
It uses SwiftUI's document lifecycle for standard File menu behavior and an
AppKit text system for both precise source editing and editable rendered
Markdown.

## Build and run

Requires macOS 13 or newer and a current Apple Swift toolchain.

```bash
cd macOS/MarkdownEditor
make app
open "build/Markdown Editor.app"
```

`make app` creates an ad-hoc-signed application at
`build/Markdown Editor.app`. Use `make run` to build and open it in one step,
and `make test` to run the focused document, formatting, explorer, and
image-import tests.

## File and image behavior

The File menu provides the standard macOS document commands and shortcuts:
New (`Command-N`), Open (`Command-O`), Save (`Command-S`), Save As
(`Shift-Command-S`), and Close (`Command-W`). Closing a changed document uses
the system unsaved-changes prompt.

Save a new document before adding an image, then use the toolbar button or
**Insert > Image** (`Option-Command-I`). If the document is `Article.md`, the
selected image is copied to `Article.assets/` beside it and a relative Markdown
reference is inserted at the current selection. Existing names are preserved;
collisions use `image-2.png`, `image-3.png`, and so on. Supported formats are
PNG, JPEG, GIF, WebP, TIFF, BMP, HEIC, HEIF, and SVG.

## File explorers

The left sidebar follows the saved document's folder by default. Its top
dropdown shows the current folder name. The menu lists one folder name per row
from `/` through the current folder, and selecting any row moves the explorer
to that ancestor. Expand folders lazily, double-click a Markdown file to open
it in the editor, or double-click another file type to open it with its system
application. Use **Choose Folder** in the dropdown or **File > Open Folder**
(`Option-Command-O`) to browse a different root; use the refresh button after
external filesystem changes. The document-and-magnifying-glass button beside
Refresh restores the current document's folder and reveals its file. Hidden
files are omitted, and packages and symbolic links are never traversed.

## Editing modes and formatting

The toolbar's **Rich Text / Markdown / Split** control switches between an
editable rendered document, its exact Markdown source, and both panes side by
side. Split is the default mode. It keeps both editors synchronized, mirrors
scrolling between them, applies formatting to the focused pane, and has a
draggable center divider. Preview appears on the left and raw Markdown on the
right. Carets and selections map between both panes; edits reveal the mapped
selection in each pane while the other view updates and reflows. All modes
preserve the current selection when switching. Markdown that the rendered
editor does not recognize remains visible as literal text rather than being
discarded.

Toolbar icons and the **Markdown** menu provide paragraph and heading levels,
bold, italic, underline (`<u>...</u>`), strikethrough, bulleted, numbered, and
task lists, quotes, links, horizontal rules, and images. The Code menu has
**Inline Code (Single Line)** for backtick spans and
**Fenced Code Block (Multi-Line)** for full-line fenced blocks. Standard
shortcuts include `Command-B`, `Command-I`, `Command-U`, and `Command-K`;
`Option-Command-M` cycles editing modes. Rendered fenced blocks align every
code line to the same leading edge and use one subtly rounded background.

Drag the dotted gripper between the explorer and document to resize both
panes. Double-click the gripper to restore the default pane split.
In Rich Text mode, a second gripper at the preview's right edge resizes the
rendered document width without changing the explorer, reflowing content as
you drag. Double-click it to restore the default preview width.
