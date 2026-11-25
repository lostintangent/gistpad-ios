# Markdown

A note's Markdown, read once and changed through edits. The module uses only Foundation, so
the editor, Preview, Intelligence, Platform and Store share one reading of the same text. It's
the note's state, not its input or look: what a keystroke means, highlighting and Writing Tools'
protected ranges are the editor's, in Editor.

```text
MarkdownDocument                  a note's source, read once
  text  contentStart  body        the source, where the body starts, and the body
  range                           the whole text
  literals  literals(touching:)   front matter and fenced code, in whole lines
  proseRuns  proseRuns(touching:) the runs of nonblank lines outside them
  inlineCode(in:)                 a prose run's code spans
  isLiteral(_:)  isProtected(_:)  whether a range touches a literal, or inline code too
  blocks  blocks(in:)             headings, paragraphs, list items, table rows and code
  listItem(at:) -> ListItem       the list item on a line: prefix, marker, number and box
  quoteMarker(at:)                the marker that quotes a line
  headingMarker(at:)              the marker that makes a line a heading
  excerpt                         the prose on one line, for a snippet
  taskMarkers                     every task box
  edit(…) -> MarkdownEdit         every change, made from this document

MarkdownEdit                      one change to that document
  document  range  replacement    what it changes and to what
  selection                       the selection after it, or nil to keep the caret
  result                          the document's text with the change made
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
| Lists | `edit(continuingListAt:with:)` starts the next item after a selection in a list item, numbered and boxed like it, and renumbers the siblings below. `edit(indenting:)` and `edit(outdenting:)` nest and lift items, renumbering both lists. |
| Formatting | `edit(bolding:)`, `italicizing`, `coding`, `fencing`, `heading:over:`, `bulleting`, `numbering`, `checklisting`, `quoting` and `edit(linking:to:label:)`, which returns nil unless the destination is a complete web, email or phone link. Each toggles, so running it again removes it. |
| Tasks | `edit(togglingTaskAt:)` checks or unchecks the box that starts exactly there, and returns nil anywhere else. |
| Any change | `edit(replacing:with:selection:)`, for text that comes from elsewhere, like GitHub, an image upload or Intelligence. |

`MarkdownEditor.apply(_:)` lands an edit only while it shows the edit's document, and throws
`.changed` otherwise. That's the whole staleness check: an edit can't apply to text it wasn't
made from, so it carries no expected text or generation. Mac tests apply edits to text with
`result`.

Run `swift test --filter MarkdownTests`.
