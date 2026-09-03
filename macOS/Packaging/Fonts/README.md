# Bundled fonts

**Monomaniac One** (`MonomaniacOne-Regular.ttf`), used for the labels in the
critique rail — the score, the severities, the section headings. Condensed and
technical, so it sits against the handwriting rather than competing with it.

Copyright 2020 The Monomaniac Project Authors, licensed under the SIL Open Font
License 1.1 — see `MonomaniacOne-OFL.txt`. The OFL permits bundling in an
application, which is why this one can ship where a system font could not be
relied on: it is not installed on macOS by default.

The critique rail offers three hands and remembers which one is chosen —
**Architects Daughter** (`ArchitectsDaughter-Regular.ttf`, copyright 2010
Kimberly Geswein), **Caveat** (`Caveat-Regular.ttf`, copyright 2014 The Caveat
Project Authors), both under the SIL Open Font License 1.1, and **Permanent
Marker** below. All three are bundled, so the choice never depends on what
happens to be installed.

They are three tones of voice for the same comment: a drafting hand, a pen and a
marker. Architects Daughter is the default — Permanent Marker is a chisel tip,
and at a paragraph's length it is a wall of heavy strokes.

Sized against x-height rather than cap height, so the three land at the same
*read* size. They disagree about capitals far more than about lowercase:
x-heights of 0.43, 0.40 and 0.61 against cap heights of 0.66, 0.61 and 0.74.
Almost every word here is lowercase, so matching the capitals would set the text
people actually read as much as a fifth too small. `check-critique` asserts the
three stay within 10% of each other.

None of them has a bold. Asking `NSFontManager` to embolden a single-weight face
returns it unchanged, so emphasis here is size, not weight.

**Permanent Marker** (`PermanentMarker-Regular.ttf`), the third choice and the
first fallback. Copyright the Permanent Marker Project Authors, under the Apache
License 2.0 — see `PermanentMarker-LICENSE.txt`. Bundled for the same reason:
macOS does not ship it.

The fallback hand is **not** bundled. Bradley Hand ships with macOS, and the
rail falls back through Noteworthy, Segoe Marker and Chalkboard if it has been
disabled in Font Book.
