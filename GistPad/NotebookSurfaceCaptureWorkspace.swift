#if DEBUG
import GistPadEditor
import GistPadInterface
import GistPadSync
import SwiftUI

struct NotebookSurfaceCaptureWorkspace: View {
  let screen: String
  @State private var session = DocumentSession(
    documentID: "note-chrome-capture",
    text: """
      # A place for good ideas

      Some days, all you need is a little room to think.

      Keep the useful things close. Let the rest find their place.

      ## A few things worth keeping

      - A good walk clears more than your head.
      - The best ideas usually start as a sentence.
      - Leave a little space for tomorrow.

      ## Next, something small

      - [x] Make room to write
      - [ ] Follow the thread
      - [ ] See where it goes
      """)
  @State private var mode = NoteMode.reading
  @State private var presentedSheet: CaptureSheet?
  @State private var metadata: [String: MetadataValue] = [
    "isAutoSaveEnabled": .bool(true),
    "accentColor": .string("#0EA5E9"),
  ]
  @State private var selectedTagIDs: Set<String> = ["ideas", "everyday"]

  static func supports(_ screen: String) -> Bool {
    ["note-chrome", "note-loading", "note-failed", "settings", "settings-signed-out", "tags", "account"]
      .contains(screen)
  }

  var body: some View {
    NavigationStack {
      if screen == "note-loading" {
        NotebookOpeningView(title: "A place for good ideas")
      } else if screen == "note-failed" {
        NotebookFailedOpeningView(
          failure: .init(
            rowID: "fixture", title: "A place for good ideas", gistID: "fixture",
            filename: "README.md", draftID: nil,
            message: "The Internet connection appears to be offline.")
        ) {}
      } else {
        NoteScreen(
          document: chrome, mode: $mode, saveState: captureSaveState, actions: actions
        ) {
          MarkdownEditorView(session: session)
        } preview: {
          SessionPreview(session: session)
        }
      }
    }
    .personalAccent(savedHex: metadata["accentColor"]?.stringValue)
    .sheet(item: $presentedSheet) { sheet in
      switch sheet {
      case .settings:
        settings
      case .tags:
        TagEditor(tags: Self.tags, selectedTagIDs: selectedTagIDs) { edits in
          for edit in edits {
            if case .setMembership(let id, let included) = edit {
              if included { selectedTagIDs.insert(id) } else { selectedTagIDs.remove(id) }
            }
          }
        }
      case .account:
        NotebookAccountSwitchSheet(
          current: "octavia", replacement: "mira", export: { Data("[]".utf8) },
          switchAccount: { presentedSheet = nil }, keepCurrent: { presentedSheet = nil })
      }
    }
    .task {
      if screen.hasPrefix("settings") { presentedSheet = .settings }
      if screen == "tags" { presentedSheet = .tags }
      if screen == "account" { presentedSheet = .account }
    }
  }

  private var chrome: NoteChrome {
    let files = ProcessInfo.processInfo.arguments.contains("--capture-multi-file")
      ? [NoteFile(id: "README.md", filename: "README.md"), .init(id: "Ideas.md", filename: "Ideas.md")]
      : [NoteFile(id: "README.md", filename: "README.md")]
    return .init(
      title: "A place for good ideas", files: files, selectedFileID: "README.md",
      tags: Array(Self.tags.prefix(2)), isAutoSaveEnabled: true)
  }

  private var captureSaveState: NoteSaveState {
    if ProcessInfo.processInfo.arguments.contains("--capture-offline") { return .offline }
    if ProcessInfo.processInfo.arguments.contains("--capture-cloud-failure") {
      return .cloudFailure(message: "The Internet connection appears to be offline.")
    }
    return .savedToGitHub
  }

  private var actions: NoteActions {
    var actions = NoteActions()
    actions.selectFile = { _ in }
    actions.rename = {}
    actions.renameFile = {}
    actions.addFile = {}
    actions.togglePin = {}
    actions.toggleStar = {}
    actions.share = {}
    actions.copyLink = {}
    actions.find = { mode = .source; session.presentFind(replacing: true) }
    actions.tags = { presentedSheet = .tags }
    actions.intelligence = {}
    actions.openInGitHub = {}
    actions.toggleArchive = {}
    actions.delete = {}
    actions.retry = {}
    actions.save = {}
    return actions
  }

  private var settings: some View {
    NotebookSettingsSheet(
      account: screen == "settings-signed-out" ? nil : .init(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        login: "octavia", preferences: .init(metadata: metadata)),
      savePreference: { key, value in metadata[key.rawValue] = .bool(value) },
      connect: { presentedSheet = .account }
    ) {
      PersonalAccentColorRow(savedHex: metadata["accentColor"]?.stringValue) {
        metadata["accentColor"] = .string($0)
      }
    }
  }

  private enum CaptureSheet: String, Identifiable {
    case settings, tags, account
    var id: Self { self }
  }

  private static let tags = [
    LibraryTag(id: "everyday", name: "Everyday", colorHex: "#0EA5E9"),
    LibraryTag(id: "ideas", name: "Ideas", colorHex: "#DB9E47"),
    LibraryTag(id: "making", name: "Making things", colorHex: "#6DAD8B"),
    LibraryTag(id: "reading", name: "Reading", colorHex: "#9D89C5"),
    LibraryTag(id: "weekend", name: "Weekend", colorHex: "#D87C8D"),
  ]
}
#endif
