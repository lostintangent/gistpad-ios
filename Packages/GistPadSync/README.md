# GistPadSync

Swift 6 actors and Sendable values for the native app's account, Gists, preferences and durable drafts. No UI or editor ownership lives here. The only external product is Supabase's `Auth`, pinned in `Package.swift` and `Package.resolved`.

## Account and reads

```swift
let accounts = try AccountStore(publishableKey: configuredPublicKey)
let account = try await accounts.signIn()
let client = await accounts.githubClient(accountID: account.id)
let library = try await client.listGists()
let gist = try await client.gist(id: selectedGistID)
let text = try await client.content(gist: gist, filename: selectedFilename)
```

`cachedAccount()` restores without requiring the network. `refreshAccount()` fetches current Supabase metadata. `signIn()` uses the SDK's `ASWebAuthenticationSession` with PKCE, GitHub's `gist` scope and `gistpad://auth-callback`. The launch-flow overload supports injected presentation and fake exchanges. The same callback must be allowed in the Supabase dashboard.

Supabase session/PKCE data and the separately retained, account-scoped GitHub provider token use Keychain, accessible only while unlocked on this device. Supabase refresh responses can omit the provider token. Storage failures propagate instead of being mistaken for sign-out. SDK logging is disabled because callback URLs and HTTP details may contain credentials. Pass only a publishable/legacy anon project key, never a service-role key.

Create a new client for each account. Its credential provider rejects an account switch or sign-out. Clear app-visible document and library references when switching accounts. `AccountSnapshot.githubUserID` is available when Supabase supplies GitHub identity metadata. If absent, fetch `client.authenticatedUser().id` before creating an editable draft. **Never use a selected foreign gist's owner ID as the current account's GitHub ID.**

The client paginates, applies the web's different owned/starred Markdown filters. It preserves archive/daily-note markers, exact source bytes and the U+2064 empty-file sentinel. Secret gists are the create default. Updates are targeted file dictionaries, including rename and deletion. Truncated file content uses an unauthenticated HTTPS raw URL on `gist.githubusercontent.com`. A truncated overall file list is explicitly unsupported, never treated as complete. Production sessions reject redirects and never persist note responses to the URL cache.

## Gist comments

`GitHubClient` is the Comments sheet's `CommentsRemote`. `listComments(gistID:)` fetches every page without applying the Library's Markdown-gist filter. `createComment(gistID:body:)`, `updateComment(gistID:commentID:body:)` and `deleteComment(gistID:commentID:)` use the [GitHub gist-comments API](https://docs.github.com/en/rest/gists/comments?apiVersion=2026-03-10) with the active account's credentials and typed errors. A failed read throws instead of becoming an empty conversation. POST is never retried automatically.

Bodies remain exact Markdown, including hidden quote/reply prefixes. Use the Foundation-only `GistPadComments` models and `GistCommentBody.replacingText(with:)` to edit only the visible body. Authors can edit, while authors and the gist owner can delete. Do not infer commenting permission from source editability, automatically publish on autosave, or silently turn a reply to a missing parent into a new root.

`Gist.commentCount` decodes GitHub's `comments` total, including replies. Missing counts remain `nil`, distinct from a known zero and compatible with older durable caches. `withCommentCount(_:)` copies only that total, preserving all other metadata and source bytes. Hosts omit GitHub comments on Daily Notes and before a gist is published.

## Preferences

```swift
let updated = try await accounts.update(
    .setTag(gistID: gist.id, tagID: existingTagID, included: true),
    accountID: account.id
)
```

Operations include `setPinned`, `setTag`, `upsertTag`, `deleteTag` and `setBoolean`. They fetch current metadata before applying, send only changed top-level fields, and preserve unknown nested tag fields. Malformed existing shapes throw rather than being replaced. Account-changing actions and preference mutations cannot overlap. This minimizes web/native collisions, but Supabase user metadata does not provide atomic compare-and-swap.

## Durable editing and publication

```swift
let store = try DraftStore.open()
let draft = try await store.draft(
    accountID: account.id, githubUserID: verifiedGitHubUserID,
    gistID: gist.id, filename: selectedFilename,
    description: gist.displayDescription, content: text, revision: gist.revision
)
// Restore draft.text and draft.generation before starting this document session.
let durable = try await store.persist(
    id: draft.id, accountID: account.id, text: sessionText, generation: sessionGeneration
)
let sync = DraftPublisher(client: client, store: store)
let result = try await sync.publish(id: durable.id, accountID: account.id)
```

Use one store for the app and one publisher for the active account, shared across scenes. Replace the publisher when switching accounts. `draft` returns an existing account/file draft instead of overwriting it with a network response. Generation must increase for every content edit, including undo. SwiftData's automatic saving and CloudKit are disabled. Every successful persistence operation explicitly commits before returning. Never display "Saved on this iPhone" before `persist` succeeds.

On reopen, capture the stored generation **before** requesting fresh remote content, then call `refreshCleanDraft(id:accountID:expectedGeneration:content:revision:)`. It updates only an unchanged clean baseline with no uncertain write. Its result explicitly reports refreshed, unchanged or preserved local changes. A newer generation rejects a stale response. Restore that snapshot into an inactive/new document session, never an actively composing editor.

The publisher serializes publication, freshly reads the remote file, validates ownership/completeness, and persists the attempted content and generation before sending. Acknowledging one generation never clears newer local typing. The draft keeps the user's text until GitHub acknowledges that generation. On restart, an interrupted operation becomes uncertain rather than remaining labelled "Saving".

`PublishState` distinguishes local durability, an in-flight generation, GitHub acknowledgement, reconnect, typed failures and conflicts. A network failure is `.failed(.network)` and retries on the next publish. A failure is persisted and thrown. The UI should reload the snapshot to show its state. A `404` retains the draft. A `403` is not sign-out. Rate-limit reset and `Retry-After` deadlines are honored.

The document session owns the web's five-second autosave delay and account/input eligibility. The publisher only publishes accepted durable generations. Disabling autosave or changing accounts cancels the session's pending request. Leaving a note publishes when autosave is enabled. Leaving the app always attempts publication. Folding itself never requests publication. Pending AI proposals, marked text and temporary Writing Tools edits are not accepted draft generations.

## Conflicts and uncertain writes

`SaveState.conflict` stores the base, local text, remote text, expected generation and remote revision. The sync layer does **not** change active editor text. The document session applies the chosen text as one undoable edit, then calls `resolveConflict(id:accountID:expectedGeneration:text:generation:)`. Keeping byte-identical current source may retain its generation, updating only the baseline without manufacturing an edit or Undo entry. Any byte change still requires a newer generation. A missing remote file also stays a conflict until the user resolves it. There is no automatic or suggested merge. Stale resolutions are rejected.

Typing and Undo retain the inspected remote conflict while updating its local generation. For an explicit refresh of the review, supply freshly verified complete remote content to `refreshConflict(id:accountID:expectedGeneration:expectedConflict:remote:revision:)`. It checks the inspected snapshot byte-for-byte and replaces only the remote review values. It neither resolves nor publishes, and nil remote means a verified missing file, not an unsuccessful read.

After a timed-out PATCH, the next publication reads remote content before any repeat write. If it matches the attempted generation, that generation is acknowledged without another PATCH. A timed-out POST is never automatically retried, including after relaunch. The draft stays `creationUncertain`, and publishing it again never creates another gist. The user keeps, exports or discards it rather than the app guessing that creation failed.

GitHub Gist PATCH has no documented conditional-write precondition. A fresh read before publishing reduces risk but cannot close the race with simultaneous web writes. Do not describe this as atomic collaborative editing.

Drafts remain account-isolated across sign-out. The account service does not delete local drafts.

After an acknowledged remote rename, `updateDraftMetadata(id:accountID:expectedFilename:filename:description:)` retargets the same draft without changing source, generation, baseline or state. Filename collisions, stale metadata and unresolved publication attempts are explicit errors. Serialize remote metadata mutations with publication and flush the active session first. This operation does not rename anything on GitHub.

After the user confirms deletion and GitHub acknowledges it, `removeDraftsForDeletedGist(gistID:accountID:)` permanently removes every draft for that account/gist, including unsynced text and publication attempts. It also removes the gist and its content from the durable library cache. Other accounts and gists remain unchanged. No copy of the deleted text is retained after this explicit deletion.

`discardLocalCopy` removes one explicitly confirmed local draft, either a recovery draft or a never-published draft (no gist ID and no attempted publication), together with its linked history, without a GitHub mutation. Its generation/account checks reject stale confirmations. A draft whose creation was attempted (`attemptedGeneration` set) throws `ambiguousCreation`; once it is `.failed(.creationUncertain)`, resolve it with `discardUncertainCreation` or `confirmNewCreation`. The `onlyIfClean` form additionally requires byte-identical text/base and no unresolved publication attempt. The host uses it only after a successful full list and an authoritative gist 404. Draft edit timestamps change only with actual local text or metadata edits, not reads, publishing or refreshes. The optional stored timestamp migrates existing drafts without fabricating a historical date.

An acknowledged publication updates the cached owned gist, details and file content in the same store commit as its draft baseline. This makes newly created gists immediately available to Library actions even when a subsequent metadata GET is offline.

The app adopts that acknowledged metadata without another GET. A confirmed Library deletion waits for an in-flight publication on the same retained document before taking its destructive lock, including the brief handoff where the durable draft knows the new gist ID before the session does. Autosave and departure publication use the same path as an explicit Save.

`discardBlankDraft(id:accountID:expectedGeneration:)` quietly removes an unbound, locally saved draft with an empty description and whitespace-only source. It also accepts an untouched, generation-zero default daily date heading with no remote-file baseline, including a new day bound to an existing daily gist. Typed daily content, custom templates and published files are not blank. Neither case may have publication attempts. The store rechecks the generation and commits only the local draft deletion before returning `true`. The host must finish pending local edits and exclude its current note before requesting cleanup. It must not automatically publish a discardable blank.

## Validation

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/GistPadSync
```

Tests use URLProtocol fakes and temporary SwiftData stores. They never read or mutate the user's GitHub/Supabase accounts. Live browser sign-in, account list verification and a user-approved scratch-gist round trip remain app/device integration gates.

API choices were checked against [Supabase OAuth](https://supabase.com/docs/reference/swift/auth-signinwithoauth), the pinned SDK source, [GitHub Gists](https://docs.github.com/en/rest/gists/gists), [Keychain services](https://developer.apple.com/documentation/security/keychain-services) and [SwiftData ModelActor](https://developer.apple.com/documentation/swiftdata/modelactor).

## Daily-driver operations

The package supports iOS 27.2 and later. It has no Duo-only UI dependency.

`DailyNotes(accountID:githubUserID:client:store:publisher:)` shares the active account's existing publisher. Create a `DailyNote.Day(date:timeZone:)` at the start of an action, then call `stageToday(target:)`. The target pins the local Gregorian date even if midnight or the time zone changes while the request runs. It freshly lists owned gists and selects the first exact `📆 Daily notes` match in the same stable updated-date order as the web.

If today's file exists, opening it is read-only and preserves dirty drafts. If missing, it stages a durable new-file draft, expands every `{{date}}` in `template.md`, and publishes a targeted file change through the ordinary conflict protocol. Missing/empty templates use `# YYYY-MM-DD\n\n`. No old daily files are deleted, carried over or rewritten. `publishIfMissing: false` stages locally instead.

If no daily gist exists, the service stages one secret gist with today's file and publishes it through the uncertain-create path. The durable daily-creation intent is reused across requests and relaunches. A timeout cannot lead to another POST. If the created gist appears in a later fresh list with matching source, the original draft is reconciled rather than abandoned. A pending first creation from an earlier date requires resolution before creating another daily gist. GitHub still offers no atomic cross-client create-if-absent guarantee, so simultaneous first creation on the web can race.

`DailyNotesIndex.notes(gist:localContent:date:timeZone:)` gives task progress and overdue-first, newest-first ordering using the web's exact task-marker convention. Uncached/truncated file contents have unknown progress, not a misleading zero. `DraftStore.newGistDraft(...)` stages a new ordinary note with the web's `README.md`, description-heading and empty-content defaults. Publication remains secret by default.

Cache a complete list refresh with `cacheLibrary(owned:starred:preferences:accountID:)`, detail reads with `cacheGist(_:accountID:)`, and resolved raw content with `cacheContent(_:gist:filename:accountID:)`. The persisted `cachedLibrary(accountID:)` is account-isolated and survives relaunch. An unsuccessful network refresh must not replace it with an empty library.

`LibrarySearch.search(_:query:collection:drafts:date:timeZone:)` searches cached titles, filenames and available Markdown. This intentionally improves on the web's description-only filter. It overlays accepted local drafts, including unpublished files and new notes, without mixing accounts. `LibrarySearchQuery(query:preferences:tagIDs:)` accepts free words, quoted phrases, `tag:ID`, `tag:"Tag name"` and `#TagName`. All text terms and tags are conjunctive. Unknown/ambiguous typed tags and malformed quoting are explicit errors. Deleted selected tag IDs are ignored to match the web. Results report cached-content coverage, incomplete gists and stale content rather than implying a complete server-side search.

The app uses one `.all` query across the Library. Daily rows represent real Gregorian `yyyy-MM-dd.md` files and eligible local drafts, never `template.md`, unrelated Markdown or the backing gist itself. Their stable published row identity is `gistID/filename`. A known complete file list supplies the unfiltered day count. A missing or truncated list leaves that count unknown. Clean saved files absent from a complete daily list stay excluded, while dirty or uncertain local work remains visible. Searching or displaying membership never fetches or creates a note.

Retained drafts whose gist has disappeared from the cache remain searchable by body and tags with `isRecovery == true`. They preserve their real draft ID and original gist ID, without fabricating a remote Gist value. Open their local draft directly. Absence from a cache is not proof of remote deletion, and their remote privacy/access cannot be inferred from local-only presentation defaults.

`GistLinks(gist:filename:draft:)` returns a read-only `/#/share/` URL, an explicit editor URL, and a GitHub URL, with correct UTF-8 filename escaping. It reports `isSecret` and `hasUnpublishedChanges`. It never publishes. A new, unpublished gist/file cannot yield a saved-file share URL. The UI must explain that secret gists are unlisted and links expose the saved revision.

## App Group boundary

Only the widget snapshot lives in the App Group container, written by GistPadPlatform's `LibrarySnapshot`. Canonical drafts stay in the app's private store, and the app is the only SwiftData writer. Widgets and Shortcuts run their edits in the main app through iOS 27's intent execution target.

## Photos

```swift
let png = try PhotoStorage.png(from: pickedData)
let storage = try await accounts.photoStorage(accountID: account.id)
let url = try await storage.upload(png, gistID: gistID)
let markdown = PhotoStorage.markdown(url) // ![Image](url)
```

Use PhotosPicker in the app and load its transferable image data without requesting broad library access. Normalize off the main actor. `PhotoImage` converts the first image to upright PNG without carrying location/EXIF metadata. It rejects invalid images, inputs/outputs over 50 MB and decoded images over 100 megapixels. These are native safety limits, not claims about the server's configured bucket limit.


The upload contract matches the web: `POST /storage/v1/object/assets/{gistId}/{lowercase-uuid}.png`, the project `apikey`, a Bearer Supabase access token (never the GitHub provider token), `Content-Type: image/png`, and `Cache-Control: max-age=3600`. There is no upsert. The public URL is `/storage/v1/object/public/assets/{gistId}/{uuid}.png`. The low-level client supports the web's publishable-key fallback. Native account-bound clients instead reject signed-out/wrong-account use and refresh the Supabase session when needed.

The app must offer insertion only for an editable, current-account document. The storage service does not determine GitHub ownership from an asset path. Storage conflict/error semantics follow [Supabase's current error codes](https://supabase.com/docs/guides/storage/debugging/error-codes).

**Assets are public even when the gist is secret.** Explain that before the first upload. No test uploads to the live bucket. Like the web, there is no local upload queue. The app uploads once, inserts the Markdown at the cursor as an ordinary undoable edit, and offers Try Again when an upload fails.
