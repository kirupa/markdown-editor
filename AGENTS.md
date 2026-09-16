# Working on this repository

Notes for anyone — person or agent — changing this code. The product itself is
specified in [`README.md`](README.md) and the per-build PRDs it links to; this
file is only the things that are easy to get wrong and cheap to state.

## Running the macOS app

```bash
cd macOS && make run           # builds build/KONVO.app and opens it
cd macOS && make test          # the shared package's unit tests
cd macOS && make check-window  # a real document window, measured
```

`make run` is how a change to the window, the document column or the critique
rail gets looked at. `make check-window` is how it gets asserted: it opens the
real editor in a real window and reads the frame back, so "the rail fits" is a
check rather than something somebody has to remember to eyeball.

## KONVO opens wide enough for the rail

**A document window must contain the document column *and* the critique rail.
A window that opens with the rail clipped at its trailing edge is a bug report,
not a finished change.**

The rail is presented on every newly opened document — `CritiqueModel` starts
undismissed — so this is the ordinary case, not an edge one. It is a fixed
width, `Layout.railWidth` in `macOS/Sources/MarkdownEditor/MarkdownEditorView.swift`,
currently 356 points. The window must hold that *plus* the column beside it.

Two functions answer the width questions, both in
`Shared/Sources/MarkdownEditorUI/EditorPaneGeometry.swift`, both pure and both
covered by `Shared/Tests/MarkdownEditorUITests/EditorPaneGeometryTests.swift`:

- `idealContentWidth(columnWidth:railWidth:railIsOpen:)` — how wide the window
  needs to be. `WindowChrome` sizes a new window to it and zooms to it.
- `minimumContentWidth(documentMinimum:columnMinimum:railWidth:railIsOpen:screenWidth:)`
  — how narrow it may be dragged before the rail would be clipped again.

Do not re-derive either by hand in a view. They are in one place so that
"does the rail fit" is a test rather than a thing somebody has to remember,
and so a screen too small for both degrades in one known way instead of three
invented ones.

### Why the rule is written down

The code makes it true when a window opens, and `make check-window` keeps it
true. What neither covers is the moment somebody looks at a window restored
from an old saved frame, or reads a screenshot taken on a machine set up
differently. So when you verify by eye: look at the rail's body text and its
**Run critique** button, not just its header. The header was visible in the
screenshot that reported this bug; everything under it was outside the window.

`screencapture -l` and `-R` both fail behind a lock screen while a full-screen
capture still succeeds, so a locked machine looks like a broken check rather
than a failing one. `MDE_WINDOW_PNG=/tmp/window.png make check-window` draws
the window's own content instead, and works either way.

See §10a (I-218 to I-223) and §16.9 of [`macOS/README.md`](macOS/README.md) for
the full requirements and what each decision was weighed against.

## House style for comments

Comments here explain *why*, usually by naming what was measured and what the
earlier wrong version did. A comment that restates the code is noise; a
comment recording the reason a non-obvious choice was made is the point. Match
the surrounding register rather than introducing a new one.
