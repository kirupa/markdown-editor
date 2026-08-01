# Markdown Editor

A dependency-free native macOS editor for UTF-8 `.md` and `.markdown` files.
It uses SwiftUI's document lifecycle for standard File menu behavior and an
AppKit text view for precise source editing and cursor-aware insertion.

## Build and run

Requires macOS 13 or newer and a current Apple Swift toolchain.

```bash
cd macOS/MarkdownEditor
make app
open "build/Markdown Editor.app"
```

`make app` creates an ad-hoc-signed application at
`build/Markdown Editor.app`. Use `make run` to build and open it in one step,
and `make test` to run the focused document and image-import tests.

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
