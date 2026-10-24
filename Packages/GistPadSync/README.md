# GistPadSync

Swift 6 actors and Sendable values for the native app's account, Gists, preferences and durable drafts. No UI or editor ownership lives here. The only external product is Supabase's `Auth`, pinned in `Package.swift` and `Package.resolved`.

## Account and reads

```swift
let accounts = try AccountService(publishableKey: configuredPublicKey)
let account = try await accounts.signIn()
let client = await accounts.githubClient(accountID: account.id)
let library = try await client.listGists()
let gist = try await client.gist(id: selectedGistID)
let text = try await client.content(gist: gist, filename: selectedFilename)
```

`cachedAccount()` restores without requiring the network. `refreshAccount()` fetches current Supabase metadata. `signIn()` uses the SDK's `ASWebAuthenticationSession` with PKCE, GitHub's `gist` scope and `gistpad://auth-callback`. The launch-flow overload supports injected presentation and fake exchanges. The same callback must be allowed in the Supabase dashboard.

Supabase session/PKCE data and the separately retained, account-scoped GitHub provider token use Keychain, accessible only while unlocked on this device. Supabase refresh responses can omit the provider token. Storage failures propagate instead of being mistaken for sign-out. SDK logging is disabled because callback URLs and HTTP details may contain credentials. Pass only a publishable/legacy anon project key, never a service-role key.

Create a new client for each account. Its credential provider rejects an account switch or sign-out. Clear app-visible document and library references when switching accounts. `AccountSnapshot.githubUserID` is available when Supabase supplies GitHub identity metadata. If absent, fetch `client.authenticatedUser().id` before creating an editable draft. **Never use a selected foreign gist's owner ID as the current account's GitHub ID.**

The client paginates, applies the web's different owned/starred Markdown filters, and retains ETags in memory only. It preserves archive/daily-note markers, exact source bytes and the U+2064 empty-file sentinel. Secret gists are the create default. Updates are targeted file dictionaries, including rename and deletion. Truncated file content uses an unauthenticated HTTPS raw URL on `gist.githubusercontent.com`. A truncated overall file list is explicitly unsupported, never treated as complete. Production sessions reject redirects and never persist note responses to the URL cache.

## Preferences

```swift
let updated = try await accounts.apply(
    .setTag(gistID: gist.id, tagID: existingTagID, included: true),
    accountID: account.id
)
```

Operations include `setPinned`, `setTag`, `upsertTag`, `deleteTag` and `setBoolean`. They fetch current metadata before applying, send only changed top-level fields, and preserve unknown nested tag fields. Malformed existing shapes throw rather than being replaced. Account-changing actions and preference mutations cannot overlap. This minimizes web/native collisions, but Supabase user metadata does not provide atomic compare-and-swap.

## Durable editing and publication

```swift
let store = try DraftStore.open()
let draft = try await store.openDraft(
    accountID: account.id, githubUserID: verifiedGitHubUserID,
    gistID: gist.id, filename: selectedFilename,
    description: gist.displayDescription, content: text, revision: gist.revision
)
// Restore draft.text and draft.generation before starting this document session.
let durable = try await store.persist(
    id: draft.id, accountID: account.id, text: sessionText, generation: sessionGeneration
)
let sync = SyncCoordinator(client: client, store: store)
let result = try await sync.publish(id: durable.id, accountID: account.id)
```

Use one store for the app and one coordinator for the active account, shared across scenes. Replace the coordinator when switching accounts. `openDraft` returns an existing account/file draft instead of overwriting it with a network response. Generation must increase for every content edit, including undo. SwiftData's automatic saving and CloudKit are disabled. Every successful persistence operation explicitly commits before returning. Never display "Saved on this iPhone" before `persist` succeeds.

On reopen, capture the stored generation **before** requesting fresh remote content, then call `refreshCleanDraft(id:accountID:expectedGeneration:content:revision:)`. It updates only an unchanged clean baseline with no uncertain write. Its result explicitly reports refreshed, unchanged or preserved local changes. A newer generation rejects a stale response. Restore that snapshot into an inactive/new document session, never an actively composing editor.

The coordinator serializes publication, freshly reads the remote file, validates ownership/completeness, and persists a recovery snapshot and attempted generation before sending. Acknowledging one generation never clears newer local typing. `recoveries(id:accountID:)` exposes retained source snapshots for recovery/export. On restart, an interrupted operation becomes uncertain rather than remaining labelled "Saving".

`SaveState` distinguishes local durability, an in-flight generation, GitHub acknowledgement, offline, reconnect, typed failures and conflicts. A failure is persisted and thrown. The UI should reload the snapshot to show its state. A `404` retains the draft. A `403` is not sign-out. Rate-limit reset and `Retry-After` deadlines are honored.

`scheduleAutosave` coalesces edits with the web's five-second delay. Always persist locally first. Cancel scheduled publishing immediately when autosave is disabled or the account changes. Background publication is permitted only when autosave is enabled. Folding itself must never request publication. Pending AI proposals, marked text and temporary Writing Tools edits are not accepted draft generations.

## Conflicts and uncertain writes

`SaveState.conflict` includes the base, local, remote, expected generation, remote revision and an optional byte-exact, nonoverlapping line merge. The sync layer does **not** change active editor text. The document session may accept a safe merge only when input composition/Writing Tools is inactive, apply it as one undoable edit, then call `resolveConflict(id:accountID:expectedGeneration:text:generation:)`. Overlapping edits and deleted files require an explicit resolution. Re-publish after applying. Stale resolutions are rejected.

After a timed-out PATCH, the next publication reads remote content before any repeat write. If it matches the attempted generation, that generation is acknowledged without another PATCH. A timed-out POST is never automatically retried, including after relaunch. Let the user inspect their library and explicitly select the created gist, then call `reconcileCreation(id:accountID:createdGistID:)`. The coordinator verifies owner and exact content before attaching it. Otherwise retain/export the draft instead of guessing that creation failed.

GitHub Gist PATCH has no documented conditional-write precondition. A fresh read and recovery snapshots reduce risk but cannot close the race with simultaneous web writes. Do not describe this as atomic collaborative editing.

Before sign-out, ask the user to keep, export or discard unsynced work using `hasUnsyncedWork(accountID:)`. Kept drafts remain account-isolated. The account service does not delete local drafts.

After an acknowledged remote rename, `updateDraftMetadata(id:accountID:expectedFilename:filename:description:)` retargets the same draft without changing source, generation, baseline, state or recovery history. Filename collisions, stale metadata and unresolved publication attempts are explicit errors. Serialize remote metadata mutations with publication and flush the active session first. This operation does not rename anything on GitHub.

After a confirmed remote deletion, `removeCleanDraftsForDeletedGist(gistID:accountID:)` removes only acknowledged, byte-clean drafts without recovery history. Dirty, uncertain, conflicted and historical recovery-bearing drafts stay intact and are returned for recovery presentation. The host must label their remote note as deleted and not recreate it implicitly. Retained state/source are deliberately unchanged.

## Validation

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/GistPadSync
```

Tests use URLProtocol fakes and temporary SwiftData stores. They never read or mutate the user's GitHub/Supabase accounts. Live browser sign-in, account list verification and a user-approved scratch-gist round trip remain app/device integration gates.

API choices were checked against [Supabase OAuth](https://supabase.com/docs/reference/swift/auth-signinwithoauth), the pinned SDK source, [GitHub Gists](https://docs.github.com/en/rest/gists/gists), [Keychain services](https://developer.apple.com/documentation/security/keychain-services) and [SwiftData ModelActor](https://developer.apple.com/documentation/swiftdata/modelactor).

## Daily-driver operations

The package supports iOS 27.1 and later. It has no Duo-only UI dependency.

`DailyNotesService(accountID:githubUserID:client:store:coordinator:)` shares the active account's existing coordinator. Create a `DailyNoteTarget(date:timeZone:)` at the start of an action, then call `openToday(target:)`. The target pins the local Gregorian date even if midnight or the time zone changes while the request runs. It freshly lists owned gists and selects the first exact `📆 Daily notes` match in the same stable updated-date order as the web.

If today's file exists, opening it is read-only and preserves dirty drafts. If missing, it stages a durable new-file draft, expands every `{{date}}` in `template.md`, and publishes a targeted file change through the ordinary conflict protocol. Missing/empty templates use `# YYYY-MM-DD\n\n`. No old daily files are deleted, carried over or rewritten. `publishIfMissing: false` stages locally instead.

If no daily gist exists, the service stages one secret gist with today's file and publishes it through the uncertain-create path. The durable daily-creation intent is reused across requests and relaunches. A timeout cannot lead to another POST. If the created gist appears in a later fresh list with matching source, the original draft is reconciled rather than abandoned. A pending first creation from an earlier date requires resolution before creating another daily gist. GitHub still offers no atomic cross-client create-if-absent guarantee, so simultaneous first creation on the web can race.

`DailyNotesIndex.notes(gist:localContent:date:timeZone:)` gives task progress and overdue-first, newest-first ordering using the web's exact task-marker convention. Uncached/truncated file contents have unknown progress, not a misleading zero. `DraftStore.createGistDraft(...)` stages a new ordinary note with the web's `README.md`, description-heading and empty-content defaults. Publication remains secret by default.

Cache a complete list refresh with `cacheLibrary(owned:starred:preferences:accountID:)`, detail reads with `cacheGist(_:accountID:)`, and resolved raw content with `cacheContent(_:gist:filename:accountID:)`. The persisted `cachedLibrary(accountID:)` is account-isolated and survives relaunch. An unsuccessful network refresh must not replace it with an empty library.

`LibrarySearch.search(_:query:collection:drafts:date:timeZone:)` searches cached titles, filenames and available Markdown. This intentionally improves on the web's description-only filter. It overlays accepted local drafts, including unpublished files and new notes, without mixing accounts. `LibrarySearchQuery(query:preferences:tagIDs:)` accepts free words, quoted phrases, `tag:ID`, `tag:"Tag name"` and `#TagName`. All text terms and tags are conjunctive. Unknown/ambiguous typed tags and malformed quoting are explicit errors. Deleted selected tag IDs are ignored to match the web. Results report cached-content coverage, incomplete gists and stale content rather than implying a complete server-side search.

Retained drafts whose gist has disappeared from the cache remain searchable by body and tags with `isRecovery == true`. They preserve their real draft ID and original gist ID, without fabricating a remote Gist value. Open their local draft directly. Absence from a cache is not proof of remote deletion, and their remote privacy/access cannot be inferred from local-only presentation defaults.

`DocumentLinks(gist:filename:draft:)` returns a read-only `/#/share/` URL, an explicit editor URL, and a GitHub URL, with correct UTF-8 filename escaping. It reports `isSecret` and `hasUnpublishedChanges`. It never publishes. A new, unpublished gist/file cannot yield a saved-file share URL. The UI must explain that secret gists are unlisted and links expose the saved revision.

## App Group boundary

`SharedStoreLocation(appGroupIdentifier:)` resolves the entitled container using FileManager. There is no fallback to an unrelated container if entitlement/configuration is wrong. The store directory and command files request complete file protection. `DraftStore.open(location:)` uses an explicit SwiftData URL with no CloudKit. Locked-device extension access is not promised. For tests, `SharedStoreLocation(containerURL:)` accepts a temporary directory. The app and future extension targets still need the same App Group entitlement. Adding that entitlement does not automatically move the current store. Migrate existing drafts explicitly before changing locations.

**The app remains the single SwiftData writer.** Opening a second SwiftData actor in a widget while the app owns an active document is not cross-process synchronization. For now, extensions use `SharedDraftInbox` to enqueue immutable `SharedDraftCommand` values and show Pending, never Completed. A fully written command is atomically published under its UUID without overwriting another process's command. Account-specific inbox directories avoid loading another account's command content.

The main app flushes accepted editor changes and imports commands only when the affected session can accept an external edit. `DraftStore.apply(_:)` validates account, expected generation, UTF-16 scalar boundaries and exact expected source. The new source and deduplication receipt are committed in one SwiftData save. The host must then update the active document session through its undoable edit path, or reload an inactive session. Delete the inbox envelope with `acknowledge(_:)` only after that successful import. A crash before acknowledgement is safe to replay. Stale or invalid commands remain actionable errors, never silently discarded.

This is an honest foundation for M4 capture and controls. Immediate widget checkbox completion while the app is not running still requires a process-coordinated mutation owner and extension integration. An enqueued command alone is not proof that the note changed or reached GitHub. Keychain credentials are not shared with extensions.

## Photos and durable image uploads

```swift
let png = try PhotoImage.pngData(from: pickedData)
let pending = try await store.enqueueImage(
    pngData: png, draftID: draft.id, accountID: account.id,
    expectedGeneration: draft.generation, insertionLocation: selectedUTF16Offset
)
let storage = try await accounts.imageStorageClient(accountID: account.id)
let images = ImageUploadCoordinator(accountID: account.id, store: store, storage: storage)
let uploaded = try await images.upload(id: pending.id)
let proposal = try await store.imageInsertion(id: uploaded.id, accountID: account.id)
```

Use PhotosPicker in the app and load its transferable image data without requesting broad library access. Normalize off the main actor. `PhotoImage` converts the first image to upright PNG without carrying location/EXIF metadata. It explicitly rejects invalid images, inputs/outputs over 50 MB and decoded images over 100 megapixels. These are native safety limits, not claims about the server's configured bucket limit.

The upload contract matches the web: `POST /storage/v1/object/assets/{gistId}/{lowercase-uuid}.png`, the project `apikey`, a Bearer Supabase access token (never the GitHub provider token), `Content-Type: image/png`, and `Cache-Control: max-age=3600`. There is no upsert. The public URL is `/storage/v1/object/public/assets/{gistId}/{uuid}.png`. The low-level client supports the web's publishable-key fallback. Native account-bound clients instead reject signed-out/wrong-account use and refresh the Supabase session when needed.

The app must offer insertion only for an editable, current-account document. The storage service does not determine GitHub ownership from an asset path. Storage conflict/error semantics follow [Supabase's current error codes](https://supabase.com/docs/guides/storage/debugging/error-codes).

**Assets are public even when the gist is secret.** Explain that before the first upload. No test uploads to the live bucket. The native Photos action, its permission/privacy presentation and its undo/session integration remain app-owned.

Enqueue commits PNG bytes and the original insertion generation/location to the same local SwiftData store as drafts before returning. On iOS, persistent store directories and existing SQLite/journal files request complete file protection. No background or locked-device transfer is promised. Pending images count as unsynced work and prevent deletion of an otherwise clean recovery draft.

`ImageUploadCoordinator` coalesces concurrent requests for one image. A stable UUID/path survives offline errors and relaunch. Interrupted requests reopen as uncertain. A retry first checks that exact public path with no credentials, comparing both byte count and SHA-256. The same verification follows successful POST and duplicate responses. A missing or mismatched asset never exposes a ready URL or inserts Markdown. Retry-After is durable and honored. Failures persist and throw, rather than dropping the image.

Call `resumePending()` after account restoration, explicit foreground recovery or a connectivity change. It returns an explicit Result for each attempted transfer. Waiting unpublished notes remain visible without an HTTP request until their gist ID is acknowledged. Reconnect, permanent failure, queued, uploading, offline, uncertain, uploaded and inserted states are inspectable with `imageUploads(accountID:)`. Cancel active transfers on account change with `cancelUploads()`. This is foreground resumption, not an iOS background-transfer entitlement.

Pending placeholders stay out of canonical Markdown and Undo, as on the web. A verified upload proposes exactly `![Image](URL)`, or `<img src="URL" />` for explicit HTML format. If the document generation changed, the original proposal is rejected. Let the user select a current insertion point and request `imageInsertion(id:accountID:expectedGeneration:insertionLocation:)` instead of guessing where to insert.

Flush accepted session edits and wait for composition/Writing Tools to end before applying a proposal. `applyImageInsertion(id:accountID:command:)` commits the source edit, deduplication receipt and inserted state together. Reflect that exact edit in the active session as one undoable edit at the same generation, or reload an inactive session. Do not independently insert the text twice. An interrupted acknowledgement can safely replay the same command. Image insertion only saves locally. Ordinary autosave-off publication rules still apply.

`discardImageUpload(id:accountID:)` removes local queued bytes/state only after the app's explicit discard action. It cannot cancel an in-flight transfer or delete a remote asset. After an inserted upload, discarding its local cache does not remove the note's Markdown. A public orphan from a canceled insertion is possible and is never silently deleted from the user's storage.
