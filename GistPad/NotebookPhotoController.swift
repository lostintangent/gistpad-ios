import Foundation
import GistPadEditor
import GistPadInterface
import GistPadSync
import Network
import OSLog
import Observation

struct NotebookPhotoServices: Sendable {
  let store: DraftStore
  let uploads: ImageUploadCoordinator
}

protocol NotebookPhotoProviding: Sendable {
  func photoServices(accountID: UUID) async throws -> NotebookPhotoServices
}

extension LiveNotebookProvider: NotebookPhotoProviding {
  func photoServices(accountID: UUID) async throws -> NotebookPhotoServices {
    guard try await accounts.cachedAccount()?.id == accountID else { throw AccountError.accountChanged }
    let storage = try await accounts.imageStorageClient(accountID: accountID)
    return NotebookPhotoServices(
      store: drafts, uploads: ImageUploadCoordinator(accountID: accountID, store: drafts, storage: storage))
  }
}

struct NotebookPhotoTarget: Sendable {
  let accountID: UUID
  let draftID: UUID
  let generation: UInt64
  let insertionLocation: Int
  let canInsert: Bool
}

@MainActor
@Observable
final class NotebookPhotoController {
  let accountID: UUID
  private let draftID: UUID
  private(set) var attachments: [PhotoAttachment] = []
  private var isPreparing = false
  private(set) var isShowingNotice = false
  var isShowingDetails = false
  private(set) var noticeStartsPicker = false
  var isShowingPicker = false
  var removalID: UUID?
  private(set) var queueError: String?
  @ObservationIgnored private let makeServices: @MainActor () async throws -> NotebookPhotoServices
  @ObservationIgnored private let target: @MainActor () -> NotebookPhotoTarget?
  @ObservationIgnored private let insert: @MainActor (SharedDraftCommand, DraftStore) async throws -> Void
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let reconnect: @MainActor () async -> Void
  @ObservationIgnored private let didInsert: @MainActor () -> Void
  @ObservationIgnored private let prepareQueue: @MainActor () async throws -> Void
  @ObservationIgnored private let publication: @MainActor () -> String?
  @ObservationIgnored private let preparePresentation: @MainActor () -> Void
  @ObservationIgnored private var services: NotebookPhotoServices?
  @ObservationIgnored private var servicesTask: Task<NotebookPhotoServices, any Error>?
  @ObservationIgnored private var origin: NotebookPhotoTarget?
  @ObservationIgnored private var pendingBytes: (id: UUID, data: Data, target: NotebookPhotoTarget)?
  @ObservationIgnored private var working: Set<UUID> = []
  @ObservationIgnored private var knownImages: [UUID: ImageUploadSnapshot] = [:]
  @ObservationIgnored private var thumbnails: [UUID: Data] = [:]
  @ObservationIgnored private var monitor: NWPathMonitor?
  @ObservationIgnored private var hasStarted = false
  @ObservationIgnored private var isResuming = false
  @ObservationIgnored private var isForeground = true
  @ObservationIgnored private var insertionFailures: Set<UUID> = []
  @ObservationIgnored private var isPersisting = false
  @ObservationIgnored private var picksAfterDetails = false
  @ObservationIgnored private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "Photos")

  init(
    accountID: UUID, draftID: UUID,
    services: @escaping @MainActor () async throws -> NotebookPhotoServices,
    target: @escaping @MainActor () -> NotebookPhotoTarget?,
    insert: @escaping @MainActor (SharedDraftCommand, DraftStore) async throws -> Void,
    reconnect: @escaping @MainActor () async -> Void,
    didInsert: @escaping @MainActor () -> Void = {},
    prepareQueue: @escaping @MainActor () async throws -> Void = {},
    publication: @escaping @MainActor () -> String? = { nil },
    preparePresentation: @escaping @MainActor () -> Void = {},
    defaults: UserDefaults = .standard
  ) {
    self.accountID = accountID
    self.draftID = draftID
    makeServices = services
    self.target = target
    self.insert = insert
    self.reconnect = reconnect
    self.didInsert = didInsert
    self.prepareQueue = prepareQueue
    self.publication = publication
    self.preparePresentation = preparePresentation
    self.defaults = defaults
  }

  convenience init(
    session controller: NotebookSessionController, notebook: NotebookModel,
    isCurrent: @escaping @MainActor () -> Bool,
    reconnect: @escaping @MainActor () async -> Void
  ) {
    let accountID = controller.draft.accountID
    let draftID = controller.draft.id
    self.init(
      accountID: accountID, draftID: draftID,
      services: { try await notebook.photoServices(accountID: accountID) },
      target: {
        guard isCurrent(), notebook.account?.id == accountID, notebook.pendingAccount == nil else { return nil }
        return NotebookPhotoTarget(
          accountID: accountID, draftID: draftID, generation: controller.session.generation,
          insertionLocation: NSMaxRange(controller.session.selection),
          canInsert: controller.canMutate && !controller.document.isRecovery)
      },
      insert: { command, store in
        guard isCurrent(), notebook.account?.id == accountID, notebook.pendingAccount == nil else {
          throw AccountError.accountChanged
        }
        try await controller.applyDurableEdit(command) {
          try await store.applyImageInsertion(id: command.id, accountID: accountID, command: command)
        }
      },
      reconnect: reconnect,
      didInsert: { controller.mode = .source },
      prepareQueue: {
        guard await controller.waitForLocalSave() else { throw NotebookEditError.localPersistenceFailed }
      },
      publication: { controller.draft.gistID },
      preparePresentation: { controller.session.textView.resignFirstResponder() })
  }

  var canChoosePhoto: Bool { currentTarget?.canInsert == true && !isPreparing && pendingBytes == nil }
  var hasAcknowledgedPublicStorage: Bool { defaults.bool(forKey: consentKey) }
  var publishedGistID: String? { publication() }
  var displayedAttachments: [PhotoAttachment] {
    attachments.map { attachment in
      var value = attachment
      if value.action == .insertHere {
        value.actionEnabled = currentTarget?.canInsert == true
        if !value.actionEnabled {
          value.guidance = String(localized: "Finish the current edit to insert the photo.")
        }
      }
      return value
    }
  }

  func choosePhoto() {
    guard canChoosePhoto, let currentTarget else { return }
    origin = currentTarget
    preparePresentation()
    if hasAcknowledgedPublicStorage { isShowingPicker = true }
    else {
      noticeStartsPicker = true
      isShowingNotice = true
    }
  }

  func showPrivacy() {
    preparePresentation()
    noticeStartsPicker = false
    isShowingNotice = true
  }

  func showDetails() {
    guard !attachments.isEmpty else { return }
    preparePresentation()
    isShowingDetails = true
  }

  func detailsDidDismiss() {
    guard picksAfterDetails else { return }
    picksAfterDetails = false
    choosePhoto()
  }

  func acceptNotice() {
    guard noticeStartsPicker, origin != nil else { return }
    defaults.set(true, forKey: consentKey)
    isShowingNotice = false
  }

  func dismissNotice() {
    isShowingNotice = false
    if !hasAcknowledgedPublicStorage { origin = nil }
  }

  func noticeDidDismiss() {
    if noticeStartsPicker, hasAcknowledgedPublicStorage, origin != nil, currentTarget?.canInsert == true {
      isShowingPicker = true
    }
    noticeStartsPicker = false
  }

  func beginPreparing() {
    guard origin != nil else { return }
    isPreparing = true
    attachments.removeAll { if case .preparationFailed = $0.phase { return true }; return false }
    attachments.append(PhotoAttachment(id: UUID(), phase: .preparing, canRemove: false))
  }

  func receivePickedData(_ data: Data) async {
    guard let origin else { return }
    if !isPreparing { beginPreparing() }
    let temporaryID = attachments.first { $0.phase == .preparing }?.id ?? UUID()
    do {
      let png = try await Task.detached(priority: .userInitiated) { try PhotoImage.pngData(from: data) }.value
      pendingBytes = (temporaryID, png, origin)
      await persistPreparedPhoto()
    } catch {
      preparationFailed(error)
    }
  }

  func preparationFailed(_ error: any Error) {
    log(error, operation: "prepare")
    isPreparing = false
    origin = nil
    attachments.removeAll { $0.phase == .preparing }
    attachments.append(PhotoAttachment(
      id: UUID(), phase: .preparationFailed(message: Self.preparationMessage(error)),
      action: .chooseAnother))
  }

  func pickerCancelled() {
    guard !isPreparing else { return }
    origin = nil
  }

  func start() async {
    guard !hasStarted else { return }
    isForeground = true
    hasStarted = true
    await reload()
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      guard path.status == .satisfied else { return }
      Task { @MainActor [weak self] in await self?.resume() }
    }
    monitor.start(queue: DispatchQueue(label: "dev.gistpad.photos.connectivity"))
    self.monitor = monitor
    await resume()
  }

  func stop() async {
    isForeground = false
    monitor?.cancel()
    monitor = nil
    hasStarted = false
    if let services { await services.uploads.cancelUploads() }
  }

  func resume() async {
    guard !isResuming, isForeground, hasAcknowledgedPublicStorage, currentTarget != nil else { return }
    isResuming = true
    defer { isResuming = false }
    do {
      let services = try await loadServices()
      let images = try await services.store.imageUploads(accountID: accountID)
      for image in images where image.draftID == draftID && !image.isInserted {
        guard currentTarget != nil else { return }
        if case .failed(let failure) = image.state {
          guard case .http(let status, let date) = failure,
            status == 429 || status >= 500, date == nil || date! <= .now else { continue }
        }
        if image.state == .waitingForGist,
          try await services.store.draft(id: draftID, accountID: accountID).gistID == nil { continue }
        await upload(id: image.id)
      }
      await reload()
    } catch {
      reportQueueError(error)
    }
  }

  func perform(_ action: PhotoAttachmentAction, id: UUID) async {
    switch action {
    case .chooseAnother:
      if isShowingDetails {
        picksAfterDetails = true
        isShowingDetails = false
      } else {
        choosePhoto()
      }
    case .reconnect:
      await reconnect()
      await resume()
    case .retry:
      if pendingBytes?.id == id { await persistPreparedPhoto() }
      else { await upload(id: id) }
    case .insertHere: await insertImage(id: id, atCurrentPosition: true)
    }
  }

  func removePendingPhoto() async {
    guard let id = removalID else { return }
    removalID = nil
    if pendingBytes?.id == id {
      pendingBytes = nil
      attachments.removeAll { $0.id == id }
      return
    }
    guard knownImages[id] != nil else {
      attachments.removeAll { $0.id == id }
      return
    }
    do {
      let services = try await loadServices()
      try await services.store.discardImageUpload(id: id, accountID: accountID)
      await reload()
    } catch {
      reportQueueError(error)
    }
  }

  func reload() async {
    do {
      let services = try await loadServices()
      let images = try await services.store.imageUploads(accountID: accountID)
        .filter { $0.draftID == draftID && !$0.isInserted }
      knownImages = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
      rebuildAttachments()
      var thumbnailFailed = false
      for image in images where thumbnails[image.id] == nil {
        do {
          let data = try await services.store.imageData(id: image.id, accountID: accountID)
          thumbnails[image.id] = try await Task.detached(priority: .utility) {
            try PhotoImage.thumbnailData(from: data)
          }.value
        } catch {
          thumbnailFailed = true
          reportQueueError(error)
        }
      }
      rebuildAttachments()
      if !thumbnailFailed { queueError = nil }
    } catch {
      reportQueueError(error)
    }
  }

  private var consentKey: String { "public-image-storage.\(accountID.uuidString)" }

  private var currentTarget: NotebookPhotoTarget? {
    guard let value = target(), value.accountID == accountID, value.draftID == draftID else { return nil }
    return value
  }

  private func loadServices() async throws -> NotebookPhotoServices {
    if let services { return services }
    if let servicesTask { return try await servicesTask.value }
    let task = Task { try await makeServices() }
    servicesTask = task
    defer { servicesTask = nil }
    let value = try await task.value
    services = value
    return value
  }

  private func persistPreparedPhoto() async {
    guard !isPersisting, let pendingBytes else { return }
    isPersisting = true
    defer { isPersisting = false }
    do {
      try await prepareQueue()
      let services = try await loadServices()
      let queued = try await services.store.enqueueImage(
        pngData: pendingBytes.data, draftID: draftID, accountID: accountID,
        expectedGeneration: pendingBytes.target.generation,
        insertionLocation: pendingBytes.target.insertionLocation)
      self.pendingBytes = nil
      origin = nil
      isPreparing = false
      attachments.removeAll { $0.id == pendingBytes.id }
      await reload()
      if isForeground, hasAcknowledgedPublicStorage, currentTarget != nil { await upload(id: queued.id) }
    } catch {
      isPreparing = false
      log(error, operation: "queue")
      attachments.removeAll { $0.id == pendingBytes.id }
      attachments.append(PhotoAttachment(
        id: pendingBytes.id, phase: .localFailure(message: String(localized: "Keep this note open and try again.")),
        action: .retry))
    }
  }

  private func upload(id: UUID) async {
    guard !working.contains(id), isForeground, hasAcknowledgedPublicStorage, currentTarget != nil else { return }
    working.insert(id)
    defer {
      working.remove(id)
      rebuildAttachments()
    }
    do {
      let services = try await loadServices()
      let before = try await services.store.imageUpload(id: id, accountID: accountID)
      if let index = attachments.firstIndex(where: { $0.id == id }), before.state != .uploaded {
        attachments[index].phase = before.state == .queued ? .uploading : .checking
        attachments[index].canRemove = false
        attachments[index].action = nil
      }
      let uploaded = try await services.uploads.upload(id: id)
      await reload()
      if uploaded.state == .uploaded { await insertImage(id: id, atCurrentPosition: false) }
    } catch {
      log(error, operation: "upload")
      await reload()
    }
  }

  private func insertImage(id: UUID, atCurrentPosition: Bool) async {
    guard let target = currentTarget, target.canInsert else {
      await reload()
      return
    }
    do {
      let services = try await loadServices()
      if !atCurrentPosition {
        let image = try await services.store.imageUpload(id: id, accountID: accountID)
        guard !insertionFailures.contains(id),
          image.insertionGeneration == target.generation,
          image.insertionLocation == target.insertionLocation else { return }
      }
      let command = try await services.store.imageInsertion(
        id: id, accountID: accountID,
        expectedGeneration: atCurrentPosition ? target.generation : nil,
        insertionLocation: atCurrentPosition ? target.insertionLocation : nil)
      try await insert(command, services.store)
      insertionFailures.remove(id)
      didInsert()
      await reload()
    } catch {
      log(error, operation: "insert")
      if (error as? DraftError) != .staleGeneration { insertionFailures.insert(id) }
      await reload()
    }
  }

  private func presentation(_ image: ImageUploadSnapshot) -> PhotoAttachment {
    var value = PhotoAttachment(id: image.id, thumbnail: thumbnails[image.id], phase: .queued)
    switch image.state {
    case .waitingForGist: value.phase = .waitingForNote
    case .queued: value.phase = .queued
    case .uploading:
      value.phase = .uploading
      value.canRemove = false
    case .uncertain:
      if working.contains(image.id) { value.phase = .checking }
      else {
        value.phase = .failed(
          message: String(localized: "The upload may have completed. Retry checks the stored photo first."))
        value.action = .retry
      }
    case .offline: value.phase = .offline
    case .reconnect:
      value.phase = .reconnect
      value.action = .reconnect
    case .uploaded:
      value.phase = insertionFailures.contains(image.id)
        ? .localFailure(message: String(localized: "The photo is uploaded. Try inserting it again."))
        : .ready
      value.action = .insertHere
      value.actionEnabled = currentTarget?.canInsert == true
      if !value.actionEnabled {
        value.guidance = String(localized: "Finish the current edit to insert the photo.")
      }
    case .failed(let failure):
      let retryAfter: Date?
      if case .http(_, let date) = failure { retryAfter = date } else { retryAfter = nil }
      value.phase = .failed(message: Self.failureMessage(failure), retryAfter: retryAfter)
      value.action = failure == .assetMismatch ? nil : .retry
    case .inserted: break
    }
    return value
  }

  private func rebuildAttachments() {
    let transient = attachments.filter { attachment in
      if attachment.id == pendingBytes?.id || attachment.phase == .preparing { return true }
      if case .preparationFailed = attachment.phase { return true }
      return false
    }
    attachments = transient + knownImages.values.sorted { $0.createdAt < $1.createdAt }.map(presentation)
  }

  private func reportQueueError(_ error: any Error) {
    log(error, operation: "read-queue")
    queueError = String(localized: "Pending photos couldn't be read from this iPhone. Keep this note open and retry.")
  }

  private func log(_ error: any Error, operation: String) {
    logger.error("Photo \(operation, privacy: .public) failed: \(String(reflecting: type(of: error)), privacy: .public)")
  }

  private static func preparationMessage(_ error: any Error) -> String {
    switch error as? PhotoImageError {
    case .imageTooLarge: String(localized: "Choose a photo under 50 MB and 100 megapixels.")
    case .invalidImage: String(localized: "This item couldn't be read as an image. Choose another photo.")
    default: String(localized: "The photo couldn't be loaded. Check its iCloud download and choose it again.")
    }
  }

  private static func failureMessage(_ failure: ImageUploadFailure) -> String {
    switch failure {
    case .http(let status, let retryAfter):
      if let retryAfter { return String(localized: "The image service asked us to wait until \(retryAfter.formatted(date: .omitted, time: .shortened)).") }
      return String(localized: "The image service returned error \(status). The photo remains on this iPhone.")
    case .assetMismatch: return String(localized: "The stored image did not match this photo. No link was inserted.")
    case .invalidResponse, .network: return String(localized: "The photo remains on this iPhone. Try again when the connection is available.")
    }
  }
}
