import Foundation
import GistPadEditor
import GistPadInterface
import SwiftUI
import Synchronization
import Testing
import UIKit
@testable import GistPad
@testable import GistPadSync

@Suite(.serialized)
@MainActor
struct NotebookPhotoTests {
  @Test func consentCancellationAndPickerCancellationDoNotQueueOrUpload() async throws {
    let fixture = try await PhotoFixture()
    defer { fixture.cleanup() }
    let photos = fixture.photos
    photos.choosePhoto()
    #expect(photos.isShowingNotice)
    #expect(!photos.isShowingPicker)
    photos.dismissNotice()
    photos.noticeDidDismiss()
    #expect(!photos.isShowingPicker)
    #expect(!photos.hasAcknowledgedPublicStorage)
    photos.choosePhoto()
    photos.acceptNotice()
    photos.noticeDidDismiss()
    #expect(photos.isShowingPicker)
    photos.pickerCancelled()
    await photos.receivePickedData(fixture.bytes)
    #expect(try await fixture.store.imageUploads(accountID: fixture.accountID).isEmpty)
    #expect(fixture.network.requests.withLock { $0.isEmpty })

    let other = try await PhotoFixture(defaults: fixture.defaults)
    #expect(!other.photos.hasAcknowledgedPublicStorage)
  }

  @Test func preparationFailureNeverCreatesAQueueOrASavedClaim() async throws {
    let fixture = try await PhotoFixture()
    defer { fixture.cleanup() }
    fixture.authorize()
    fixture.photos.beginPreparing()
    await fixture.photos.receivePickedData(Data("invalid image".utf8))
    let row = try #require(fixture.photos.attachments.first)
    guard case .preparationFailed = row.phase else {
      Issue.record("A failed Photos load must remain a preparation failure")
      return
    }
    #expect(row.action == .chooseAnother)
    #expect(try await fixture.store.imageUploads(accountID: fixture.accountID).isEmpty)
    #expect(fixture.network.requests.withLock { $0.isEmpty })
  }

  @Test func presentingPrivacyOrThePickerEndsSourceInputBeforeShowingASheet() async throws {
    let fixture = try await PhotoFixture()
    defer { fixture.cleanup() }
    let window = try EditorContinuityTests().host(fixture.session.session)
    defer { window.isHidden = true }
    fixture.session.session.textView.becomeFirstResponder()
    #expect(fixture.session.session.textView.isFirstResponder)
    fixture.session.session.textView.selectedRange = NSRange(location: 1, length: 2)
    let selection = fixture.session.session.textView.selectedRange
    fixture.photos.choosePhoto()
    #expect(fixture.photos.isShowingNotice)
    #expect(!fixture.session.session.textView.isFirstResponder)
    #expect(fixture.session.session.textView.selectedRange == selection)
    #expect(fixture.session.session.text == "Base")
    #expect(fixture.session.session.generation == 0)
    fixture.photos.acceptNotice()
    fixture.photos.noticeDidDismiss()
    fixture.photos.pickerCancelled()
    fixture.session.session.textView.becomeFirstResponder()
    fixture.photos.choosePhoto()
    #expect(fixture.photos.isShowingPicker)
    #expect(!fixture.session.session.textView.isFirstResponder)
    fixture.photos.pickerCancelled()
    fixture.session.session.textView.becomeFirstResponder()
    fixture.photos.showPrivacy()
    #expect(!fixture.session.session.textView.isFirstResponder)
    #expect(fixture.photos.isShowingNotice)
  }

  @Test func failedLocalQueueRetainsBytesAndBlocksAnOverwritingSecondPick() async throws {
    let fixture = try await PhotoFixture()
    defer { fixture.cleanup() }
    fixture.authorize()
    fixture.queueFails = true
    await fixture.photos.receivePickedData(fixture.bytes)
    let row = try #require(fixture.photos.attachments.first)
    guard case .localFailure = row.phase else {
      Issue.record("Uncommitted image bytes cannot be described as saved")
      return
    }
    #expect(!fixture.photos.canChoosePhoto)
    #expect(try await fixture.store.imageUploads(accountID: fixture.accountID).isEmpty)
    fixture.queueFails = false
    await fixture.photos.perform(.retry, id: row.id)
    let queued = try #require(try await fixture.store.imageUploads(accountID: fixture.accountID).first)
    #expect(try await fixture.store.imageData(id: queued.id, accountID: fixture.accountID) == fixture.normalized)
    #expect(queued.state == .offline)
    #expect(fixture.session.session.text == "Base")
  }

  @Test func unpublishedAutosaveOffNoteDoesNotPublishToUploadAPhoto() async throws {
    let fixture = try await PhotoFixture(unpublished: true)
    defer { fixture.cleanup() }
    fixture.authorize()
    fixture.network.mode.withLock { $0 = .online }
    await fixture.photos.receivePickedData(fixture.bytes)
    #expect(fixture.photos.attachments.first?.phase == .waitingForNote)
    #expect(fixture.network.requests.withLock { $0.isEmpty })
    #expect(await fixture.provider.publishCount == 0)
    #expect(fixture.session.session.text == "Base")
  }

  @Test func changedCursorRequiresExplicitInsertHereAndOneUndoDoesNotReinsert() async throws {
    let fixture = try await PhotoFixture()
    defer { fixture.cleanup() }
    let window = try EditorContinuityTests().host(fixture.session.session)
    defer { window.isHidden = true }
    fixture.authorize()
    fixture.session.session.textView.selectedRange = NSRange(location: 1, length: 0)
    await fixture.photos.receivePickedData(fixture.bytes)
    #expect(fixture.photos.attachments.first?.phase == .offline)
    fixture.network.mode.withLock { $0 = .online }
    await fixture.photos.resume()
    let ready = try #require(fixture.photos.attachments.first)
    #expect(ready.phase == .ready)
    #expect(fixture.session.session.text == "Base")
    await fixture.photos.perform(.insertHere, id: ready.id)
    #expect(fixture.session.session.text.hasPrefix("B![Image]("))
    #expect(fixture.session.session.text.hasSuffix("ase"))
    #expect(fixture.photos.attachments.isEmpty)
    #expect(fixture.session.session.textView.undoManager?.canUndo == true)
    fixture.session.session.textView.undoManager?.undo()
    #expect(fixture.session.session.text == "Base")
    #expect(await fixture.session.waitForLocalSave())
    await fixture.photos.resume()
    #expect(fixture.session.session.text == "Base")
    #expect(fixture.photos.attachments.isEmpty)
    #expect(await fixture.provider.publishCount == 0)
  }

  @Test func switchedNoteOrAccountKeepsThePhotoLocalWithoutChangingAnotherEditor() async throws {
    let fixture = try await PhotoFixture()
    defer { fixture.cleanup() }
    fixture.authorize()
    fixture.isCurrent = false
    fixture.network.mode.withLock { $0 = .online }
    await fixture.photos.receivePickedData(fixture.bytes)
    await fixture.photos.resume()
    #expect(fixture.network.requests.withLock { $0.isEmpty })
    #expect(fixture.photos.attachments.first?.phase == .queued)
    #expect(fixture.session.session.text == "Base")
    #expect(try await fixture.store.imageUploads(accountID: UUID()).isEmpty)
  }

  @Test func uncertainUploadShowsRetryInsteadOfAnIdleCheckingSpinner() async throws {
    let fixture = try await PhotoFixture()
    defer { fixture.cleanup() }
    fixture.authorize()
    fixture.network.mode.withLock { $0 = .delayedVisibility }
    await fixture.photos.receivePickedData(fixture.bytes)
    let uncertain = try #require(fixture.photos.attachments.first)
    guard case .failed = uncertain.phase else {
      Issue.record("No reconciliation is running after its request returned")
      return
    }
    #expect(uncertain.action == .retry)
    fixture.network.mode.withLock { $0 = .online }
    await fixture.photos.perform(.retry, id: uncertain.id)
    #expect(fixture.photos.attachments.isEmpty)
    #expect(fixture.network.requests.withLock { $0.filter { $0 == "POST" }.count } == 1)
  }

  @Test func failedInsertionKeepsSourceAndSelectionWithAnExplicitLocalFailure() async throws {
    let fixture = try await PhotoFixture()
    defer { fixture.cleanup() }
    fixture.authorize()
    fixture.network.mode.withLock { $0 = .online }
    fixture.commitFails = true
    let selection = fixture.session.session.selection
    await fixture.photos.receivePickedData(fixture.bytes)
    let failed = try #require(fixture.photos.attachments.first)
    guard case .localFailure = failed.phase else {
      Issue.record("An uploaded image is not proof that its source insertion was saved")
      return
    }
    #expect(failed.action == .insertHere)
    #expect(fixture.session.session.text == "Base")
    #expect(fixture.session.session.selection == selection)
    #expect(fixture.session.session.generation == 0)
    fixture.commitFails = false
    await fixture.photos.perform(.insertHere, id: failed.id)
    #expect(fixture.photos.attachments.isEmpty)
    #expect(fixture.session.session.text.hasPrefix("Base![Image]("))
  }

  @Test func removingAPendingPhotoNeverSendsARemoteDelete() async throws {
    let fixture = try await PhotoFixture()
    defer { fixture.cleanup() }
    fixture.authorize()
    await fixture.photos.receivePickedData(fixture.bytes)
    let row = try #require(fixture.photos.attachments.first)
    fixture.photos.removalID = row.id
    await fixture.photos.removePendingPhoto()
    #expect(fixture.photos.attachments.isEmpty)
    #expect(try await fixture.store.imageUploads(accountID: fixture.accountID).isEmpty)
    #expect(!fixture.network.requests.withLock { $0.contains("DELETE") })
    #expect(fixture.session.session.text == "Base")
  }

  @Test func writingToolsAndRecoveryCannotPickOrInsertPhotos() async throws {
    let fixture = try await PhotoFixture()
    defer { fixture.cleanup() }
    fixture.authorize()
    await fixture.photos.receivePickedData(fixture.bytes)
    let queued = try #require(try await fixture.store.imageUploads(accountID: fixture.accountID).first)
    _ = try await fixture.store.setImageUploadState(.uploaded, id: queued.id, accountID: fixture.accountID)
    fixture.session.session.textViewWritingToolsWillBegin(fixture.session.session.textView)
    await fixture.photos.reload()
    #expect(!fixture.photos.canChoosePhoto)
    #expect(fixture.photos.displayedAttachments.first?.actionEnabled == false)
    await fixture.photos.perform(.insertHere, id: queued.id)
    #expect(fixture.session.session.text == "Base")
    fixture.session.session.textViewWritingToolsDidEnd(fixture.session.session.textView)
    #expect(fixture.photos.displayedAttachments.first?.actionEnabled == true)
    fixture.session.markRecovery()
    #expect(!fixture.photos.canChoosePhoto)
    await fixture.photos.perform(.insertHere, id: queued.id)
    #expect(fixture.session.session.text == "Base")
  }
}

@Suite(.serialized)
@MainActor
struct NotebookPhotoLayoutProbe {
  @Test(arguments: [1, 3])
  func accessibilityShelfCanScrollWithoutLosingTheEditor(photoCount: Int) async throws {
    let fixture = try await PhotoFixture()
    defer { fixture.cleanup() }
    for _ in 0..<photoCount {
      fixture.authorize()
      await fixture.photos.receivePickedData(fixture.bytes)
      fixture.photos.isShowingPicker = false
    }
    #expect(fixture.photos.attachments.count == photoCount)
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let root = NavigationStack {
      NoteScreen(
        document: fixture.session.document.chrome, mode: .constant(.source),
        saveState: .savedLocally
      ) {
        NotebookPhotoSurface(controller: fixture.photos, isSource: true) {
          MarkdownEditorView(
            session: fixture.session.session,
            insertPhoto: { fixture.photos.choosePhoto() },
            canInsertPhoto: fixture.photos.canChoosePhoto)
        }
      } preview: { Color.clear }
    }
    .environment(\.dynamicTypeSize, .accessibility3)
    let host = UIHostingController(rootView: root)
    host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(300))
    let editor = fixture.session.session.textView
    editor.becomeFirstResponder()
    try await Task.sleep(for: .milliseconds(700))
    host.view.layoutIfNeeded()
    #expect(editor.isFirstResponder)
    let accessory = try #require(editor.inputAccessoryView)
    let insertion = try #require(
      descendants(of: accessory).compactMap { $0 as? UIButton }.first {
        $0.accessibilityIdentifier == "editor-insert-menu"
      })
    let insertMenu = try #require(insertion.menu)
    let insertActions = insertMenu.children.flatMap { ($0 as? UIMenu)?.children ?? [$0] }
      .compactMap { $0 as? UIAction }
    let photo = try #require(insertActions.first { $0.title == "Photo" })
    #expect(photo.subtitle == "Public, even in a secret gist")
    #expect(!insertActions.contains { $0.title == "Photos Are Public" })
    let prefix = "photos-ax3-\(photoCount)"
    let views = descendants(of: host.view)
    let bars = views.compactMap { $0 as? UINavigationBar }
    #expect(bars.contains { bar in
      bar.interactions.contains { interaction in
        guard let edge = interaction as? UIScrollEdgeElementContainerInteraction else { return false }
        return edge.scrollView === editor && edge.edge == .top
      }
    }, "The real navigation chrome must participate in the source's native soft edge.")
    Attachment.record(
      views.map { view in
        let geometry =
          "\(type(of: view)): frame \(view.frame), bounds \(view.bounds), "
          + "hidden \(view.isHidden), alpha \(view.alpha), id \(view.accessibilityIdentifier ?? "-")"
        guard let scroll = view as? UIScrollView else { return geometry }
        return geometry + ", content \(scroll.contentSize), insets \(scroll.adjustedContentInset)"
      }.joined(separator: "\n"),
      named: "\(prefix)-hierarchy.txt")
    let scrolls = views.compactMap { $0 as? UIScrollView }
    let shelf = try #require(scrolls.first {
      $0 !== editor && !$0.isHidden && $0.bounds.height > 0
    })
    let visibleShelfHeight =
      shelf.bounds.height - shelf.adjustedContentInset.top - shelf.adjustedContentInset.bottom
    #expect(visibleShelfHeight > 0 && visibleShelfHeight <= 181)
    #expect(shelf.contentSize.height > visibleShelfHeight)
    let shelfViewport = shelf.convert(
      CGRect(
        x: shelf.bounds.minX, y: shelf.bounds.minY + shelf.adjustedContentInset.top,
        width: shelf.bounds.width, height: visibleShelfHeight), to: window)
    let image = record(window, named: "\(prefix)-shelf-top")
    if photoCount == 3 {
      let pixelRows = try thumbnailPixelRows(in: image)
      let top = max(0, Int(ceil(shelfViewport.minY * image.scale)))
      let bottom = min(pixelRows.count, Int(ceil(shelfViewport.maxY * image.scale)))
      try #require(top < bottom)
      #expect(pixelRows[top..<bottom].reduce(0, +) > 0, "The synthetic thumbnail must be rendered.")
      let below = min(pixelRows.count, bottom + Int(ceil(image.scale)))
      #expect(
        pixelRows.dropFirst(below).reduce(0, +) == 0,
        "Photo rows must not paint below the shelf's inset-adjusted viewport.")
    }
    let bottom = shelf.contentSize.height - shelf.bounds.height + shelf.adjustedContentInset.bottom
    shelf.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    try await Task.sleep(for: .milliseconds(150))
    #expect(abs(shelf.contentOffset.y - bottom) < 1)
    record(window, named: "\(prefix)-shelf-bottom")
    var visibleSourceTop = editor.bounds.minY + editor.adjustedContentInset.top
    for bar in views.compactMap({ $0 as? UINavigationBar }) where !bar.isHidden && bar.alpha > 0 {
      let rect = bar.convert(bar.bounds, to: editor)
      if rect.intersects(editor.bounds) {
        visibleSourceTop = max(visibleSourceTop, rect.maxY)
      }
    }
    let visibleSourceHeight = max(
      0, editor.bounds.maxY - editor.adjustedContentInset.bottom - visibleSourceTop)
    let twoLines = (editor.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight) * 2
    Attachment.record(
      "source unobscured viewport: \(visibleSourceHeight) pt, top: \(visibleSourceTop) pt, "
        + "two lines: \(twoLines) pt, "
        + "shelf viewport: \(visibleShelfHeight) pt, bounds: \(shelf.bounds.height) pt, "
        + "content: \(shelf.contentSize.height) pt, "
        + "scroll bottom: \(shelf.contentOffset.y) pt",
      named: "\(prefix)-geometry.txt")
    #expect(visibleSourceHeight >= twoLines, "Keep at least two source lines above the shelf and keyboard.")
    #expect(
      visibleSourceHeight >= twoLines + editor.textContainerInset.top,
      "The opening passage's top padding must not consume either writing line.")
    editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
    editor.insertText(" Still editable")
    #expect(fixture.session.session.text.hasSuffix(" Still editable"))
    #expect(editor.isFirstResponder)
    record(window, named: "\(prefix)-continued-edit")
  }

  private func descendants(of view: UIView) -> [UIView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }

  @discardableResult
  private func record(_ window: UIWindow, named name: String) -> UIImage {
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    Attachment.record(image, named: "\(name).png", as: .png)
    return image
  }

  private func thumbnailPixelRows(in image: UIImage) throws -> [Int] {
    let source = try #require(image.cgImage)
    let width = source.width
    let height = source.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
      let context = try #require(
        CGContext(
          data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (0..<height).map { row in
      (0..<width).reduce(into: 0) { count, column in
        let index = (row * width + column) * 4
        if pixels[index] < 120, pixels[index + 1] < 200, pixels[index + 2] > 200,
          pixels[index + 2] > pixels[index + 1] + 40,
          pixels[index + 1] > pixels[index] + 20, pixels[index + 3] > 200
        {
          count += 1
        }
      }
    }
  }
}

@MainActor
private final class PhotoFixture {
  let accountID = UUID()
  let store: DraftStore
  let session: NotebookSessionController
  let provider: PhotoNotebookProvider
  let defaults: UserDefaults
  let bytes: Data
  let normalized: Data
  let uploads: ImageUploadCoordinator
  let network: PhotoNetwork = PhotoNetwork()
  private let defaultsName: String?
  var queueFails = false
  var commitFails = false
  var isCurrent = true

  private var retainedPhotos: NotebookPhotoController?
  var photos: NotebookPhotoController {
    if let retainedPhotos { return retainedPhotos }
    let controller = NotebookPhotoController(
    accountID: accountID, draftID: session.draft.id,
    services: { [unowned self] in NotebookPhotoServices(store: store, uploads: uploads) },
    target: { [unowned self] in
      guard isCurrent else { return nil }
      return NotebookPhotoTarget(
        accountID: accountID, draftID: session.draft.id,
        generation: session.session.generation,
        insertionLocation: NSMaxRange(session.session.selection),
        canInsert: session.canMutate && !session.document.isRecovery)
    },
    insert: { [unowned self] command, store in
      try await session.applyDurableEdit(command) {
        if commitFails { throw URLError(.cannotWriteToFile) }
        return try await store.applyImageInsertion(id: command.id, accountID: accountID, command: command)
      }
    },
    reconnect: {},
    didInsert: {},
    prepareQueue: { [unowned self] in
      if queueFails { throw URLError(.cannotWriteToFile) }
      guard await session.waitForLocalSave() else { throw NotebookEditError.localPersistenceFailed }
    },
    publication: { nil },
    preparePresentation: { [unowned self] in session.session.textView.resignFirstResponder() },
    defaults: defaults)
    retainedPhotos = controller
    return controller
  }

  init(unpublished: Bool = false, defaults suppliedDefaults: UserDefaults? = nil) async throws {
    if let suppliedDefaults {
      defaults = suppliedDefaults
      defaultsName = nil
    } else {
      let name = "dev.gistpad.photos.tests.\(UUID().uuidString)"
      defaultsName = name
      defaults = try #require(UserDefaults(suiteName: name))
    }
    store = try DraftStore.open(inMemory: true)
    let draft: DraftSnapshot
    if unpublished {
      draft = try await store.newDraft(accountID: accountID, githubUserID: 42, text: "Base")
    } else {
      draft = try await store.openDraft(
        accountID: accountID, githubUserID: 42, gistID: "abc123", filename: "README.md",
        description: "Photo fixture", content: "Base", revision: "one")
    }
    provider = PhotoNotebookProvider(store: store)
    session = NotebookSessionController(
      document: NotebookDocument(draft: draft), draft: draft, notebook: NotebookModel(provider: provider))
    session.session.textView.selectedRange = NSRange(location: 4, length: 0)
    bytes = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { renderer in
      UIColor.systemBlue.setFill()
      renderer.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    normalized = try PhotoImage.pngData(from: bytes)
    let network = self.network
    let normalized = self.normalized
    PhotoTestURLProtocol.handler.withLock { handler in
      handler = { request in
        network.requests.withLock { $0.append(request.httpMethod ?? "") }
        let current = network.mode.withLock { $0 }
        if current == .offline { throw URLError(.notConnectedToInternet) }
        let isPublic = request.httpMethod == "GET"
        let status = isPublic && current == .delayedVisibility ? 404 : 200
        guard let url = request.url,
          let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else { throw URLError(.badServerResponse) }
        return (response, isPublic ? normalized : Data())
      }
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PhotoTestURLProtocol.self]
    let storage = try ImageStorageClient(
      publishableKey: "sb_publishable_fake", session: URLSession(configuration: configuration)
    ) { "fake-supabase-access" }
    uploads = ImageUploadCoordinator(accountID: accountID, store: store, storage: storage)
  }

  fileprivate final class PhotoNetwork: Sendable {
    enum Mode: Equatable, Sendable { case offline, online, delayedVisibility }
    let mode = Mutex(Mode.offline)
    let requests = Mutex<[String]>([])
  }

  func authorize() {
    photos.choosePhoto()
    photos.acceptNotice()
    photos.noticeDidDismiss()
  }

  func cleanup() {
    if let defaultsName { defaults.removePersistentDomain(forName: defaultsName) }
  }
}

private final class PhotoTestURLProtocol: URLProtocol {
  static let handler = Mutex<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let handler = try #require(Self.handler.withLock { $0 })
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
  override func stopLoading() {}
}

private actor PhotoNotebookProvider: NotebookProviding {
  let store: DraftStore
  private(set) var publishCount = 0
  init(store: DraftStore) { self.store = store }
  func cachedAccount() -> NotebookAccount? { nil }
  func signIn() throws -> NotebookAccount { throw AccountError.signedOut }
  func refreshAccount() throws -> NotebookAccount { throw AccountError.signedOut }
  func gists(accountID: UUID) -> [Gist] { [] }
  func starredGists(accountID: UUID) -> [Gist] { [] }
  func gist(id: String, accountID: UUID) throws -> Gist { throw DraftError.notFound }
  func content(gist: Gist, filename: String, accountID: UUID) throws -> String { throw DraftError.notFound }
  func openDraft(for document: NotebookDocument) throws -> DraftSnapshot { throw DraftError.notFound }
  func persist(draftID: UUID, accountID: UUID, text: String, generation: UInt64) async throws -> DraftSnapshot {
    try await store.persist(id: draftID, accountID: accountID, text: text, generation: generation)
  }
  func publish(
    draftID: UUID, accountID: UUID, reason: PublishReason,
    expectedGeneration: UInt64?, shouldPublish: @escaping @Sendable () async -> Bool
  ) throws -> DraftSnapshot {
    publishCount += 1
    throw DraftError.readOnly
  }
  func localState(accountID: UUID) async throws -> NotebookLocalState {
    NotebookLocalState(library: nil, drafts: try await store.drafts(accountID: accountID))
  }
  func cacheLibrary(owned: [Gist], starred: [Gist], account: NotebookAccount) {}
  func createDraft(accountID: UUID) throws -> DraftSnapshot { throw DraftError.notFound }
  func today(accountID: UUID, target: DailyNoteTarget) throws -> TodayNote { throw DraftError.notFound }
  func perform(_ action: NotebookAction, accountID: UUID) throws -> NotebookActionResult { throw DraftError.notFound }
}
