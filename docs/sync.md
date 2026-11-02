# How GistPad syncs

You should never have to think about sync. Nothing you type is lost, you always see the latest version, and GitHub is the source of truth.

## The five rules

1. **Every keystroke is saved on the phone right away**, before anything goes over the network.
2. **If a file has no unpublished edits, it shows what's on GitHub.** The copy on the phone is only a cache, so files open instantly and can be read offline.
3. **Publishing happens automatically.** Edits publish 5 seconds after you stop typing. They also always publish when you leave the file (back to the list or to another file) and when you leave the app. The Autosave setting only turns off the 5-second publish.
4. **Only unpublished edits are held back.** Once GitHub has your text, there's nothing left to publish. Undoing your way back to the published text has the same effect.
5. **You're only interrupted when you'd otherwise lose words.** That only happens in a conflict.

## Editing a file

- **Open.** The cached copy shows instantly, then the file refreshes from GitHub. If you haven't made edits, GitHub's version replaces the cached copy silently. You never see a warning.
- **Return to the app.** The open file refreshes the same way.
- **Edit.** Each edit is saved on the phone and marked as unpublished.
- **Publish.** If GitHub still has the version you started editing from, your text replaces it.
- **Conflict.** If GitHub changed after you started editing, nothing is overwritten. You see both versions and choose one of two options:
  - **Keep Mine** publishes your text over GitHub's. The gist's history on GitHub still has their version.
  - **Use GitHub's** replaces your text with theirs as one edit you can undo.

  A conflict can only happen when GitHub changes while you have unpublished edits.

  If the file was deleted on GitHub, GitHub's side is empty and Keep Mine adds the file back with your text.

## New gist

- **Create.** A new gist opens immediately and lives on the phone, so it works offline. You can rename it or delete it before it ever reaches GitHub.
- **First publish.** The gist is created on GitHub at the first publish after you give it a title or write something. Like the web, it's secret.
- **Left blank.** A gist with no title and nothing typed is discarded when you leave it, so empty gists never reach GitHub.
- **No duplicates.** If the app can't tell whether a create went through, for example because the connection dropped, it checks GitHub before trying again.

## New file in a gist

- **Add.** Adding a file needs a connection, so GistPad can check the name is free. The file then publishes at the next publish moment, like any edit.
- **Left blank.** The file is still created. GitHub can't store an empty file, so it's saved with the same invisible placeholder the web uses.

## Daily notes

- **Opening today's note creates it**, whether or not you type in it. That's true from the Today button, the widget, Shortcuts, or the app opening on today. The day starts from the Daily notes gist's template, with the date filled in, or a heading with the date when there's no template. It opens offline too, and publishes on the normal schedule.
- **The first day creates the Daily notes gist.** If an earlier day never reached GitHub, opening the next day publishes it first, so every day lands in one gist.
- **Earlier days** are deleted on purpose. Nothing carries over.
- **Deleting a day** removes that day's file, or the whole gist when it's the last file.

## Everything else

These actions aren't drafted. They apply right away and need a connection. If you're offline, they fail with a clear message and nothing changes.

- **On GitHub:** title, star, archive, file rename and delete.
- **In your GistPad account,** shared with the web: tags, pins and settings.

A gist that's only on the phone can still be renamed or deleted offline.

Delete works in any state. It removes the gist from GitHub if it got there, and discards anything on the phone.

## When things go wrong

- **Offline.** Edits keep saving on the phone, and they publish at the next publish moment after you're back online. Files you left with unpublished edits also publish when you open or return to the app.
- **GitHub sign-in expired.** Edits stay on the phone. Reconnect from the GitHub needs attention button, then they publish.
- **The gist was deleted somewhere else.** Your unpublished copy stays on the phone and never publishes, so you can copy your words out before you delete it.
- **Someone else's gist.** It's read-only.

## What you see

- **Nothing:** it's on GitHub, or it's on the phone and will publish by itself.
- **Publish:** Autosave is off, or a publish didn't land because you're offline or GitHub had a problem. Your text is saved on the phone either way, and tapping it tries again.
- **GitHub needs attention:** a conflict, which opens both versions, or GitHub needs reconnecting.
- **Couldn't sync, in the list:** a file or change didn't reach GitHub or your account. It says whether your changes are still saved on the phone.

## Deliberately left out

- **No automatic merging.** Conflicts don't offer a combined version.
- **No extra copies of your text.** There are no recovery snapshots, only the one unpublished draft.
- **No background sync.** The app publishes your own edits and refreshes what you open, nothing more.
