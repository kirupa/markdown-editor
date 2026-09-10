# Bundled fonts

The critique rail's own words — the score, the severities, the section
headings, the buttons — are set in the **system sans-serif**, which needs no
bundling. Monomaniac One used to be here for that job and was never actually
called; it has been removed rather than shipped unused.

The critique rail offers a choice of hands and remembers which one is chosen.
Eight are bundled, all under the SIL Open Font License, which permits shipping
them inside an application:

| Face | Copyright |
| --- | --- |
| Architects Daughter | 2010 Kimberly Geswein |
| Caveat | 2014 The Caveat Project Authors |
| Indie Flower | 2010 The Indie Flower Authors |
| Patrick Hand | 2010–2012 Patrick Wagesreiter |
| Shadows Into Light | 2010 Kimberly Geswein |
| Gloria Hallelujah | 2010 Kimberly Geswein |
| Kalam | 2014 Indian Type Foundry |
| Permanent Marker | Font Diner |

Each ships beside its licence text. `make check-critique` asserts that every
bundled face names a file the app actually ships, that every shipped file is
reachable from the picker, and that each one carries its licence — the three
ways this drifts.

The rail also offers whichever handwriting faces macOS already provides
(Bradley Hand, Marker Felt, Noteworthy, Chalkboard), filtered by what actually
resolves: macOS makes several of them optional downloads, and any face can be
switched off in Font Book.

**Permanent Marker** is the exception to the licence note above: it is under the
Apache License 2.0 rather than the OFL — see `PermanentMarker-LICENSE.txt` —
which likewise permits shipping it inside an application.

The fallback hand is **not** bundled. Bradley Hand ships with macOS, and the
rail falls back through Noteworthy, Segoe Marker and Chalkboard if it has been
disabled in Font Book.
