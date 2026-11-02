# 📓 GistPad Native

A native iPhone app for [GistPad](https://gistpad.dev), the notebook that keeps your notes, daily notes and prompts in GitHub Gists. It's the pocket companion to [gistpad.dev](https://gistpad.dev) and the [GistPad extension](https://aka.ms/gistpad) for VS Code. Sign in with GitHub and the same gists, daily notes, tags and pins are on your phone, woven into widgets, Siri, Spotlight and on-device Apple Intelligence.

## Features

- **Start your day from the Home Screen:** The GistPad widget shows today's date, your most recent gists and New Gist. Tap the date to open today's daily note, or a gist to pick up where you left off.
- **Capture a thought in seconds:** Say "Add to Today in GistPad", or run Add to Today from Shortcuts, and the line lands in today's note as text or a task without opening the app. Add to Today and Open Today are also controls for Control Center, the Lock Screen and the Action button.
- **One notebook everywhere:** Every note is a GitHub gist, so what you write on your phone is waiting in gistpad.dev and VS Code, and the other way around. Tags, pins and settings follow your GistPad account too.
- **Find any gist from anywhere:** Spotlight finds gists by title, tags and opening lines. Ask Siri to "Open Today in GistPad" or open a gist by name, and build your own automations from GistPad's actions in Shortcuts.
- **Write Markdown, read it beautifully:** A native Markdown editor with a glass formatting bar, Find and Replace and photos from your library. Preview uses the same renderer as gistpad.dev, so Mermaid diagrams, calculations and tasks you can check off look the way they do on the web. Split shows both side by side when there's room.
- **Never lose a word:** Every keystroke is saved on your phone, so you can read and write offline. Edits publish to GitHub five seconds after you stop typing, and whenever you leave a note. If a gist changed somewhere else, GistPad shows both versions and lets you choose.
- **Private AI on your phone:** Ask a question about a note and get an answer that cites it, describe an edit and review every change before applying it, or have a note reviewed for errors and unclear wording. Writing Tools work everywhere you type. It all runs on device with Apple Intelligence, so your notes never leave your phone for AI.
- **Comments in context:** Select a passage to comment on it, and see highlights in the editor and Preview. They're the same gist comments you see on gistpad.dev.
- **Made for the iPhone Duo:** Open the Duo and your library sits beside the note, like a notebook. Fold or unfold mid-sentence, and your mode, cursor and Undo stay exactly where they were.
- **Organize and share:** Pin, star, archive and tag gists in your own colors, filter the library by tag, and share or copy a gistpad.dev link in a tap.
- **Native by design:** Built to feel like it shipped next to Notes, with Liquid Glass, Dynamic Type, Dark Mode and your own accent color.

## Developing

1. Install Xcode 27.2 with the iOS 27.2 SDK, and Node.js.
2. Open `GistPad.xcodeproj` and run the GistPad scheme on an iPhone or simulator running iOS 27.2 or later.

See [AGENTS.md](AGENTS.md) for building, testing, the module map and how a change ships. [docs/design.md](docs/design.md) is the design spec and [docs/sync.md](docs/sync.md) is the sync contract.
