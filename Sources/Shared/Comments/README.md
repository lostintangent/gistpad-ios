# Comments

Gist comments, shaped like the comments panel on gistpad.dev. The package uses only Foundation, so the editor, Preview, Interface and Sync share it without accounts or storage.

```swift
let threads = GistCommentThread.build(from: comments)
let quotes = threads.compactMap(\.quotedPassage)
let highlights = CommentQuoteMatcher.highlights(quotes: quotes, segments: [source])
```

- `GistComment` is GitHub's comment value. `canEdit(as:)` allows the author. `canDelete(as:gistOwnerID:)` allows the author and the gist owner.
- `GistCommentBody` splits off the hidden prefix: a first line that starts with `>` and the blank lines after it. `> [comment:ID]` makes the comment a reply. Any other `>` line is a quote. `quoting(_:text:)` and `replying(to:text:)` write the web's format. `replacingText(with:)` keeps the prefix when a comment is edited.
- `GistCommentThread.build(from:)` sorts newest first and keeps input order for ties. A reply whose parent is missing becomes its own thread. `canReply` stops at depth 2.
- `CommentQuoteMatcher.highlights(quotes:segments:)` links a quote of at least 3 UTF-16 units that appears exactly once, as whole ASCII words, across all segments. It returns UTF-16 ranges per segment. Overlapping quotes split into pieces that list every comment ID. The editor passes the source as one segment. Preview passes each rendered text node outside `pre`, `code` and `svg`. `isEligibleSelection(_:)` needs 4 units before a selection can become a quote.
- `CommentHighlightConfiguration` carries the quotes, the selected comment and the inline toggle to the editor and Preview.
- `CommentsModel` is the open gist's `@MainActor` `@Observable` conversation. It loads through a `CommentsRemote`, which `GitHubClient` implements. `comments` is nil until the first load succeeds. One in-memory `draft` has a `Target`: root, quote, reply or edit. Editing a comment borrows the composer, and the unsent draft returns when the edit ends. A failed load, post, edit or delete sets `failure` and keeps the draft.

The app's `CommentsPresentation` creates one `CommentsModel` per signed-in account and published gist. Daily notes and recovery files have no comments.

`Tests/Shared/CommentsTests/Fixtures/WebCompatibility.json` pins body parsing and quote matching to `gistpad.dev/src/features/comments/threads.ts`. Run `swift test --filter CommentsTests`.
