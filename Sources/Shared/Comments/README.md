# Comments

Gist comments, shaped like the comments panel on gistpad.dev. The package uses only Foundation, so the editor, Preview, Store, Model and the app share it without accounts or storage.

```swift
let quotes = model.threads.compactMap(\.quotedPassage)
let matches = quotes.matches(in: [source])
```

- `GistComment` is GitHub's comment value. `canEdit(as:)` allows the author. `canDelete(as:gistOwnerID:)` allows the author and the gist owner.
- `parsedBody` splits off the hidden prefix: a first line that starts with `>` and the blank lines after it. `> [comment:ID]` makes the comment a reply. Any other `>` line is a quote. `GistCommentBody(quoting:text:)` and `GistCommentBody(replyingTo:text:)` write the web's format into `markdown`, the body GitHub stores, and an edit keeps the prefix.
- `GistCommentThread.build(from:)` sorts threads newest first and keeps input order for ties. A reply whose parent is missing becomes its own thread. `canReply` stops at depth 2.
- `matches(in:)` on `[CommentQuote]` links a quote of at least 3 UTF-16 units that appears exactly once, as whole ASCII words, across all segments. Each `CommentQuote.Match` is a UTF-16 span in one segment. Overlapping quotes split into pieces that list every thread ID. The editor passes the source as one segment. Preview passes each rendered text node outside `pre`, `code` and `svg`. `CommentQuote.isQuotable(_:)` needs 4 units before a selection can become a quote.
- `DocumentComments` is what a document shows of its comments: the quotes, the selected thread and whether every passage shows or only the selected one. Preview takes it beside the document, and its own actions report a tapped passage, a new quote and the threads it matched. A document without one has no comments.
- `CommentAnnotations` carries the same to the editor, with its actions as closures, until the editor takes `DocumentComments` too.

Model's `CommentsModel` is the open gist's conversation, built from these values. The app's `CommentsState` creates one per signed-in account and published gist, gives the editor and Preview each file's comments and hears their taps, quotes and matches, and hosts the inspector with its conversation and composer. Daily notes, unpublished notes and notes deleted on GitHub have no comments.

`Tests/Shared/CommentsTests/Fixtures/WebCompatibility.json` pins body parsing and quote matching to `gistpad.dev/src/features/comments/threads.ts`. Run `swift test --filter CommentsTests`.
