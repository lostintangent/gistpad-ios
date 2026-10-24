#if DEBUG
  import GistPadEditor
  import GistPadInterface
  import GistPadPreview
  import GistPadSync
  import SwiftUI
  import UIKit

  struct PhotoCaptureWorkspace: View {
    @State private var fixture: PhotoCaptureFixture?
    @State private var failure: String?

    var body: some View {
      Group {
        if let fixture {
          @Bindable var session = fixture.session
          NotebookPhotoHost(controller: fixture.photos) {
            NavigationStack {
              NoteScreen(
                document: session.document.chrome, mode: $session.mode,
                saveState: .inMemoryFixture, actions: fixture.actions
              ) {
                NotebookPhotoSurface(controller: fixture.photos, isSource: true) {
                  MarkdownEditorView(
                    session: session.session,
                    insertPhoto: { fixture.photos.choosePhoto() },
                    photoPrivacy: { fixture.photos.showPrivacy() },
                    canInsertPhoto: fixture.photos.canChoosePhoto)
                }
              } preview: {
                NotebookPhotoSurface(controller: fixture.photos, isSource: false) {
                  MarkdownPreviewView(
                    document: session.session.text, documentID: session.session.documentID,
                    generation: session.session.generation, allowsTaskEdits: false,
                    onEvent: { _ in })
                }
              }
            }
          }
          .task {
            do {
              if !fixture.photos.isShowingNotice, !fixture.photos.isShowingPicker {
                session.session.requestFocusAtEnd()
                if fixture.capturesInsertMenu {
                  try await fixture.presentInsertMenu()
                }
              }
              try await fixture.markReady()
            } catch is CancellationError {
              return
            } catch {
              self.fixture = nil
              failure = "The photo capture couldn't finish preparing."
            }
          }
        } else if let failure {
          ContentUnavailableView(
            "Photo fixture unavailable", systemImage: "exclamationmark.triangle",
            description: Text(failure))
        } else {
          ProgressView("Preparing isolated photo fixture")
        }
      }
      .task {
        guard fixture == nil, failure == nil else { return }
        do { fixture = try await PhotoCaptureFixture.make() } catch {
          failure = "The isolated local photo fixture couldn't be created."
        }
      }
    }
  }

  @MainActor
  private final class PhotoCaptureFixture {
    let session: NotebookSessionController
    let photos: NotebookPhotoController
    let captureState: String

    var capturesInsertMenu: Bool { captureState == "insert" }

    init(
      session: NotebookSessionController, photos: NotebookPhotoController,
      captureState: String
    ) {
      self.session = session
      self.photos = photos
      self.captureState = captureState
    }

    func markReady() async throws {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "--capture-ready-token"),
        arguments.indices.contains(index + 1),
        UUID(uuidString: arguments[index + 1]) != nil
      else { return }
      let token = arguments[index + 1]
      try await Task.sleep(for: .milliseconds(500))
      let textView = session.session.textView
      guard let window = textView.window else { throw ImageUploadError.targetChanged }
      let data = try JSONSerialization.data(
        withJSONObject: [
          "screen": "photos", "state": captureState,
          "fixture": "offline-photos", "token": token,
          "windowWidth": window.bounds.width, "windowHeight": window.bounds.height,
          "contentSizeCategory": textView.traitCollection.preferredContentSizeCategory.rawValue,
          "sourceFocused": textView.isFirstResponder,
        ], options: [.sortedKeys])
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gistpad-capture-\(token).ready")
      try data.write(to: url, options: .atomic)
    }

    func presentInsertMenu() async throws {
      func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
      }
      for _ in 0..<50 {
        if let accessory = session.session.textView.inputAccessoryView,
          let insert = descendants(accessory).compactMap({ $0 as? UIButton }).first(where: {
            $0.accessibilityIdentifier == "editor-insert-menu" && $0.window != nil
          })
        {
          // Let the keyboard finish positioning the native menu anchor.
          try await Task.sleep(for: .milliseconds(700))
          insert.performPrimaryAction()
          return
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw ImageUploadError.targetChanged
    }

    var actions: NoteActions {
      var value = NoteActions()
      value.didChangeMode = { [session] mode in
        if mode == .source {
          session.session.textView.becomeFirstResponder()
        } else {
          session.session.textView.resignFirstResponder()
        }
      }
      value.find = { [session] in
        session.mode = .source
        session.session.presentFind(replacing: true)
      }
      return value
    }

    static func make() async throws -> PhotoCaptureFixture {
      let arguments = ProcessInfo.processInfo.arguments
      let state: String
      if let index = arguments.firstIndex(of: "--capture-state"),
        arguments.indices.contains(index + 1)
      {
        state = arguments[index + 1]
      } else {
        state = "editor"
      }
      guard
        ["editor", "insert", "notice", "picker", "pending", "multiple", "unpublished"].contains(
          state)
      else {
        throw ImageUploadError.targetChanged
      }
      let accountID = UUID()
      let store = try DraftStore.open(inMemory: true)
      let text = """
        # A place for photos

        Bring an observation into the notebook.

        This is a synthetic capture note. No account is connected, and no photo can leave this fixture.
        """
      let draft: DraftSnapshot
      if state == "unpublished" {
        draft = try await store.newDraft(accountID: accountID, githubUserID: 42, text: text)
      } else {
        draft = try await store.openDraft(
          accountID: accountID, githubUserID: 42, gistID: "capture", filename: "README.md",
          description: "A place for photos", content: text, revision: "synthetic")
      }
      let session = NotebookSessionController(
        document: NotebookDocument(draft: draft), draft: draft,
        notebook: NotebookModel(provider: PhotoCaptureProvider(store: store)))
      session.mode = .source
      session.session.textView.selectedRange = NSRange(location: text.utf16.count, length: 0)
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [OfflinePhotoCaptureProtocol.self]
      let storage = try ImageStorageClient(
        publishableKey: "sb_publishable_capture", session: URLSession(configuration: configuration)
      ) { "synthetic-capture" }
      let uploads = ImageUploadCoordinator(accountID: accountID, store: store, storage: storage)
      guard let defaults = UserDefaults(suiteName: "dev.gistpad.photos.capture") else {
        throw ImageUploadError.targetChanged
      }
      let photos = NotebookPhotoController(
        accountID: accountID, draftID: draft.id,
        services: { NotebookPhotoServices(store: store, uploads: uploads) },
        target: {
          NotebookPhotoTarget(
            accountID: accountID, draftID: draft.id, generation: session.session.generation,
            insertionLocation: NSMaxRange(session.session.selection), canInsert: session.canMutate)
        },
        insert: { command, store in
          try await session.applyDurableEdit(command) {
            try await store.applyImageInsertion(
              id: command.id, accountID: accountID, command: command)
          }
        },
        reconnect: {}, didInsert: {}, prepareQueue: {}, publication: { session.draft.gistID },
        preparePresentation: { session.session.textView.resignFirstResponder() },
        defaults: defaults)
      switch state {
      case "notice": photos.choosePhoto()
      case "picker":
        photos.choosePhoto()
        photos.acceptNotice()
        photos.noticeDidDismiss()
      case "pending", "multiple", "unpublished":
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120))
        let bytes = renderer.pngData { context in
          UIColor.systemTeal.setFill()
          context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
          UIColor.systemYellow.setFill()
          UIBezierPath(ovalIn: CGRect(x: 85, y: 20, width: 42, height: 42)).fill()
          UIColor.systemIndigo.setFill()
          let mountain = UIBezierPath()
          mountain.move(to: CGPoint(x: 0, y: 120))
          mountain.addLine(to: CGPoint(x: 70, y: 45))
          mountain.addLine(to: CGPoint(x: 140, y: 120))
          mountain.close()
          mountain.fill()
        }
        for _ in 0..<(state == "multiple" ? 3 : 1) {
          photos.choosePhoto()
          photos.acceptNotice()
          photos.noticeDidDismiss()
          photos.isShowingPicker = false
          await photos.receivePickedData(bytes)
        }
      default: break
      }
      return PhotoCaptureFixture(
        session: session, photos: photos, captureState: state)
    }
  }

  private final class OfflinePhotoCaptureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
  }

  private actor PhotoCaptureProvider: NotebookProviding {
    let store: DraftStore
    init(store: DraftStore) { self.store = store }
    func cachedAccount() -> NotebookAccount? { nil }
    func signIn() throws -> NotebookAccount { throw AccountError.signedOut }
    func refreshAccount() throws -> NotebookAccount { throw AccountError.signedOut }
    func gists(accountID: UUID) -> [Gist] { [] }
    func starredGists(accountID: UUID) -> [Gist] { [] }
    func gist(id: String, accountID: UUID) throws -> Gist { throw DraftError.notFound }
    func content(gist: Gist, filename: String, accountID: UUID) throws -> String {
      throw DraftError.notFound
    }
    func openDraft(for document: NotebookDocument) throws -> DraftSnapshot {
      throw DraftError.notFound
    }
    func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) async throws
      -> DraftSnapshot
    {
      try await store.persist(id: draftID, accountID: accountID, text: text, generation: generation)
    }
    func publish(
      draftID: UUID, accountID: UUID, reason: PublishReason,
      expectedGeneration: UInt64?, shouldPublish: @escaping @Sendable () async -> Bool
    ) throws -> DraftSnapshot {
      throw DraftError.readOnly
    }
    func localState(accountID: UUID) async throws -> NotebookLocalState {
      NotebookLocalState(library: nil, drafts: try await store.drafts(accountID: accountID))
    }
    func cacheLibrary(owned: [Gist], starred: [Gist], account: NotebookAccount) {}
    func createDraft(accountID: UUID) throws -> DraftSnapshot { throw DraftError.notFound }
    func today(accountID: UUID, target: DailyNoteTarget) throws -> TodayNote {
      throw DraftError.notFound
    }
    func perform(_ action: NotebookAction, accountID: UUID) throws -> NotebookActionResult {
      throw DraftError.notFound
    }
  }
#endif
