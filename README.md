# 📓 GistPad iOS

A native iPhone app for [GistPad](https://gistpad.dev), the notebook that keeps your notes, daily notes and prompts in GitHub Gists. It's the pocket companion to [gistpad.dev](https://gistpad.dev) and the [GistPad extension](https://aka.ms/gistpad) for VS Code, and it's made for the iPhone Duo, so unfolding it puts your library beside the note. Sign in with GitHub and the same gists, daily notes, tags and pins are on your phone, woven into widgets, Siri, Spotlight and on-device Apple Intelligence.

## Features

- **Start your day from the Home Screen:** The GistPad widget shows today's date, your most recent gists and New Gist. Tap the date to open today's daily note, or a gist to pick up where you left off.
- **Capture a thought in seconds:** Say "Add to Today in GistPad", or run Add to Today from Shortcuts, and the line lands in today's note as text or a task without opening the app. Add to Today and Open Today are also controls for Control Center, the Lock Screen and the Action button.
- **Find any gist from anywhere:** Spotlight finds gists by title, tags and opening lines. Ask Siri to "Open Today in GistPad" or open a gist by name, and build your own automations from GistPad's actions in Shortcuts.
- **Write Markdown, read it beautifully:** A native Markdown editor with a glass formatting bar, Find and Replace and images from your library. Preview uses the same renderer as gistpad.dev, so Mermaid diagrams, calculations and tasks you can check off look just like they do on the web. Select any passage to comment on it, and the conversation shows up on gistpad.dev too.
- **Ready when you're offline:** Gists you've opened stay on your phone, so they open instantly with or without a connection. Today's note and new gists work offline too, and every keystroke is saved on your phone as you type. Once you're back online, your edits publish to GitHub the next time you pause or switch away, and if a gist changed somewhere else in the meantime, GistPad shows both versions and lets you choose.
- **Private AI on your phone:** Ask a question about a note and get an answer that cites it, describe an edit and review every change before applying it, or have a note reviewed for errors and unclear wording. Writing Tools work everywhere you type. It all runs on device with Apple Intelligence, so your notes never leave your phone for AI.

## Developing

1. Install Xcode 27.2 with the iOS 27.2 SDK, and Node.js.
2. Open `GistPad.xcodeproj` and run the GistPad scheme on an iPhone or simulator running iOS 27.2 or later.

See [AGENTS.md](AGENTS.md) for building, testing, the module map and how a change ships. [docs/design.md](docs/design.md) is the design spec and [docs/sync.md](docs/sync.md) is the sync contract.
