# The cross-platform contract

This directory is the answer to a question that had no good answer before it
existed: **if you are writing this editor for a fourth platform, what exactly do
you have to match?**

The three READMEs are product requirements documents, and they are thorough, but
each describes one build. They tell you what the Mac app does, or what the web
app does. None of them tells you what *the editor* does, independently of the
platform it happens to be running on — and none of them is checkable. A new
build could satisfy every sentence in all three and still write documents the
others cannot open.

So this is not more prose. It is the compiled Swift, dumped as data:

| File | What it pins down | Cases |
| --- | --- | --- |
| `formatting.jsonl` | Every formatting command, at every interesting selection, in every corpus document | 8,180 |
| `render-model.json` | What the reading view shows, and where each part of it came from in the source | 13 documents, every span |
| `paths.json` | Workspace-path arithmetic: naming, descendancy, subtree rewriting, collision numbering | 123 |

Regenerate them after changing `MarkdownEditorCore` or `CloudPath`:

```bash
swift run --package-path Shared markdown-contract Contract
```

A test in `MarkdownEditorContractTests` regenerates and compares, so a fixture
that no longer describes the code fails the suite rather than quietly
misleading whoever ports next.

## Why these files exist at all

The web build's README claims it was verified against the compiled Swift by
differential testing: 14,148 formatting cases and 41 documents through the
render model, zero mismatches. That was true. But the harness that ran it was
never committed, so the claim outlived any means of checking it, and nobody
starting a fourth build could repeat it.

These files are that harness's output, committed. A port is correct when it
reproduces them, and you can tell whether it does by running them.

## Offsets are UTF-16 code units

Every `[location, length]` pair in every fixture counts UTF-16 code units, which
is what Swift's `NSString`, JavaScript strings, C# `string`, and Java `String`
all index by. In those languages the numbers can be used directly.

Go, Rust, and Python index differently — bytes, or scalars — and a port in one of
those has to convert at the boundary. That is precisely why the corpus contains
`😀`, a regional-indicator flag, and a four-person family emoji: a port that
treats one visible character as one unit will pass most of the corpus and fail
those, which is the failure you want, early and loudly.

## Reading the formatting fixture

One JSON object per line. The first line is the header, which carries the
corpus; every line after it is a case.

```
{"version":1,"about":"…","offsets":"UTF-16 code units","caseCount":8180,"documents":[{"id":"mixed","text":"# Trip notes\n…"}]}
{"argument":"bold","command":"toggleInline","document":"mixed","replace":[0,0],"selection":[2,4],"selectionAfter":[4,4],"with":"**"}
```

Each case says: take the named document, put the selection at `selection`, run
the command, and you must get the document back with `with` written over the
`replace` range, and the selection at `selectionAfter`.

The edit is stored rather than the whole resulting text because most commands
change a handful of characters in a document that is otherwise identical —
storing the result made the file forty times larger and no clearer.

A runner is about fifteen lines:

```csharp
foreach (var line in File.ReadLines("Contract/formatting.jsonl").Skip(1))
{
    var c = JsonSerializer.Deserialize<Case>(line);
    var source = documents[c.Document];
    var expected = source.Remove(c.Replace[0], c.Replace[1]).Insert(c.Replace[0], c.With);

    var actual = Formatting.Apply(c.Command, c.Argument, source, c.Selection[0], c.Selection[1]);

    Assert.Equal(expected, actual.Text);
    Assert.Equal(c.SelectionAfter[0], actual.SelectionStart);
    Assert.Equal(c.SelectionAfter[1], actual.SelectionLength);
}
```

### The twenty commands

| `command` | `argument` |
| --- | --- |
| `toggleInline` | `bold`, `italic`, `underline`, `strikethrough`, `inlineCode` |
| `applyHeading` | `0`–`6`, where `0` removes the heading |
| `toggleList` | `bulleted`, `numbered`, `task` |
| `toggleQuote` | — |
| `wrapCodeBlock` | — |
| `insertNewline` | — |
| `insertLink` | the destination, `https://example.com` in the fixture |
| `insertHorizontalRule` | — |

`insertNewline` is in the list because pressing Return is a formatting command
in this editor: inside a list it continues the list, and on an empty list item it
ends it. A port that treats Return as plain text insertion passes everything
else and gets lists wrong.

## Reading the render fixture

`render-model.json` holds, for each corpus document, the text the reading view
displays and every style span in it. Each span carries two ranges:

- `rendered` — where it is in the displayed text
- `source` — where it came from in the original Markdown

The second is the half that is easy to skip and impossible to do without. It is
what lets a click in the rendered pane put the caret in the right place in the
source, and what keeps a selection where it was when switching views. A port
that renders correctly but maps ranges wrongly looks finished and is not.

`includesMarkup` says whether the span covers the syntax characters as well as
the content. `isAtomic` marks a span that behaves as one unit for selection —
an image, or a horizontal rule.

## What is not in these files

Some of the contract is not a pure function and cannot be dumped as cases. Those
parts are listed here with the file that defines them, so nothing has to be
reverse-engineered from behaviour.

### The Firestore data model

Documents live at `users/{uid}/nodes/{documentId}`, one flat collection per
account — a subcollection rather than a `uid` field so the security rules are a
path match and cannot be got wrong for a single document.

`documentId` is the workspace path percent-encoded exactly as JavaScript's
`encodeURIComponent` encodes it: everything escaped except
`A–Z a–z 0–9 - _ . ! ~ * ' ( )`. **This is the one that decides whether two
builds can see each other's documents at all.** `paths.json` has cases for it,
including non-ASCII and emoji paths.

Every node document has these fields, and the security rules validate them:

| Field | Type | On | Notes |
| --- | --- | --- | --- |
| `type` | string | all | `folder`, `file`, or `asset` |
| `path` | string | all | Workspace-relative, no leading slash |
| `parent` | string | all | Containing folder; `""` at the root |
| `name` | string | all | Last path component |
| `modified` | number | all | **Milliseconds** since the epoch, as JavaScript's `Date.now()` writes. Read it as a double: Firestore hands back either |
| `text` | string | files | The Markdown itself |
| `hasByteOrderMark` | bool | files | Preserved so a round-trip through the editor does not change the file's bytes |
| `size` | number | files, assets | UTF-8 **bytes**, not characters |
| `storagePath` | string | assets | Object path in Cloud Storage |
| `url` | string | assets | Download URL |
| `contentType` | string | assets | MIME type |

Defined in `Shared/Sources/MarkdownEditorCloud/CloudNode.swift` and
`Web/public/app/cloud/`. A document is refused above 900,000 bytes, below
Firestore's 1 MiB per-document cap.

**Count those 900,000 in UTF-8 bytes, not characters, and enforce it in the
client.** Every port has to, because neither of the two server-side limits
substitutes for it:

- The rule in `firestore.rules` reads `text.size() < 900000`, and the rules
  language has no byte-length function — `size()` on a string counts
  *characters*. Measured against the real engine: 500,000 accented characters
  (1,000,000 UTF-8 bytes) are accepted by the rules.
- Firestore's own limit is a hard 1,048,487 bytes per property, and a write past
  it fails with `400 INVALID_ARGUMENT` — **not** the `403 PERMISSION_DENIED` a
  client can read as "you are signed out". 600,000 accented characters land
  exactly there: inside the character limit, outside the byte cap.

So a client counting characters has a band of documents that pass its own check,
pass the rules, and then fail with an error meaning something else entirely.
Counting UTF-8 bytes at 900,000 is strictly stricter than both and closes it.
Verified by `Web/firebase/run-rules-checks.sh`.

### Where image bytes live

Not in Firestore. A Firestore document is capped at 1 MiB and base64 inflates a
file by about a third, which would cap an inserted image near 700 KB and spend
the same budget the text needs.

Images go to a Cloud Storage bucket at:

```
users/{uid}/{workspace path of the asset}#{milliseconds since epoch}
```

The timestamp keeps a re-uploaded image from being served from a CDN copy of the
previous one at the same object path. The limit is 10 MiB, enforced in the app
and again in `Web/firebase/storage.rules`, where a client cannot talk its way
around it.

**Refuse an image that reaches the limit, not one that exceeds it.** The rule is
`request.resource.size < 10 * 1024 * 1024`, so a file of exactly 10,485,760 bytes
is denied by the server. A port that checks `> limit` accepts that file and then
fails on upload with a bare permission error, which is the one outcome the
client-side check exists to prevent. The web build had this wrong until the
rules were published and it became reachable.

**Every port must cache image bytes on the device.** Firestore's offline
persistence covers Firestore documents and nothing else; Storage objects are
ordinary HTTPS downloads. A port that relies on Firestore's cache alone opens an
offline document with its text intact and every picture broken, which reads to
the person holding the device as damage rather than as being offline. The web
build keeps the bytes in IndexedDB; a native port has a filesystem and should
use it. Three rules make the cache correct on any platform:

* **Key by download URL, not by the image's path in the workspace.** A rename
  moves images, and the download URL moves with them, so a rename needs no cache
  bookkeeping. The URL also carries a token that changes when the bytes behind it
  are replaced, so a replaced image misses instead of serving the old picture:
  the cache can go empty but it cannot go stale.
* **A miss must fall back to the download URL,** never to a missing image. The
  cache is only ever allowed to improve on the uncached behaviour.
* **Adopt what is already on the device before returning the document; do not
  wait on what is not.** A miss only matters with no network, and with no network
  the download fails anyway — so blocking every open on fetching images spends
  something real to buy something hypothetical. Bytes that were just *uploaded*
  are cached from the copy in hand rather than downloaded back.

**Every port must send a real `image/*` content type, derived from the file
extension rather than taken from the platform's file handle.** The Storage rule
accepts only `contentType.matches('image/.*')`, and an upload with no declared
type is stored as `application/octet-stream` and refused. Platforms hand over
untyped files routinely — a drag from some applications, a paste, bytes read
straight off disk — so the type has to be derived. By the time it is needed the
extension has already been checked against the accepted list, so deriving it is
safe. A type the platform *does* declare is kept only when it is itself an
`image/*`. The map is the one below; a port that skips this sees images that
silently fail to add, reported as a bare permission error.

| Extension | Type | | Extension | Type |
| --- | --- | --- | --- | --- |
| `png` | `image/png` | | `bmp` | `image/bmp` |
| `jpg`, `jpeg` | `image/jpeg` | | `webp` | `image/webp` |
| `gif` | `image/gif` | | `svg` | `image/svg+xml` |
| `heic` | `image/heic` | | `tiff`, `tif` | `image/tiff` |
| `heif` | `image/heif` | | | |

A second thing no fixture can express: **if a port caches image URLs by path so
the renderer can resolve them synchronously, the cache must be re-keyed whenever
a path changes.** A document's assets folder is a *sibling*, not a descendant, so
a subtree walk over the renamed path does not reach it and has to be handled
separately.

**The Markdown text never contains a Storage URL.** It keeps the relative
reference every build writes, and the URL is resolved at render time from the
`asset` node. That is what keeps a document portable between builds.

### The assets convention

A document's images live in a sibling folder named after the document's stem
plus `.assets`, so `Trip.md` has `Trip.assets/`. The reference written into the
document is relative and percent-encoded per RFC 3986 — unreserved characters
are `A–Z a–z 0–9 - . _ ~`, everything else escaped:

```markdown
![my shot](Trip.assets/my%20shot.png)
```

A name already taken gets `-2`, `-3`, and so on before the extension, and an
existing file is never overwritten. `paths.json` has the cases. Renaming a
document moves its assets folder with it and rewrites the references inside it;
deleting a document deliberately leaves the assets behind, because the originals
may exist nowhere else.

### How an image carries a size

Markdown has no syntax for image dimensions. Every port must therefore agree on
what to write instead, or a document sized on one platform shows raw HTML on
another.

The rule is: **an image with no size stays Markdown; an image with a size is an
HTML `<img>` tag.** Setting a size converts one to the other, and clearing it
converts back.

```markdown
![my shot](Trip.assets/my%20shot.png)
<img src="Trip.assets/my%20shot.png" alt="my shot" width="300" height="200">
```

This was settled by rendering the candidates through GitHub's own
`POST /markdown`, not by preference:

| Written as | What GitHub does with it |
| --- | --- |
| `<img src="a.png" alt="s" width="300" height="200">` | **Honoured** — both dimensions survive |
| `![s](a.png =300x200)` | Rendered as literal text; **the image is lost** |
| `![s\|300x200](a.png)` | Renders, but the size is ignored and the alt text becomes `s\|300x200` |

Only the first keeps both the picture and the size, so it is the one the
documents use. It is also consistent with the existing use of `<u>` for
underline: reach for HTML exactly where Markdown has no syntax, and nowhere
else.

A port must read a tag more liberally than it writes one, because a person may
have typed it. Attributes come in any order, quoted with `"` or `'` or not at
all, in any case, with or without a self-closing `/`, and a quoted value may
contain `>`. HTML entities are decoded. These are **not** images and stay as
literal text: `<imgx …>` and `<image …>` (a shared prefix is not a match), a tag
with no `src` or an empty one, and — importantly — **a tag with no closing `>`**,
which otherwise swallows the rest of the line. A dimension that is not a
positive whole number, such as `50%`, is reported as absent rather than
rewritten, so hand-written HTML the editor cannot represent in a number field is
still displayed and not silently damaged.

Two rules govern the conversion:

1. **Going back to Markdown percent-encodes the destination.** An HTML attribute
   holds `my file.png` happily; the same text in Markdown is not an image at all.
   The encoding is idempotent, so an already-encoded path is unharmed.
2. **A size is only ever set on a range that is exactly one image reference.**
   If it is not, the text is left untouched. A stale range from a document that
   has since been edited must never corrupt it.

Resizing preserves the aspect ratio, derived from the image's own pixel
dimensions rather than from anything in the document. The dimension the person
edited is kept exactly and the other is derived; the derived one is rounded, but
never to zero, or a very wide, very short image would vanish. When the image has
not loaded there is no shape to preserve, so nothing is derived.

An image may also be referenced by URL instead of being copied into the assets
folder. Nothing is uploaded in that case and the document points at the original
address.

### Drawing an image held at a web address

A browser draws `<img src="https://…">` itself; a native build has to fetch the
bytes. That difference is invisible in every fixture here, so it is written down
instead — the macOS and iOS builds both once drew a placeholder glyph for every
address, and a port that reads only the fixtures would reproduce that.

The rules a native port must follow, all shared between macOS and iOS in
`RemoteImageStore` and worth copying rather than reinventing:

| Rule | Why |
| --- | --- |
| Look up synchronously; download asynchronously | Styling re-runs on every keystroke, so a lookup must be instant. On a miss, draw the placeholder, start one download, and re-style when it lands. |
| `http` and `https` only | A `file:` address would let a document read any file on disk, defeating the containment that keeps an import inside the document's own folder. `data:` is already bytes. |
| Record a failure as a failure | Otherwise a broken address costs one request per keystroke. One attempt per address per launch. |
| Cap the transfer, while streaming | 25 MB. `Content-Length` may be absent, so the ceiling has to be enforced against bytes actually received, and a missing length is not itself grounds to refuse. |
| Require the bytes to decode as an image | A server answering an error page with HTTP 200 is a failure, not a picture. |
| Unescape the destination before parsing the URL | A Markdown `\)` inside an address parses as a different URL if it is read literally. |

Re-styling on arrival must preserve the selection and must not scroll. A cached
image also supplies the natural size, so an address can be resized
proportionally like a local file; before it loads there is no shape to preserve,
which is the same "not loaded" case the sizing rules above already describe.

### Drawing an image kept beside the document

A browser gets this free: `<img src="notes.assets/photo.png">` is decoded once
by the engine and redrawn from its own cache. A native build that rebuilds the
document's attachments on every keystroke does not, and re-reads and re-decodes
every picture on the page per character. Measured on macOS with forty
photo-sized references: 65.7 ms per keystroke against 1.1 ms for the same text
without images — about 15 fps, felt as lag rather than seen as a glitch.

Shared between macOS and iOS in `LocalImageStore`. A port needs four rules:

| Rule | Why |
| --- | --- |
| Decode once and keep it | The whole point. Styling an illustrated document should cost about what styling its prose costs. |
| Key on modification date **and size**, not the path | A picture edited in another app must not go on drawing its old self. Size is in the key because a timestamp is coarse enough that a generated or scripted image can be rewritten inside the same second. A `stat` costs a microsecond against a decode's millisecond, so checking every lookup is worth it. |
| Cost entries by pixel area, and evict | An image is far larger decoded than compressed — a 34 MB photo is roughly 48 MB of pixels — so a count-based limit budgets nothing. This cache evicts, unlike the remote one, because a long illustrated document could otherwise hold more memory than the rest of the app. Eviction only costs a re-read. |
| Give the memory back under pressure | A text editor should hand a hundred megabytes of decoded pictures back to the OS long before the machine swaps. `NSCache` does this by itself; a port hand-rolling a dictionary has to do it deliberately. |

Two traps worth inheriting, both of which produced tests that passed against a
broken cache. Reading a file's modification date and setting it back does **not**
round-trip — the filesystem keeps nanoseconds a `Date` does not reproduce — so a
test that tries to hold the timestamp still while changing the content proves
nothing about the size half of the key; pin both writes to an explicit whole
second instead. And asserting that a cost function returns the right number says
nothing about whether that number ever reaches the cache: size a cache for one
image and add two.

### Reading the paths fixture

`paths.json` is a flat list of calls. Each case names a `function`, its
`input` arguments, and either an `output` or an `error`:

```json
{ "function": "documentId", "input": ["a/b/c.md"], "output": "a%2Fb%2Fc.md" }
{ "function": "documentId", "input": [""], "error": "rootIsNotADocument" }
```

A case with `error` must fail. The string is the Swift error case name; a port
should map it to whatever its own failure looks like, but it must not succeed.
The functions covered are `normalize`, `name`, `parent`, `stem`,
`fileExtension`, `isMarkdown`, `assetsFolderName`, `documentId`, `join`,
`isDescendant`, `nextAvailableName`, and `rewrite` (which re-points a path and
everything under it when a folder moves).

### Sort order

Explorer order is folders first, then natural case-insensitive order, so
`Folder 2` comes before `Folder 10`. Each build spells this with its platform's
own collation — `localizedStandardCompare` in Swift, `Intl.Collator` with
`numeric: true` in JavaScript, `strnatcasecmp` in PHP. On .NET the equivalent is
`StrCmpLogicalW`, or a comparer that splits digit runs and compares them
numerically.

### Themes

Sixteen palettes — eight colours × light and dark — transcribed once from
kirupa.com into `Shared/Sources/MarkdownEditorUI/EditorColorTheme.swift`.

**Do not transcribe them again.** `Web/public/css/themes.css` is *generated* from
that Swift file and is committed, so it is a plain list of resolved hex values
for all sixteen, including the derived ones. Read the colours from there.

One thing that will bite a port: several colours are blends, and `NSColor`'s
blend does not interpolate in sRGB. It converts to Apple's Generic RGB —
different primaries, gamma 1.8 — mixes, and converts back, so black halfway to
white is `0.573`, not `0.5`. A naive sRGB blend is off by up to 46/255. Since
`themes.css` holds the resolved values, a port that reads them avoids the
problem; a port that reimplements the blending must reproduce this.

### Keyboard shortcuts

These are product, not platform courtesy, and a build should have them:

| Shortcut | Command |
| --- | --- |
| `Ctrl/⌘ B` | Bold |
| `Ctrl/⌘ I` | Italic |
| `Ctrl/⌘ U` | Underline |
| `Ctrl/⌘ K` | Insert link |
| `Ctrl/⌘ Alt/⌥ I` | Insert image |
| `Ctrl/⌘ Alt/⌥ M` | Cycle editor view |
| `Ctrl/⌘ Alt/⌥ O` | Open folder |

Plus the platform's own document shortcuts — New, Open, Save, Save As, Close —
using whatever that platform's convention is.

### Keeping the reader's place while re-styling

Every build re-styles by replacing the whole text of a pane, and every build
has lost the reader's scroll position doing it. This is the one rule here that
was written from a bug rather than from a design, so it is worth reading before
a port repeats it.

The failure looks like the document jumping far down the page and snapping back
on a keystroke. Four rules prevent it, and each corresponds to a defect that
actually shipped:

1. **Restore an absolute offset, not a fraction of the travel.** A fraction is
   relative to the document's height, and typing changes the height, so
   restoring a fraction moves the text on almost every keystroke. Fractions are
   only meaningful for syncing *two different* documents, which is a different
   job.
2. **Never publish a position from a pane that has not finished laying out.**
   Partial layout describes the part measured so far, not the document. A pane
   20pt down a 29629pt file reported itself 17% of the way through because only
   114pt existed yet; applying that to the real height threw the other pane
   5198pt down. Report "don't know" rather than a number — which means the
   value must be nullable, since zero is indistinguishable from a reader parked
   at the top.
3. **Lay a pane out fully before applying a position to it.** The receiving
   side needs the same care as the sending side. A pane that has just been
   created has measured only the screenful it shows, and a document 136,017pt
   tall reports the 600pt of its viewport, so a reader 80% through lands at the
   very top.
4. **Reveal the caret last, and only if it is off screen.** Revealing before
   restoring the offset means the restore undoes the reveal. Revealing when the
   caret is already visible moves the page during ordinary typing. A caret
   straddling the edge of the viewport counts as off screen — testing for
   intersection rather than containment leaves it permanently half-hidden.

5. **Publish a selection change only when the writer caused it.** Both panes
   replace their whole text storage to re-style, on every keystroke, and the
   toolkit moves the selection part-way through that before the intended one is
   put back. AppKit announces that intermediate value through the same delegate
   callback it uses for a real caret move, and it is not near the caret: 19,681
   characters away in the case that was measured. Publishing it made the other
   pane reveal a caret the writer had not moved, so a split editor lurched down
   the document and back on every character typed. Suppress selection
   notifications while re-styling and publish the settled selection afterwards.
   UIKit does the same thing on `attributedText` assignment — the iOS build
   guards it — so a port should assume its toolkit does too until it has
   checked.

6. **Catch a pane up when it joins the split, not on every update.** Aligning
   one pane to the other applies a normalized *fraction*, and the two panes
   render the same text at different heights, so the operation is **not
   idempotent** — repeating it drags the idle pane further out of step each
   time. Declarative UI layers make this easy to get wrong: SwiftUI calls
   `updateNSView` for both panes on every keystroke, and the alignment sat in
   the function that call lands in, so 20 keystrokes produced 40 unwanted
   moves. Separate "register this pane" from "this pane is joining the split",
   and owe the catch-up again only when the layout genuinely changes — the view
   mode switches, or a pane leaves and comes back.

   Telling "joining" from "updating again" means holding pane identity, which
   carries its own trap: panes are held weakly because they are deallocated
   without a teardown call, and a freed address gets reused, so a new pane can
   inherit a dead one's identity and be mistaken for one that has already
   caught up. Prune identities to the live panes wherever the weak list is
   compacted. This was measured, not imagined — removing the pruning makes a
   replacement pane land on the dead pane's address and never align.

The arithmetic is shared and testable:
`Shared/Sources/MarkdownEditorUI/EditorScrollGeometry.swift`, with the recorded
numbers in `EditorScrollGeometryTests.swift`. The parts that are not pure —
which are the parts that broke — are asserted against real views by
`macOS/Scripts/check-scroll.swift`, and the coordination between panes by
`macOS/Scripts/check-session.swift`.

A trap that made a first version of those checks worthless: `NSTextView` never
shrinks its frame once grown, so re-styling an already-measured pane cannot
lose the offset and proves nothing. Whatever the platform equivalent is, the
state to test from is a pane that has *not* been measured yet. On UIKit the
shape of the problem is different again — assigning `attributedText` resets
`contentOffset` outright — so a port should establish what its own toolkit does
rather than assume this one transfers.

### What is deliberately per-platform

Not everything is a requirement. These differ between the existing builds on
purpose, and a new build should decide for itself:

- Scroll and selection synchronisation between split panes (macOS has it, iOS
  does not)
- The file explorer (macOS and web have one, iOS does not)
- Where the formatting toolbar sits, and whether it is a toolbar at all
- Drag-and-drop and paste of images
- The welcome window and recent documents

## Properties, not just fixtures

The fixtures say what this implementation produces. They cannot say what *any*
implementation must never do, and a port will hit the second problem first —
usually by measuring characters instead of UTF-16 code units, or by trusting a
selection that arrived from the platform's text control.

These properties are checked in Swift by
`MarkdownFormattingInvariantTests`, `MarkdownRenderModelInvariantTests`,
`RichMarkdownStylerTests` and `MarkdownTextCodecInvariantTests`, over the same
corpus that generates the fixtures. They need no fixture file, so a port can
assert them from day one, before any output matches.

**Formatting.** For every command, over every selection of every corpus
document:

- The returned selection lies inside the returned text.
- It never begins or ends in the middle of a surrogate pair.
- No command returns empty text unless the document was already empty.
- A selection outside the document is clamped, never trapped or crashed on.
- Applying a heading level twice is the same as applying it once.
- Every command works on the empty document.
- Toggling an inline style twice restores the text, where the selection and its
  immediate neighbours contain no marker characters. Outside that, Markdown is
  genuinely ambiguous — see `macOS/README.md` §16.3.

**Render model.** For every corpus document, and for every prefix and every
suffix of one:

- Every span's rendered range lies inside the rendered text, and its source
  range inside the source, with neither splitting a surrogate pair.
- Rendering the same text twice gives the same model.
- `sourceRange(for:)` and `renderedRange(for:)` return ranges inside their
  target string for *any* input, including negative locations and lengths.
- The empty document renders to an empty model with no spans.

Prefixes and suffixes matter more than they look. A finished document has
balanced markup; a document being typed does not, and unterminated fences,
half-written links and lone `*` characters only exist in that state. Every
crash this renderer has had was in one.

**Styling.** The attributed string handed to the text control must be exactly
as long as the model text it came from. The span table is what maps an edit in
the rendered view back into the source, so one character of drift means every
later edit is written to the wrong offset in the file. No attribute run may
extend past the end of the string.

**Reading and writing.** Bytes in, identical bytes out — for every corpus
document, with and without a byte order mark. Line endings are preserved, never
normalised. Malformed UTF-8 is refused rather than repaired: replacing bad
bytes with U+FFFD and then saving overwrites the original with the damage.

## Reading order for a new build

1. This file.
2. `README.md` at the repository root — what the project is, and where storage
   is going.
3. `Contract/paths.json` and `Shared/Sources/MarkdownEditorCloud/CloudPath.swift`
   — small, and everything else rests on it.
4. `Contract/formatting.jsonl` with
   `Shared/Sources/MarkdownEditorCore/MarkdownFormatting.swift` beside it.
5. `Contract/render-model.json` with
   `Shared/Sources/MarkdownEditorCore/MarkdownRenderModel.swift`.
6. `Web/README.md` §11 for the cloud model, and `Web/firebase/` for the rules —
   the web build is the one with a working cloud path, so it is the reference.
7. The README of whichever existing build is closest in shape to the one being
   written.

Port the pure logic first, get the fixtures passing, and only then build the
interface. That is the order the web build was written in, and it is why it
could be verified at all.

## Standing caveats

**Nothing about the Firebase project is outstanding any more.** The rules are
published and the Storage bucket exists: an unauthenticated read, an
unauthenticated write, and both Storage operations all answer `403`, where the
Firestore calls previously answered `200`.

What remains true is that **no build has been exercised end to end against the
real project**, because only Google sign-in is enabled and a token for it cannot
be minted headlessly. Every cloud test on every build runs against an in-memory
double. A port should treat the cloud path as written-and-conformant rather than
proven, and the first real sign-in is the moment to watch for.

**The rules themselves are now an exception to that**, and a port should use the
same escape hatch. `Web/firebase/run-rules-checks.sh` puts 29 checks through
Firebase's own rules engine in the emulators, including both deny-by-default
catch-alls and all three limits from either side of their edge, with thirteen
mutants killed. The Auth emulator issues ID tokens to anybody, so the
Google-only constraint above does not apply there — it never applied to the
emulators, which is worth stating plainly because this document previously
described the rules as unverifiable on the strength of it. They are language-
neutral HTTP checks against a `demo-` project, so a Windows port can run the
same script against the same two files and needs no .NET equivalent.

**So is the data path.** `Web/firebase/run-cloud-checks.sh` runs the web
build's real store against an emulated Firestore. Three results a port should
take as given rather than rediscover:

- The range query in `subtreeOf` **does** over-match. `path >= 'Notes'` and
  `path < 'Notes\uf8ff'` returns `Notes 2/Out.md` and `Notes.md` as well.
  Confirmed by issuing the bare range and looking. Filter on a separator
  afterwards or renaming a folder will drag its similarly named siblings along.
- A batch is **atomic**: one write that breaks the rules refuses the whole
  batch, including the valid writes beside it. The create-before-delete
  ordering depends on that, and it holds.
- A local write reaches its own listener **not at all**, provided the snapshot
  carrying `hasPendingWrites` is skipped. There is no second, confirmed
  snapshot to wait for — a listener without `includeMetadataChanges` is not
  woken merely because a write was acknowledged, since the data did not
  change. A port that skips the pending snapshot and then expects a confirmed
  one will hang waiting for it.

One caveat for whoever runs these: the emulator does **not** enforce
Firestore's 500-write batch limit — it accepted 613 in one batch — so a
functional test cannot catch a chunk size that production would refuse. Assert
the constant directly.

Every point above has since been reproduced by a **second, independent SDK** —
the Swift one, in `Shared/Firebase/run-emulator-checks.sh`. That matters for a
port: these were previously observations about how the JavaScript client
behaves, and two clients agreeing makes them observations about Firestore. The
one place the two builds deliberately differ is the name in the source, not the
name on the wire — Swift's `CloudNode.kind` is stored as `type`, because `type`
is what the rules validate and what the web build writes. A port should expect
to make the same split.

A practical note for a native check: the listener case cannot be tested with
one client. A client is not delivered its own write at all, so the write has to
come from a genuinely separate client instance, not merely a separate store
object sharing one connection.

Re-checked on 6 August 2026, with the commands to repeat the checks, in
[Web/README.md § 11b](../Web/README.md#setup-steps-that-cannot-be-done-from-this-repository).
The console work itself is done.
