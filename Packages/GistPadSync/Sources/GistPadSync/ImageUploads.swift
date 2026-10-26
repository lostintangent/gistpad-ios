import Foundation
import SwiftData

public enum ImageInsertionFormat: String, Codable, Sendable {
    case markdown, html
}

public enum ImageUploadFailure: Codable, Equatable, Sendable {
    case http(status: Int, retryAfter: Date?)
    case network
    case assetMismatch
    case invalidResponse
}

public enum ImageUploadState: Codable, Equatable, Sendable {
    case waitingForGist
    case queued
    case uploading
    case uncertain
    case offline
    case reconnect
    case failed(ImageUploadFailure)
    case uploaded
    case inserted(generation: UInt64)
}

public enum ImageUploadError: Error, Equatable, Sendable {
    case notFound
    case uploadInProgress
    case unpublishedNote
    case notUploaded
    case invalidInsertion
    case targetChanged
    case retryDeferred(until: Date)
}

public struct ImageUploadSnapshot: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let draftID: UUID
    public let gistID: String?
    public let createdAt: Date
    public let byteCount: Int
    public let insertionGeneration: UInt64
    public let insertionLocation: Int
    public let format: ImageInsertionFormat
    public let state: ImageUploadState
    public let publicURL: URL?

    public var isInserted: Bool {
        if case .inserted = state { return true }
        return false
    }

    public var insertionText: String? {
        guard let publicURL else { return nil }
        return format == .markdown ? "![Image](\(publicURL.absoluteString))"
            : "<img src=\"\(publicURL.absoluteString)\" />"
    }
}

@Model
final class StoredImageUpload {
    @Attribute(.unique) var id: UUID
    var accountID: UUID
    var draftID: UUID
    var gistID: String?
    var createdAt: Date
    var data: Data
    var insertionGeneration: UInt64
    var insertionLocation: Int
    var format: String
    var stateData: Data
    var hasAttempted: Bool

    init(
        accountID: UUID, draft: DraftSnapshot, data: Data, insertionLocation: Int,
        insertionGeneration: UInt64, format: ImageInsertionFormat
    ) throws {
        id = UUID()
        self.accountID = accountID
        draftID = draft.id
        gistID = draft.gistID
        createdAt = .now
        self.data = data
        self.insertionGeneration = insertionGeneration
        self.insertionLocation = insertionLocation
        self.format = format.rawValue
        stateData = try JSONEncoder().encode(draft.gistID == nil ? ImageUploadState.waitingForGist : .queued)
        hasAttempted = false
    }
}

struct PendingImageTransfer: Sendable {
    let data: Data
    let gistID: String
    let reconcileFirst: Bool
}

extension DraftStore {
    public func enqueueImage(
        pngData: Data, draftID: UUID, accountID: UUID, expectedGeneration: UInt64,
        insertionLocation: Int, format: ImageInsertionFormat = .markdown
    ) throws -> ImageUploadSnapshot {
        let draft = try draft(id: draftID, accountID: accountID)
        guard expectedGeneration <= draft.generation, insertionLocation >= 0 else { throw DraftError.staleGeneration }
        if draft.generation == expectedGeneration {
            _ = try DraftSourceEdit(
                location: insertionLocation, length: 0, expectedText: "", replacement: ""
            ).apply(to: draft.text)
        }
        try PhotoImage.validatePNG(pngData)
        let image = try StoredImageUpload(
            accountID: accountID, draft: draft, data: pngData, insertionLocation: insertionLocation,
            insertionGeneration: expectedGeneration, format: format
        )
        modelContext.insert(image)
        try commit()
        return try imageSnapshot(image)
    }

    public func imageUploads(accountID: UUID) throws -> [ImageUploadSnapshot] {
        try modelContext.fetch(FetchDescriptor<StoredImageUpload>(
            predicate: #Predicate { $0.accountID == accountID },
            sortBy: [SortDescriptor(\.createdAt)]
        )).map(imageSnapshot)
    }

    public func imageUpload(id: UUID, accountID: UUID) throws -> ImageUploadSnapshot {
        try imageSnapshot(imageRecord(id: id, accountID: accountID))
    }

    public func imageData(id: UUID, accountID: UUID) throws -> Data {
        try imageRecord(id: id, accountID: accountID).data
    }

    public func imageInsertion(
        id: UUID, accountID: UUID, expectedGeneration: UInt64? = nil, insertionLocation: Int? = nil
    ) throws -> SharedDraftCommand {
        let image = try imageUpload(id: id, accountID: accountID)
        guard let text = image.insertionText else { throw ImageUploadError.notUploaded }
        let draft = try draft(id: image.draftID, accountID: accountID)
        let generation = expectedGeneration ?? image.insertionGeneration
        guard draft.generation == generation else { throw DraftError.staleGeneration }
        let edit = DraftSourceEdit(
            location: insertionLocation ?? image.insertionLocation, length: 0, expectedText: "", replacement: text
        )
        _ = try edit.apply(to: draft.text)
        return SharedDraftCommand(
            id: image.id, accountID: accountID, draftID: draft.id, expectedGeneration: generation, edit: edit
        )
    }

    public func applyImageInsertion(
        id: UUID, accountID: UUID, command: SharedDraftCommand
    ) throws -> DraftSnapshot {
        let image = try imageRecord(id: id, accountID: accountID)
        let value = try imageSnapshot(image)
        guard let text = value.insertionText, command.id == image.id, command.accountID == accountID,
              command.draftID == image.draftID, command.edit.length == 0,
              command.edit.expectedText.isEmpty, sourceEqual(command.edit.replacement, text) else {
            throw ImageUploadError.invalidInsertion
        }
        let draft = try applyCommand(command)
        image.stateData = try JSONEncoder().encode(ImageUploadState.inserted(generation: draft.generation))
        try commit()
        return draft
    }

    public func discardImageUpload(id: UUID, accountID: UUID) throws {
        let image = try imageRecord(id: id, accountID: accountID)
        guard try imageSnapshot(image).state != .uploading else { throw ImageUploadError.uploadInProgress }
        modelContext.delete(image)
        try commit()
    }

    func beginImageUpload(id: UUID, accountID: UUID) throws -> PendingImageTransfer {
        let image = try imageRecord(id: id, accountID: accountID)
        guard try imageSnapshot(image).state != .uploading else { throw ImageUploadError.uploadInProgress }
        let draft = try draft(id: image.draftID, accountID: accountID)
        guard let gistID = draft.gistID else {
            image.stateData = try JSONEncoder().encode(ImageUploadState.waitingForGist)
            try commit()
            throw ImageUploadError.unpublishedNote
        }
        guard image.gistID == nil || image.gistID == gistID else { throw ImageUploadError.targetChanged }
        let transfer = PendingImageTransfer(data: image.data, gistID: gistID, reconcileFirst: image.hasAttempted)
        image.gistID = gistID
        image.hasAttempted = true
        image.stateData = try JSONEncoder().encode(ImageUploadState.uploading)
        try commit()
        return transfer
    }

    func setImageUploadState(_ state: ImageUploadState, id: UUID, accountID: UUID) throws -> ImageUploadSnapshot {
        let image = try imageRecord(id: id, accountID: accountID)
        image.stateData = try JSONEncoder().encode(state)
        try commit()
        return try imageSnapshot(image)
    }

    private func imageRecord(id: UUID, accountID: UUID) throws -> StoredImageUpload {
        guard let image = try modelContext.fetch(FetchDescriptor<StoredImageUpload>(
            predicate: #Predicate { $0.id == id }
        )).first else { throw ImageUploadError.notFound }
        guard image.accountID == accountID else { throw DraftError.accountMismatch }
        return image
    }

    private func imageSnapshot(_ image: StoredImageUpload) throws -> ImageUploadSnapshot {
        let state = try JSONDecoder().decode(ImageUploadState.self, from: image.stateData)
        guard let format = ImageInsertionFormat(rawValue: image.format) else { throw ImageUploadError.invalidInsertion }
        let available: Bool
        switch state {
        case .uploaded, .inserted: available = true
        default: available = false
        }
        let url = try available ? image.gistID.map { try ImageStorageClient.publicURL(gistID: $0, assetID: image.id) } : nil
        return ImageUploadSnapshot(
            id: image.id, accountID: image.accountID, draftID: image.draftID, gistID: image.gistID,
            createdAt: image.createdAt, byteCount: image.data.count,
            insertionGeneration: image.insertionGeneration, insertionLocation: image.insertionLocation,
            format: format, state: state, publicURL: url
        )
    }
}

public struct ImageUploadAttempt: Sendable {
    public let id: UUID
    public let result: Result<ImageUploadSnapshot, any Error>
}

public actor ImageUploadCoordinator {
    private let accountID: UUID
    private let store: DraftStore
    private let storage: ImageStorageClient
    private var pending: [UUID: Task<ImageUploadSnapshot, any Error>] = [:]

    public init(accountID: UUID, store: DraftStore, storage: ImageStorageClient) {
        self.accountID = accountID
        self.store = store
        self.storage = storage
    }

    public func upload(id: UUID) async throws -> ImageUploadSnapshot {
        if let task = pending[id] { return try await task.value }
        let task = Task { try await performUpload(id: id) }
        pending[id] = task
        defer { pending[id] = nil }
        return try await task.value
    }

    public func cancelUploads() {
        for task in pending.values { task.cancel() }
    }

    public func resumePending() async throws -> [ImageUploadAttempt] {
        var results: [ImageUploadAttempt] = []
        for image in try await store.imageUploads(accountID: accountID) {
            try Task.checkCancellation()
            switch image.state {
            case .inserted, .uploading: continue
            case .waitingForGist:
                guard try await store.draft(id: image.draftID, accountID: accountID).gistID != nil else { continue }
            case .failed(let failure):
                guard case .http(let status, let retryAfter) = failure,
                      status == 429 || status >= 500,
                      retryAfter == nil || retryAfter! <= .now else { continue }
            default: break
            }
            do { results.append(ImageUploadAttempt(id: image.id, result: .success(try await upload(id: image.id)))) }
            catch { results.append(ImageUploadAttempt(id: image.id, result: .failure(error))) }
        }
        return results
    }

    private func performUpload(id: UUID) async throws -> ImageUploadSnapshot {
        let current = try await store.imageUpload(id: id, accountID: accountID)
        if current.state == .uploaded || current.isInserted { return current }
        try Task.checkCancellation()
        if case .failed(.http(_, let retryAfter)) = current.state, let retryAfter, retryAfter > .now {
            throw ImageUploadError.retryDeferred(until: retryAfter)
        }
        let transfer = try await store.beginImageUpload(id: id, accountID: accountID)
        do {
            _ = try await storage.upload(
                transfer.data, gistID: transfer.gistID, assetID: id, reconcileFirst: transfer.reconcileFirst
            )
            return try await store.setImageUploadState(.uploaded, id: id, accountID: accountID)
        } catch {
            let state: ImageUploadState
            if error is AccountError { state = .reconnect }
            else if let storageError = error as? ImageStorageError {
                switch storageError {
                case .http(let status, let retryAfter):
                    state = status == 401 ? .reconnect : .failed(.http(status: status, retryAfter: retryAfter))
                case .assetNotAvailable: state = .uncertain
                case .assetMismatch: state = .failed(.assetMismatch)
                default: state = .failed(.invalidResponse)
                }
            } else if let network = error as? URLError,
                      [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                       .cannotConnectToHost, .cannotFindHost, .dataNotAllowed].contains(network.code) {
                state = .offline
            } else if error is CancellationError || (error as? URLError)?.code == .cancelled { state = .uncertain }
            else { state = .failed(.network) }
            _ = try await store.setImageUploadState(state, id: id, accountID: accountID)
            throw error
        }
    }
}
