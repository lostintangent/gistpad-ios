import GistPadEditor
import GistPadInterface
import GistPadSync
import OSLog
import SwiftUI

struct LiveNotebookWorkspace: View {
  @Bindable var notebook: NotebookModel
  @State private var sessions: [String: NotebookSessionController] = [:]
  @State private var activeID: String?
  @State private var openRequest = UUID()
  @State private var compactColumn: NavigationSplitViewColumn = .sidebar
  @State private var actionMessage: String?
  @State private var shareURL: URL?
  @State private var showingShare = false
  @State private var showingSecretWarning = false
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase

  private var active: NotebookSessionController? {
    activeID.flatMap { sessions[$0] }
  }

  private var gistURL: URL? {
    guard let id = active?.draft.gistID else { return nil }
    return URL(string: "https://gist.github.com")?.appendingPathComponent(id)
  }

  var body: some View {
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      LibraryView(model: notebook.library, actions: libraryActions)
    } detail: {
      NavigationStack {
        if let active {
          note(active)
        } else {
          ContentUnavailableView(
            "Your next thought starts here", systemImage: "book.closed",
            description: Text("Choose a note from your library."))
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .tint(InterfaceTheme.accent)
    .overlay(alignment: .top) {
      if notebook.isOpeningDocument {
        ProgressView("Opening note")
          .padding()
          .background(.regularMaterial, in: .capsule)
          .allowsHitTesting(false)
      }
    }
    .task { await notebook.start() }
    .onChange(of: notebook.library.selectedNoteID) { _, selected in
      guard let selected, selected != active?.document.gist.id else { return }
      open(gistID: selected)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { finishLocalPersistence() }
    }
    .alert(
      "GistPad",
      isPresented: Binding(
        get: { actionMessage != nil || notebook.documentError != nil },
        set: {
          if !$0 {
            actionMessage = nil
            notebook.documentError = nil
          }
        })
    ) {
      Button("OK") {
        actionMessage = nil
        notebook.documentError = nil
      }
    } message: {
      Text(actionMessage ?? notebook.documentError ?? "")
    }
    .confirmationDialog(
      "Anyone with this link can read this secret gist.",
      isPresented: $showingSecretWarning, titleVisibility: .visible
    ) {
      Button("Share Link") { prepareShare() }
      Button("Cancel", role: .cancel) {}
    }
    .sheet(isPresented: $showingShare) {
      if let shareURL { LinkShareSheet(url: shareURL) }
    }
  }

  private var libraryActions: LibraryActions {
    var actions = LibraryActions(
      refresh: { await notebook.refresh() },
      create: {
        actionMessage = String(localized: "New gist creation is not connected in this build.")
      },
      today: {
        if let daily = notebook.library.snapshot.notes.first(where: \.isDailyNote) {
          open(gistID: daily.id, filename: GistConventions.todayFilename())
        } else {
          actionMessage = String(localized: "Creating daily notes is not connected in this build.")
        }
      })
    actions.reconnect = {
      Task {
        await notebook.signIn()
        if notebook.account?.id == active?.draft.accountID,
          notebook.pendingAccount == nil, notebook.library.loadState == .ready
        {
          active?.didReconnect()
        }
      }
    }
    return actions
  }

  private func note(_ controller: NotebookSessionController) -> some View {
    @Bindable var controller = controller
    return NoteScreen(
      document: controller.document.chrome, mode: $controller.mode,
      saveState: controller.saveState, actions: noteActions(controller)
    ) {
      MarkdownEditorView(session: controller.session)
    } preview: {
      SessionPreview(
        session: controller.session, allowsMutations: controller.document.chrome.access.canEdit,
        openWikilink: { target in
          if let note = notebook.library.snapshot.notes.first(where: {
            $0.title.localizedStandardCompare(target) == .orderedSame
          }) {
            open(gistID: note.id)
          } else {
            actionMessage = String(localized: "No note with that title is in your library.")
          }
        })
    }
  }

  private func noteActions(_ controller: NotebookSessionController) -> NoteActions {
    var actions = NoteActions()
    actions.save = { publish(controller) }
    actions.retry = {
      if case .localFailure = controller.saveState {
        controller.retryLocalSave()
      } else {
        publish(controller)
      }
    }
    actions.reconnect = {
      Task {
        await notebook.signIn()
        if notebook.account?.id == controller.draft.accountID,
          notebook.pendingAccount == nil, notebook.library.loadState == .ready
        {
          controller.didReconnect()
        }
      }
    }
    actions.selectFile = { open(gistID: controller.document.gist.id, filename: $0) }
    actions.didChangeMode = { mode in
      if mode == .source {
        controller.session.textView.becomeFirstResponder()
      } else {
        controller.session.textView.resignFirstResponder()
      }
    }
    if let gistURL {
      actions.share = {
        if controller.document.gist.isPublic {
          prepareShare()
        } else {
          showingSecretWarning = true
        }
      }
      actions.copyLink = {
        UIPasteboard.general.url = gistURL
        UIAccessibility.post(
          notification: .announcement, argument: String(localized: "Link copied"))
      }
      actions.openInGitHub = { openURL(gistURL) }
    }
    return actions
  }

  private func open(gistID: String, filename: String? = nil) {
    guard active?.session.isComposing != true, active?.session.writingToolsActive != true else {
      notebook.library.selectedNoteID = active?.document.gist.id
      actionMessage = String(
        localized: "Finish composition or Writing Tools before switching notes.")
      return
    }
    let request = UUID()
    openRequest = request
    Task {
      await notebook.open(gistID: gistID, filename: filename)
      guard request == openRequest else { return }
      await activateLoadedDocument()
    }
  }

  private func activateLoadedDocument() async {
    guard let document = notebook.loadedDocument else { return }
    if let existing = sessions[document.id] {
      activeID = existing.document.id
      compactColumn = .detail
      return
    }
    do {
      let draft = try await notebook.openDraft(for: document)
      guard !Task.isCancelled, notebook.loadedDocument?.id == document.id,
        notebook.account?.id == document.accountID
      else { return }
      sessions[document.id] = NotebookSessionController(
        document: document, draft: draft, notebook: notebook)
      activeID = document.id
      compactColumn = .detail
    } catch is CancellationError {
      return
    } catch {
      Logger(subsystem: "dev.gistpad.GistPad", category: "Document")
        .error("Draft open failed: \(String(reflecting: type(of: error)), privacy: .public)")
      actionMessage = String(
        localized:
          "This note couldn't be opened with durable local storage. Editing has not started.")
      notebook.library.selectedNoteID = active?.document.gist.id
    }
  }

  private func publish(_ controller: NotebookSessionController) {
    guard controller.canMutate else {
      actionMessage = String(
        localized: "Finish composition or Writing Tools before saving to GitHub.")
      return
    }
    Task { await controller.publish() }
  }

  private func prepareShare() {
    shareURL = gistURL
    showingShare = shareURL != nil
  }

  private func finishLocalPersistence() {
    let lease = LocalPersistenceLease()
    let documents = Array(sessions.values)
    Task {
      for document in documents { _ = await document.waitForLocalSave() }
      lease.end()
    }
  }
}

@MainActor
private final class LocalPersistenceLease {
  private var identifier = UIBackgroundTaskIdentifier.invalid

  init() {
    identifier = UIApplication.shared.beginBackgroundTask(
      withName: "Finish local draft persistence"
    ) {
      [weak self] in
      Task { @MainActor in
        Logger(subsystem: "dev.gistpad.GistPad", category: "Document")
          .error("Background time expired before local persistence finished.")
        self?.end()
      }
    }
  }

  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }
}

private struct LinkShareSheet: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
