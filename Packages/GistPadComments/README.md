# GistPadComments

Foundation-only comment values, web-compatible body markers, thread construction, quote matching and observable conversation state. The editor and Preview share this package without importing authentication or persistence.

```swift
let threads = GistCommentThread.build(from: comments)
let quotes = threads.compactMap(\.quotedPassage)
let matches = CommentQuoteMatcher.matches(quotes: quotes, segments: [source])
```

For Preview, pass the individual eligible rendered text nodes, excluding `pre`, `code` and `svg`. A quote must occur exactly once across all supplied segments. Matches are literal and case-sensitive, with the web's JavaScript ASCII `\b` boundaries and three-UTF-16-unit minimum. They do not normalize Unicode, whitespace or Markdown, join text nodes, choose among repeated occurrences, or discard overlapping threads. Returned `segment`, `start` and `end` are UTF-16 coordinates. Native code can use `range` directly. The four-unit selection minimum is exposed separately for the native edit menu.

`GistCommentBody` hides only the first `>` line and following blank lines, preserving that exact prefix when `replacingText(with:)` edits a body. `quoting(_:text:)` and `replying(to:text:)` produce the web's existing wire format. A multiline selection is stored unchanged, but only its first line is parsed as the quote, exactly as on the web. This is not a source-position mapping.

`GistCommentThread.build(from:)` orders roots and replies newest first, retaining input order for equal creation dates. Reply controls stop at depth two. Deeper imported replies remain visible at that last level, with their original parent marker intact. Deleted parents become roots. Self-references and cycles cannot hide comments or cause unbounded recursion. Duplicate IDs retain the most recently edited version.

Permissions distinguish comment authorship from gist ownership: authors can edit, while authors and the gist owner can delete. GitHub remains the authority for the actual request. Daily Notes and unpublished notes have no gist-comments surface, as enforced by the host, not by quote matching.

## Live conversations

`CommentConversationController` is MainActor-owned. Inject a `CommentConversationRemote` and `CommentConversationStore`, then call `load()` when opening the conversation. `comments == nil` means unknown, not empty. `knownTotal` covers every comment in the gist, including replies, and retains a supplied known count through read failure. No conversation fetch is needed for a decorative badge.

`composer` supplies its captured target, text, durable-save state, problem and enabled states. Targets keep independent drafts for a root, an exact quote with its original filename, a reply ID or an edit ID. New selections never retarget an existing draft. Draft changes save after 250 ms. Await `flushDraft()` on deliberate Close or application departure, and retain an explicit local-save failure when it returns false. The host disables field editing while `canEdit` is false. Merely opening or closing a conversation never posts.

`post()` and confirmed `delete(_:)` refresh before writing. They check current author/owner permissions, reply depth and target existence, and preserve an edit's original hidden prefix. Missing replies never become root comments. Note editability is not a comment permission. A durable attempt record precedes every remote mutation. After an uncertain result, refresh the gist: a new, byte-exact authored match acknowledges a create, while edit/delete reconcile their known IDs. Otherwise preserve the draft and allow another explicit Post. Failed outcome checks block another mutation until `refresh()` succeeds. Server retry deadlines remain enforced.

An edit that reports `commentChanged` keeps its authored text and old snapshot. The explicit `restartEditing(_:)` action adopts the latest loaded comment's snapshot and prefix while retaining the typed text. It does not happen silently when selecting Edit again.

After a user-confirmed gist deletion succeeds on GitHub, call `discardAfterGistDeletion()`. It disables the obsolete controller, cancels draft saving and removes its scoped composer archive. It cannot prepare or autosave that deleted gist's draft again. This is not the policy for an unsuccessful delete or an ordinary comment deletion.

Release 1.1 does not persist thread caches or present an uncertain-post chooser. Network and protected atomic draft-journal adapters live in GistPadSync. The app's `NotebookCommentProvider` scopes controllers to the authenticated account and published gist.

The checked-in compatibility fixtures are grounded in `gistpad.dev/src/features/comments/threads.ts`, including JavaScript's punctuation, Unicode and nonoverlapping-match behavior. Run the normal package gate with `swift test --package-path Packages/GistPadComments`. Network endpoints live in `GistPadSync`, not here.
