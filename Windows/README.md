# The Windows build

Nothing here yet. This is the brief for the session that writes it.

## Read this first: where to run

**A WinUI 3 app cannot be built on macOS.** The Windows App SDK builds against
the Windows SDK and produces a Windows binary; there is no cross-compilation
path and no way to run the result. Neither `dotnet build` on macOS nor a CI
runner changes that. So:

> **Run that session on a Windows machine**, with Visual Studio 2022 (or the
> Build Tools) plus the ".NET Desktop Development" and "Windows App SDK"
> workloads, and .NET 8 or later.

What *can* be done from anywhere, including macOS, is the half of this
application that is not Windows at all — the Markdown logic, the path
arithmetic, the cloud data model. That is most of the interesting code, it is
already specified as executable fixtures in [`../Contract/`](../Contract/), and
it is the reason this file recommends the split below.

## Is the PRD the source of truth?

Partly, and it is worth being precise about which part, because building from
the wrong document wastes a lot of time.

The three existing READMEs — [root](../README.md), [macOS](../macOS/README.md),
[Web](../Web/README.md) — are genuine product requirements documents, and they
are the source of truth for **what the product is**: what a user can do, what
the storage model is, what is deliberately excluded, and why particular
decisions were made. Read them.

They are **not** sufficient on their own to build a matching implementation,
because each one describes a single build, in terms of that build's platform.
"The Rich Text pane is an `NSTextView` subclass" tells a Windows developer
nothing checkable. And where they do describe behaviour, prose cannot say
whether your version matches — the web build's README once claimed parity with
the Mac build, verified by 14,148 differential test cases, but the harness that
produced that number was never committed, so the claim could not be repeated.

That gap is what [`../Contract/`](../Contract/) closes. It holds the compiled
Swift's actual behaviour dumped as language-neutral fixtures: 8,180 formatting
cases, every render-model span with its source mapping, and 123 path cases.

So, concretely:

| For | Read |
| --- | --- |
| What the product does and why | the three READMEs |
| Exactly what your code must return | `Contract/*.jsonl`, `*.json` |
| The data model shared with the other builds | [`Contract/README.md`](../Contract/README.md) |
| What is genuinely up to you | `Contract/README.md` § "What is deliberately per-platform" |

## The recommended shape

Two projects, and the split is the whole point:

```
Windows/
  MarkdownEditor.Core/          net8.0 class library — no Windows references at all
  MarkdownEditor.Core.Tests/    runs the Contract fixtures
  MarkdownEditor.App/           WinUI 3 — Windows only
```

`MarkdownEditor.Core` holds the Markdown formatting commands, the render model,
path arithmetic, and the cloud node/workspace logic. It targets plain `net8.0`,
references nothing from the Windows App SDK, and therefore **builds and tests on
any machine** — including the one this repository is usually worked on. It is
also the only part with a right answer, so it is the only part that can be
verified, and it should be finished and green before any XAML is written.

This mirrors what the other two builds already do:
`Shared/Sources/MarkdownEditorCore` is dependency-free and shared by macOS and
iOS; `Web/public/app/` keeps its model modules free of DOM access so they run
under node. In both cases that separation is what made the build testable at
all. It is not architecture for its own sake — it is the difference between a
suite that runs in a third of a second and one that needs a UI.

## Suggested order

1. **Paths first.** Port `Shared/Sources/MarkdownEditorCloud/CloudPath.swift`
   and make `Contract/paths.json` pass. It is small, everything else depends on
   it, and `documentId` is the single function that decides whether your build
   and the existing ones can see each other's documents.
2. **Formatting.** Port `MarkdownFormatting.swift` against
   `Contract/formatting.jsonl`. 8,180 cases; expect the astral and CRLF
   documents to find real bugs.
3. **Render model.** Port `MarkdownRenderModel.swift` against
   `Contract/render-model.json`. Do not skip the `source` ranges — the reading
   view is not usable without them.
4. **Cloud logic.** Port `CloudWorkspace.swift` and its stores behind an
   interface, with an in-memory double, exactly as the Swift and JS builds do.
   Read `Contract/README.md` § "The Firestore data model" before writing any
   field names.
5. **Only then, the app.** XAML, the editor control, the toolbar, the file
   explorer.

## Notes for the app half

- **UTF-16 is free here.** Every offset in the fixtures counts UTF-16 code
  units, which is exactly how C# indexes `string`. The numbers transfer
  directly, with no conversion layer. This is the single biggest reason .NET is
  a comfortable target for this port — a Go or Rust port would need a boundary
  conversion everywhere.
- **The editing control is the hard part, as it was on every platform.**
  The macOS build uses `NSTextView` with a custom layout manager; the web build
  uses a `contenteditable` with a diff-and-remap controller. On Windows,
  `RichEditBox` is the closest analogue. Whatever you choose, the invariant that
  matters is the one both existing builds hold to: **the Markdown source is the
  model.** A visual edit is mapped back into a source range and applied there.
  The rendered view is never the thing being edited.
- **Themes are already resolved for you.** Do not transcribe them from
  kirupa.com. `Web/public/css/themes.css` is generated from the Swift theme
  definitions and committed, so it is a flat list of hex values for all sixteen
  palettes — including the blended ones, which are genuinely hard to reproduce
  (see `Contract/README.md`).
- **Firebase** has a .NET path, but it is not the same shape as the Apple or JS
  SDKs. `FirebaseAdmin` is server-side and must not ship in a desktop app —
  it holds credentials that trust the client completely. For a client app the
  realistic options are the Firestore REST API with a user ID token, or
  `Google.Cloud.Firestore` with care taken over authentication. Expect this to
  be the least pleasant part, and note that the existing builds' cloud paths are
  themselves unverified end to end (below).

## Before you start: the Firebase project is ready now

Both things previously listed here as broken are fixed. The security rules are
published and the Storage bucket exists, so the cloud path is reachable for the
first time. Commands to re-check are in
[Web/README.md § 11b](../Web/README.md#setup-steps-that-cannot-be-done-from-this-repository).

What is still true is that **no build has been exercised end to end against the
real project** — only Google sign-in is enabled, and a token for it cannot be
minted from a script, so every cloud test on every build runs against an
in-memory double. Treat the cloud path as written-and-conformant rather than
proven.

Two things to carry over that no fixture can express, both learned by publishing
the rules against code that was already written and already tested:

- An image upload must send a content type **derived from the file's extension**,
  not taken from the platform's file handle. The Storage rule accepts only
  `image/*`, and an untyped upload is stored as `application/octet-stream` and
  refused.
- Refuse an image that **reaches** the 10 MiB limit, not one that exceeds it. The
  rule is `size < 10 * 1024 * 1024`. The web build checked `>` and so accepted a
  file of exactly 10,485,760 bytes that the server then denied.

A third, learned by building offline support rather than by publishing rules:

- **Cache image bytes yourself.** Firestore's offline persistence covers
  Firestore documents and nothing else; Storage objects are ordinary HTTPS
  downloads. A port that leans on Firestore's cache alone opens an offline
  document with its text intact and every picture broken, which reads as damage
  rather than as being offline. Key the cache by *download URL*, not by the
  image's path — a rename then needs no bookkeeping, and a replaced image misses
  instead of serving the picture it replaced. A miss must fall back to the
  download URL, never to a missing image.

- **A size on an image is HTML, not Markdown.** `![alt](a.png =300x200)` is
  rendered by GitHub as literal text with the image lost entirely, so an image
  that carries a width or a height is written as
  `<img src="…" alt="…" width="300">` and one that does not stays
  `![alt](a.png)`. Setting a size converts one to the other and clearing it
  converts back. Parse liberally (any attribute order, any quoting, entities
  decoded) and write strictly. Two rules cost the Swift and JS ports real time
  and are both covered by fixtures: the Markdown form must percent-encode its
  destination, and an unterminated `<img …` is *not* a tag — treat it as text,
  or `Check <img src="a.png" in the docs` is swallowed to end of line.

All of these are specified in
[Contract/README.md](../Contract/README.md#the-assets-convention). It is worth
mirroring the web build's approach of making the test double enforce the rules,
so a write the server would reject cannot pass the suite.

## Validating the port

```powershell
dotnet test Windows/MarkdownEditor.Core.Tests
```

That should run every fixture in `Contract/`. If it does, the shared half of the
Windows build provably matches the Mac build, which is a stronger claim than any
of the other builds could make about each other until now.

Regenerate the fixtures only from a machine with Swift, and only deliberately:

```bash
swift run --package-path Shared markdown-contract Contract
```

A fixture change means behaviour changed. If a Windows session finds a fixture
wrong — which is possible; they record what the Swift does, and the Swift can be
wrong — fix the Swift, regenerate, and say so in the commit. Do not edit the
fixtures by hand.
