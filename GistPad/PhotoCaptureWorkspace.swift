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
                } else if fixture.capturesDetails {
                  try await fixture.presentDetails()
                }
              }
              try await fixture.markReady()
            } catch is CancellationError {
              return
            } catch {
              self.fixture = nil
              failure = error.localizedDescription
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
          failure = error.localizedDescription
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)
      ) { notification in
        guard let fixture,
          let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
          let scene = fixture.session.session.textView.window?.windowScene
        else { return }
        fixture.keyboardHeight = max(
          0, scene.effectiveGeometry.coordinateSpace.bounds.intersection(frame).height)
      }
    }
  }

  @MainActor
  private final class PhotoCaptureFixture {
    let session: NotebookSessionController
    let photos: NotebookPhotoController
    let captureState: String
    let scrollFraction: CGFloat
    var keyboardHeight: CGFloat = 0
    private var activatedSummary = false

    var capturesInsertMenu: Bool { captureState == "insert" }
    var capturesDetails: Bool { captureState == "details" || captureState == "details-end" }

    init(
      session: NotebookSessionController, photos: NotebookPhotoController,
      captureState: String, scrollFraction: CGFloat = 1
    ) {
      self.session = session
      self.photos = photos
      self.captureState = captureState
      self.scrollFraction = scrollFraction
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
      let summary = captureState == "multiple" ? try await settledSummary() : nil
      var readiness: [String: Any] = [
        "screen": "photos", "state": captureState,
        "fixture": "offline-photos", "token": token,
        "windowWidth": window.bounds.width, "windowHeight": window.bounds.height,
        "contentSizeCategory": textView.traitCollection.preferredContentSizeCategory.rawValue,
        "sourceFocused": textView.isFirstResponder,
        "keyboardHeight": keyboardHeight,
        "photoCount": photos.displayedAttachments.count,
        "lastPhotoHasRecoveryAction": photos.displayedAttachments.last?.action != nil,
      ]
      if let summary {
        readiness["summaryFrame"] = frameValues(summary.accessibilityFrame)
        readiness["summaryLabel"] = summary.accessibilityLabel
        readiness["summaryStatus"] = summary.accessibilityValue
      }
      if captureState == "notice-end" || capturesDetails {
        let scroll = try await settledScroll(in: window)
        readiness["scrollOffset"] = scroll.contentOffset.y
        readiness["scrollContentHeight"] = scroll.contentSize.height
        readiness["scrollViewportHeight"] =
          scroll.bounds.height - scroll.adjustedContentInset.top
          - scroll.adjustedContentInset.bottom
        readiness["keyboardHeight"] = keyboardHeight
        readiness["sourceFocused"] = textView.isFirstResponder
        readiness["scrollFraction"] = scrollFraction
        readiness["scrollEndVisible"] =
          scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom
          >= scroll.contentSize.height - 1
        if capturesDetails {
          readiness["disclosureActivated"] = activatedSummary
        }
        if captureState == "details-end",
          let last = photos.displayedAttachments.last,
          let recovery = PhotoCaptureAccessibility.element(
            id: "photo-recovery-\(last.id)", in: window),
          let scene = window.windowScene
        {
          let frame = window.convert(
            recovery.accessibilityFrame, from: scene.effectiveGeometry.coordinateSpace)
          guard frame.height >= 44, frame.minY >= 0,
            frame.maxY <= window.bounds.height - window.safeAreaInsets.bottom + 1
          else { throw PhotoCaptureFailure.recoveryActionUnavailable }
          readiness["lastRecoveryFrame"] = frameValues(frame)
        } else if captureState == "details-end" {
          throw PhotoCaptureFailure.recoveryActionUnavailable
        }
      }
      let data = try JSONSerialization.data(withJSONObject: readiness, options: [.sortedKeys])
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gistpad-capture-\(token).ready")
      try data.write(to: url, options: .atomic)
    }

    func settledSummary() async throws -> NSObject {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(12))
      var previous: CGRect?
      var stableSince: ContinuousClock.Instant?
      var stableSamples = 0
      while clock.now < deadline {
        try Task.checkCancellation()
        if let window = session.session.textView.window,
          let summary = PhotoCaptureAccessibility.element(
            id: "pending-photos-summary", in: window),
          session.session.textView.isFirstResponder, keyboardHeight >= 150
        {
          let frame = summary.accessibilityFrame
          if frame.height >= 44, frame.width > 0, frame == previous {
            stableSamples += 1
            if stableSamples >= 20, let stableSince,
              stableSince.duration(to: clock.now) >= .milliseconds(350)
            {
              return summary
            }
          } else {
            stableSamples = 0
            stableSince = clock.now
          }
          previous = frame
        } else {
          previous = nil
          stableSamples = 0
          stableSince = nil
        }
        try await Task.sleep(for: .milliseconds(16))
      }
      throw PhotoCaptureFailure.summaryDidNotSettle
    }

    func presentDetails() async throws {
      let summary = try await settledSummary()
      guard PhotoCaptureAccessibility.activate(summary) else {
        throw PhotoCaptureFailure.summaryDidNotActivate
      }
      activatedSummary = true
    }

    private func frameValues(_ frame: CGRect) -> [String: CGFloat] {
      ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }

    func presentInsertMenu() async throws {
      for _ in 0..<50 {
        if let accessory = session.session.textView.inputAccessoryView,
          let insert = descendants(of: accessory).compactMap({ $0 as? UIButton }).first(where: {
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

    private func settledScroll(in window: UIWindow) async throws -> UIScrollView {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(12))
      var previous: ScrollSample?
      var stableSince: ContinuousClock.Instant?
      var stableSamples = 0
      while clock.now < deadline {
        try Task.checkCancellation()
        window.layoutIfNeeded()
        if let scroll = captureScroll(in: window) {
          let sample = ScrollSample(
            scroll: scroll, window: window, source: session.session.textView,
            keyboardHeight: keyboardHeight)
          let presentationReady = !capturesDetails || (!sample.sourceFocused && sample.keyboardHeight < 1)
          let target = -sample.insets.top + (sample.bottom + sample.insets.top) * scrollFraction
          if abs(sample.offset.y - target) > 0.5 {
            scroll.setContentOffset(
              CGPoint(x: sample.offset.x, y: target), animated: false)
            stableSamples = 0
            stableSince = nil
          } else if presentationReady, sample == previous {
            stableSamples += 1
            if stableSamples >= 20, let stableSince,
              stableSince.duration(to: clock.now) >= .milliseconds(350)
            {
              return scroll
            }
          } else {
            stableSamples = 0
            stableSince = clock.now
          }
          previous = sample
        } else {
          previous = nil
          stableSamples = 0
          stableSince = nil
        }
        try await Task.sleep(for: .milliseconds(16))
      }
      throw PhotoCaptureFailure.scrollDidNotSettle
    }

    private func captureScroll(in window: UIWindow) -> UIScrollView? {
      guard let controller = window.rootViewController?.presentedViewController,
        !controller.isBeingPresented, let container = controller.view
      else { return nil }
      let candidates = descendants(of: container).compactMap { $0 as? UIScrollView }.filter {
          let height =
            $0.bounds.height - $0.adjustedContentInset.top - $0.adjustedContentInset.bottom
          return $0 !== session.session.textView && height > 0
            && $0.contentSize.height > 0 && isVisible($0, in: window)
        }
      return candidates.count == 1 ? candidates[0] : nil
    }

    private func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
      var ancestor: UIView? = view
      while let current = ancestor {
        guard !current.isHidden, current.alpha > 0 else { return false }
        if current === window { return true }
        ancestor = current.superview
      }
      return false
    }

    private struct ScrollSample: Equatable {
      let scrollID: ObjectIdentifier
      let offset: CGPoint
      let contentSize: CGSize
      let frame: CGRect
      let insets: UIEdgeInsets
      let viewportHeight: CGFloat
      let bottom: CGFloat
      let keyboardHeight: CGFloat
      let sourceFocused: Bool

      @MainActor
      init(scroll: UIScrollView, window: UIWindow, source: UITextView, keyboardHeight: CGFloat) {
        scrollID = ObjectIdentifier(scroll)
        offset = scroll.contentOffset
        contentSize = scroll.contentSize
        frame = scroll.convert(scroll.bounds, to: window)
        insets = scroll.adjustedContentInset
        viewportHeight = scroll.bounds.height - insets.top - insets.bottom
        bottom = max(-insets.top, contentSize.height - scroll.bounds.height + insets.bottom)
        self.keyboardHeight = keyboardHeight
        sourceFocused = source.isFirstResponder
      }
    }

    private func descendants(of view: UIView) -> [UIView] {
      view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private enum PhotoCaptureFailure: LocalizedError {
      case scrollDidNotSettle
      case summaryDidNotSettle
      case summaryDidNotActivate
      case recoveryActionUnavailable

      var errorDescription: String? {
        switch self {
        case .scrollDidNotSettle:
          "The Photos sheet or requested scroll position didn't settle within 12 seconds."
        case .summaryDidNotSettle:
          "The photo summary and source keyboard didn't settle within 12 seconds."
        case .summaryDidNotActivate:
          "The native photo summary didn't handle its accessibility action."
        case .recoveryActionUnavailable:
          "The three-photo fixture couldn't prepare its synthetic failure and Retry action."
        }
      }
    }

    var actions: NoteActions {
      var value = NoteActions()
      value.didChangeMode = { [session] mode in
        if mode == .source {
          session.session.requestFocusAtContentStart()
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
        [
          "editor", "insert", "notice", "notice-end", "picker", "pending", "multiple",
          "details", "details-end", "unpublished",
        ].contains(state)
      else {
        throw ImageUploadError.targetChanged
      }
      let scrollFraction: CGFloat = state == "details" ? 0 : 1
      let multiplePhotos = ["multiple", "details", "details-end"].contains(state)
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
      if multiplePhotos {
        configuration.httpAdditionalHeaders = ["X-GistPad-Capture-Failure": "retry"]
      }
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
      case "notice", "notice-end": photos.choosePhoto()
      case "picker":
        photos.choosePhoto()
        photos.acceptNotice()
        photos.noticeDidDismiss()
      case "pending", "multiple", "details", "details-end", "unpublished":
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
        for _ in 0..<(multiplePhotos ? 3 : 1) {
          photos.choosePhoto()
          photos.acceptNotice()
          photos.noticeDidDismiss()
          photos.isShowingPicker = false
          await photos.receivePickedData(bytes)
        }
        if multiplePhotos {
          guard photos.displayedAttachments.count == 3,
            photos.displayedAttachments.last?.action == .retry
          else { throw PhotoCaptureFailure.recoveryActionUnavailable }
        }
      default: break
      }
      return PhotoCaptureFixture(
        session: session, photos: photos, captureState: state, scrollFraction: scrollFraction)
    }
  }

  @MainActor
  enum PhotoCaptureAccessibility {
    static func activate(_ element: NSObject) -> Bool {
      if let control = element as? UIControl, control.isEnabled {
        control.performPrimaryAction()
        return true
      }
      return element.accessibilityActivate()
    }

    static func element(id: String, in root: NSObject) -> NSObject? {
      var visited = Set<ObjectIdentifier>()
      return element(id: id, in: root, visited: &visited)
    }

    private static func element(
      id: String, in root: NSObject, visited: inout Set<ObjectIdentifier>
    ) -> NSObject? {
      guard visited.insert(ObjectIdentifier(root)).inserted else { return nil }
      if let view = root as? UIView, view.isHidden || view.alpha <= 0 { return nil }
      if let view = root as? UIView, view.accessibilityIdentifier == id { return view }
      if let element = root as? UIAccessibilityElement, element.accessibilityIdentifier == id {
        return element
      }
      if let identified = root as? any UIAccessibilityIdentification,
        identified.accessibilityIdentifier == id
      {
        return root
      }
      if let view = root as? UIView {
        for child in view.subviews {
          if let result = element(id: id, in: child, visited: &visited) { return result }
        }
      }
      for child in root.accessibilityElements ?? [] {
        if let child = child as? NSObject,
          let result = element(id: id, in: child, visited: &visited)
        {
          return result
        }
      }
      let count = max(0, min(500, root.accessibilityElementCount()))
      for index in 0..<count {
        if let child = root.accessibilityElement(at: index) as? NSObject,
          let result = element(id: id, in: child, visited: &visited)
        {
          return result
        }
      }
      return nil
    }
  }

  private final class OfflinePhotoCaptureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      let code: URLError.Code =
        request.value(forHTTPHeaderField: "X-GistPad-Capture-Failure") == "retry"
        ? .badServerResponse : .notConnectedToInternet
      client?.urlProtocol(self, didFailWithError: URLError(code))
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
    func discardBlankDraft(_ draft: DraftSnapshot) async throws -> Bool {
      try await store.discardBlankDraft(
        id: draft.id, accountID: draft.accountID, expectedGeneration: draft.generation)
    }
    func today(accountID: UUID, target: DailyNoteTarget) throws -> TodayNote {
      throw DraftError.notFound
    }
    func perform(_ action: NotebookAction, accountID: UUID) throws -> NotebookActionResult {
      throw DraftError.notFound
    }
  }
#endif
