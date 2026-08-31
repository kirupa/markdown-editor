# Bundled fonts

**Monomaniac One** (`MonomaniacOne-Regular.ttf`), used for the labels in the
critique rail — the score, the severities, the section headings. Condensed and
technical, so it sits against the handwriting rather than competing with it.

Copyright 2020 The Monomaniac Project Authors, licensed under the SIL Open Font
License 1.1 — see `MonomaniacOne-OFL.txt`. The OFL permits bundling in an
application, which is why this one can ship where a system font could not be
relied on: it is not installed on macOS by default.

**Permanent Marker** (`PermanentMarker-Regular.ttf`), the hand the feedback is
written in. Copyright the Permanent Marker Project Authors, under the Apache
License 2.0 — see `PermanentMarker-LICENSE.txt`. Bundled for the same reason:
macOS does not ship it.

It runs large for its point size — noticeably larger than Bradley Hand at the
same number — so the rail sets it a couple of points smaller to land at the same
optical size. Getting that wrong makes the notes take half again as many lines.

The fallback hand is **not** bundled. Bradley Hand ships with macOS, and the
rail falls back through Noteworthy, Segoe Marker and Chalkboard if it has been
disabled in Font Book.
