# GistPadComments

Foundation-only comment values, web-compatible body markers, thread construction and quote matching. The editor and Preview share this package without importing authentication or persistence.

```swift
let threads = GistCommentThread.build(from: comments)
let quotes = threads.compactMap(\.quotedPassage)
let matches = CommentQuoteMatcher.matches(quotes: quotes, segments: [source])
```

For Preview, pass the individual eligible rendered text nodes, excluding `pre`, `code` and `svg`. A quote must occur exactly once across all supplied segments. Matches are literal and case-sensitive, with the web's JavaScript ASCII `\b` boundaries and three-UTF-16-unit minimum. They do not normalize Unicode, whitespace or Markdown, join text nodes, choose among repeated occurrences, or discard overlapping threads. Returned `segment`, `start` and `end` are UTF-16 coordinates. Native code can use `range` directly. The four-unit selection minimum is exposed separately for the native edit menu.

`GistCommentBody` hides only the first `>` line and following blank lines, preserving that exact prefix when `replacingText(with:)` edits a body. `quoting(_:text:)` and `replying(to:text:)` produce the web's existing wire format. A multiline selection is stored unchanged, but only its first line is parsed as the quote, exactly as on the web. This is not a source-position mapping.

`GistCommentThread.build(from:)` orders roots and replies newest first, retaining input order for equal creation dates. Reply controls stop at depth two. Deeper imported replies remain visible at that last level, with their original parent marker intact. Deleted parents become roots. Self-references and cycles cannot hide comments or cause unbounded recursion. Duplicate IDs retain the most recently edited version.

Permissions distinguish comment authorship from gist ownership: authors can edit, while authors and the gist owner can delete. GitHub remains the authority for the actual request. Daily Notes and unpublished notes have no gist-comments surface, as enforced by the host, not by quote matching.

The checked-in compatibility fixtures are grounded in `gistpad.dev/src/features/comments/threads.ts`, including JavaScript's punctuation, Unicode and nonoverlapping-match behavior. Run the normal package gate with `swift test --package-path Packages/GistPadComments`. Network endpoints live in `GistPadSync`, not here.
