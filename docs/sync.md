# How GistPad syncs

You should never have to think about sync. Nothing you type is lost, you always see the latest version, and GitHub is the source of truth.

## The five rules

1. **Every keystroke is saved on the phone right away**, before anything goes over the network.
2. **If a note has no unpublished edits, it shows what's on GitHub.** The copy on the phone is only a cache, so notes open instantly and can be read offline.
3. **Publishing happens automatically.** Edits publish 5 seconds after you stop typing. They also always publish when you leave the note (back to the list or to another file) and when you leave the app. The Autosave setting only turns off the 5-second publish.
4. **A draft exists only while it has unpublished edits.** When GitHub has your text, the draft is gone. Undoing your way back to the published text also clears it.
5. **You're only interrupted when you'd otherwise lose words.** That only happens in a conflict.

## Editing a file

- **Open.** The cached copy shows instantly, then the note refreshes from GitHub. If you haven't made edits, GitHub's version replaces the cached copy silently. You never see a warning.
- **Return to the app.** The open note refreshes the same way.
- **Edit.** Each edit is saved on the phone and marked as unpublished.
- **Publish.** If GitHub still has the version you started editing from, your text replaces it.
- **Conflict.** If GitHub changed after you started editing, nothing is overwritten. You see both versions and choose one of two options:
  - **Keep Mine** publishes your text over GitHub's. The gist's history on GitHub still has their version.
  - **Use GitHub's** replaces your text with theirs as one edit you can undo.

  A conflict can only happen when GitHub changes while you have unpublished edits.

## New gist

- **Create.** A blank note opens immediately and lives on the phone, so it works offline.
- **First publish.** The gist is created on GitHub at the first publish after you write something.
- **Left blank.** The note is discarded, so empty gists never reach GitHub.
- **No duplicates.** If the app can't tell whether a create went through, for example because the connection dropped, it checks GitHub before trying again.

## New file in a gist

- **Same as a new gist.** The file stays on the phone until it has text and a publish happens.
- **Left blank.** The file is discarded. GitHub can't store empty files.

## Daily notes

- **Today's note** is a file in the Daily notes gist, created from your template.
- **Same as a new file.** An untouched template (text identical to the template) is discarded. The note is created on GitHub once you write in it.
- **Earlier days** are deleted on purpose. Nothing carries over.

## Everything else

These actions aren't drafted:
- Title
- Tags
- Star
- Archive
- File rename
- Delete

They apply on GitHub right away and need a connection. If you're offline, they fail with a clear message and nothing changes.

Delete works in any state. It removes the gist from GitHub if it got there, and discards anything on the phone.

## When things go wrong

- **Offline.** Edits keep saving on the phone, and they publish at the next publish trigger after you're back online.
- **GitHub sign-in expired.** Edits stay on the phone. One Reconnect prompt appears, then they publish.
- **Someone else's gist.** It's read-only.

## What you see

Status has only three meanings:

- **Nothing shown:** it's on GitHub.
- **Not published yet:** it's on the phone and will publish by itself. This covers publishing in progress and being offline.
- **Needs you:** a conflict, or GitHub needs reconnecting.

## Deliberately left out

- **No automatic merging.** Conflicts don't offer a combined version.
- **No extra copies of your text.** There are no recovery snapshots, only the one unpublished draft.
- **No background sync.** The app publishes your own edits and refreshes what you open, nothing more.
