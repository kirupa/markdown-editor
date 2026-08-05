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

### What is deliberately per-platform

Not everything is a requirement. These differ between the existing builds on
purpose, and a new build should decide for itself:

- Scroll and selection synchronisation between split panes (macOS has it, iOS
  does not)
- The file explorer (macOS and web have one, iOS does not)
- Where the formatting toolbar sits, and whether it is a toolbar at all
- Drag-and-drop and paste of images
- The welcome window and recent documents

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

Two things about the Firebase project are outstanding and block any end-to-end
check of the cloud path, on every build including the ones that already have one:

- **The Cloud Storage bucket does not exist.** No image in cloud mode can be
  uploaded or fetched, anywhere, until it is created.
- **The Firestore security rules are unpublished.** The database is readable and
  writable by anyone with the API key, which is public by design.

Both were re-checked on 5 August 2026, with the commands to repeat the checks, in
[Web/README.md § 11b](../Web/README.md#setup-steps-that-cannot-be-done-from-this-repository).
Neither can be done from this repository; both are console work.
