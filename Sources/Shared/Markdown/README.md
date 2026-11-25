# Markdown

A note's Markdown, read once and changed through edits. The module uses only Foundation, so
the editor, Preview, Intelligence, Platform and Store share one reading of the same text.

```text
MarkdownDocument                  a note's source, read once
  text  contentStart  body        the source, where the body starts, and the body
  range                           the whole text
  spans  spans(in:)               the constructs to style, for the note or some lines
  restyledRange(from:edited:)     the lines an edit's styling can reach
  blocks                          headings, paragraphs, list items, table rows and code
  excerpt                         the prose on one line, for a snippet
  taskMarkers                     every task box
  protectedRanges(in:)            front matter, fenced and inline code
  edit(…) -> MarkdownEdit         every change, made from this document

MarkdownEdit                      one change to that document
  document  range  replacement    what it changes and to what
  selection                       the selection after it, or nil to keep the caret
  result                          the document's text with the change made
  Failure                         unsettled, changed or invalidLink, each a sentence
```

- Front matter and fenced code are **literal**. Markdown inside them never counts, so no span,
  block, task or edit reaches inside. Front matter opens on line 0 with `---` and closes at the
  next `---` line. A fence closes at a line of the same character, at least as long, and an
  unclosed one runs to the end of the note.
- Everything else is prose, in runs of nonblank lines. Inline code can span lines inside a run.
- Offsets are UTF-16, like `NSString`, TextKit and the Preview bridge.
- `==` compares exact code units. Swift's `String` equality is canonical, so `"cafe\u{301}"`
  equals `"caf\u{e9}"` there and not here.

## Edits

Every change is a `MarkdownEdit` made by a method on the document it changes:

| Group | Methods |
|---|---|
| Typing | `edit(typing:over:)` continues lists on Return, pairs `()`, `[]` and `{}`, and links a URL pasted over a selection. It returns nil for ordinary input, so the editor types natively. `edit(indenting:)` and `edit(outdenting:)` move list items. |
| Formatting | `edit(bolding:)`, `italicizing`, `coding`, `fencing`, `heading:over:`, `bulleting`, `numbering`, `checklisting`, `quoting` and `edit(linking:to:label:)`, which throws `invalidLink`. Each toggles, so running it again removes it. |
| Tasks | `edit(togglingTaskAt:)` checks or unchecks the box that starts exactly there, and returns nil anywhere else. |
| Any change | `edit(replacing:with:selection:)`, for text that comes from elsewhere, like GitHub, an image upload or Intelligence. |

`MarkdownEditor.apply(_:)` lands an edit only while it shows the edit's document, and throws
`.changed` otherwise. That's the whole staleness check: an edit can't apply to text it wasn't
made from, so it carries no expected text or generation. Mac tests apply edits to text with
`result`.

Run `swift test --filter MarkdownTests`.
