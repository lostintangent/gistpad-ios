import Foundation
import SwiftData

public enum PublishFailure: Codable, Equatable, Sendable {
    case network
    case http(status: Int, retryAfter: Date?)
    case readOnly
    case incompleteRemote
    case creationUncertain
    case publicationUncertain
}

public struct DraftConflict: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let base: String?
    public let local: String
    public let remote: String?
    public let remoteRevision: String?
}

public enum PublishState: Codable, Equatable, Sendable {
    case savedLocally
    case savingToGitHub(generation: UInt64)
    case savedToGitHub
    case reconnect
    case failed(PublishFailure)
    case conflict(DraftConflict)
}

public struct DraftSnapshot: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let accountID: UUID
    public let githubUserID: Int64
    public let gistID: String?
    public let filename: String
    public let description: String
    public let text: String
    public let generation: UInt64
    public let baseContent: String?
    public let baseRevision: String?
    public let attemptedContent: String?
    public let attemptedGeneration: UInt64?
    public let autosavePaused: Bool
    public let state: PublishState
    public let updatedAt: Date?

    public var isDiscardableBlank: Bool {
        guard baseContent == nil, baseRevision == nil, attemptedContent == nil,
              attemptedGeneration == nil, state == .savedLocally else { return false }
        if description == GistConventions.dailyNotesDescription,
           DailyNotesIndex.parseDateFilename(filename) != nil, generation == 0 {
            return text == GistConventions.dailyContent(template: nil, dateFilename: filename)
        }
        return gistID == nil && description.isEmpty && text.allSatisfy(\.isWhitespace)
    }

    /// Whether this note has text that GitHub doesn't have yet, including a new note that was never created.
    public var hasUnpublishedEdits: Bool {
        guard !isDiscardableBlank else { return false }
        return baseContent == nil || !sourceEqual(text, baseContent)
    }

    /// Whether a clean, published note silently takes on `remote` instead of raising a conflict.
    /// The store and the editor both use this, so they always agree on the outcome.
    public func adoptsRemote(_ remote: String) -> Bool {
        gistID != nil && attemptedGeneration == nil
            && sourceEqual(text, baseContent) && !sourceEqual(baseContent, remote)
    }
}

public enum DraftError: Error, Equatable, Sendable {
    case notFound
    case accountMismatch
    case staleGeneration
    case publishInProgress
    case unresolvedConflict
    case ambiguousCreation
    case readOnly
    case remoteDidNotAcknowledge
}

public enum DraftRefreshResult: Equatable, Sendable {
    case refreshed(DraftSnapshot)
    case unchanged(DraftSnapshot)
    case preservedLocalChanges(DraftSnapshot)

    public var snapshot: DraftSnapshot {
        switch self {
        case .refreshed(let draft), .unchanged(let draft), .preservedLocalChanges(let draft): draft
        }
    }
}

public enum DraftMetadataError: Error, Equatable, Sendable {
    case invalidFilename
    case filenameInUse
    case staleMetadata
    case publicationPending
}

public struct DeletedGistDrafts: Equatable, Sendable {
    public let removedDraftIDs: Set<UUID>
}

@Model
final class StoredDraft {
    @Attribute(.unique) var id: UUID
    var accountID: UUID
    var githubUserID: Int64
    var gistID: String?
    var filename: String
    var gistDescription: String
    var text: String
    var generation: UInt64
    var baseContent: String?
    var baseRevision: String?
    var attemptedContent: String?
    var attemptedGeneration: UInt64?
    var autosavePaused: Bool = false
    var stateData: Data
    var updatedAt: Date? = nil

    init(
        id: UUID, accountID: UUID, githubUserID: Int64, gistID: String?,
        filename: String, description: String, text: String, baseContent: String?,
        baseRevision: String?, stateData: Data
    ) {
        self.id = id
        self.accountID = accountID
        self.githubUserID = githubUserID
        self.gistID = gistID
        self.filename = filename
        gistDescription = description
        self.text = text
        generation = 0
        self.baseContent = baseContent
        self.baseRevision = baseRevision
        self.stateData = stateData
        updatedAt = .now
    }
}

@Model
final class StoredCommandReceipt {
    @Attribute(.unique) var id: UUID
    var payload: Data

    init(id: UUID, payload: Data) {
        self.id = id
        self.payload = payload
    }
}

@ModelActor
public actor DraftStore {
    public init(container: ModelContainer) throws {
        modelContainer = container
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        for draft in try context.fetch(FetchDescriptor<StoredDraft>()) {
            if case .savingToGitHub = Self.decode(draft.stateData) {
                let failure: PublishFailure = draft.gistID == nil ? .creationUncertain : .publicationUncertain
                draft.stateData = try JSONEncoder().encode(PublishState.failed(failure))
            }
        }
        for image in try context.fetch(FetchDescriptor<StoredImageUpload>()) {
            if try JSONDecoder().decode(ImageUploadState.self, from: image.stateData) == .uploading {
                image.stateData = try JSONEncoder().encode(ImageUploadState.uncertain)
            }
        }
        try context.save()
    }

    public static func open(url: URL? = nil, inMemory: Bool = false) throws -> DraftStore {
        let schema = Schema([
            StoredDraft.self, StoredLibrary.self, StoredCommandReceipt.self, StoredImageUpload.self
        ])
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(
                "GistPadDrafts", schema: schema, url: url, cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                "GistPadDrafts", schema: schema, isStoredInMemoryOnly: inMemory,
                groupContainer: .none, cloudKitDatabase: .none
            )
        }
        #if os(iOS)
        if !inMemory {
            let directory = configuration.url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path
            )
        }
        #endif
        let container = try ModelContainer(for: schema, configurations: [configuration])
        #if os(iOS)
        if !inMemory {
            for suffix in ["", "-wal", "-shm"] {
                let path = configuration.url.path + suffix
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.complete], ofItemAtPath: path
                    )
                }
            }
        }
        #endif
        return try DraftStore(container: container)
    }

    public func drafts(accountID: UUID) throws -> [DraftSnapshot] {
        try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate { $0.accountID == accountID }
        )).map(snapshot)
    }

    public func draft(id: UUID, accountID: UUID) throws -> DraftSnapshot {
        try snapshot(find(id, accountID: accountID))
    }

    public func discardBlankDraft(
        id: UUID, accountID: UUID, expectedGeneration: UInt64
    ) throws -> Bool {
        let draft: StoredDraft
        do {
            draft = try find(id, accountID: accountID)
        } catch DraftError.notFound {
            return false
        }
        guard draft.generation == expectedGeneration, try snapshot(draft).isDiscardableBlank else {
            return false
        }
        let hasImage = try modelContext.fetchCount(FetchDescriptor<StoredImageUpload>(
            predicate: #Predicate { $0.accountID == accountID && $0.draftID == id }
        )) > 0
        guard !hasImage else { return false }
        modelContext.delete(draft)
        try commit()
        return true
    }

    public func updateDraftMetadata(
        id: UUID, accountID: UUID, expectedFilename: String,
        filename: String, description: String
    ) throws -> DraftSnapshot {
        let draft = try find(id, accountID: accountID)
        guard !filename.isEmpty, !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DraftMetadataError.invalidFilename
        }
        guard draft.filename == expectedFilename || draft.filename == filename else {
            throw DraftMetadataError.staleMetadata
        }
        guard draft.attemptedGeneration == nil else { throw DraftMetadataError.publicationPending }
        if let gistID = draft.gistID {
            let duplicates = try modelContext.fetch(FetchDescriptor<StoredDraft>(
                predicate: #Predicate {
                    $0.accountID == accountID && $0.gistID == gistID && $0.filename == filename
                }
            ))
            guard !duplicates.contains(where: { $0.id != id }) else { throw DraftMetadataError.filenameInUse }
        }
        if !sourceEqual(draft.filename, filename) || !sourceEqual(draft.gistDescription, description) {
            draft.updatedAt = .now
        }
        draft.filename = filename
        draft.gistDescription = description
        try commit()
        return try snapshot(draft)
    }

    public func removeDraftsForDeletedGist(gistID: String, accountID: UUID) throws -> DeletedGistDrafts {
        let candidates = try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate { $0.accountID == accountID && $0.gistID == gistID }
        ))
        let removed = Set(candidates.map(\.id))
        let images = try modelContext.fetch(FetchDescriptor<StoredImageUpload>(
            predicate: #Predicate { $0.accountID == accountID }
        )).filter { $0.gistID == gistID || removed.contains($0.draftID) }
        let receipts = try modelContext.fetch(FetchDescriptor<StoredCommandReceipt>()).filter {
            let command = try JSONDecoder().decode(SharedDraftCommand.self, from: $0.payload)
            return command.accountID == accountID && removed.contains(command.draftID)
        }
        let library = try modelContext.fetch(FetchDescriptor<StoredLibrary>(
            predicate: #Predicate { $0.accountID == accountID }
        )).first
        let libraryPayload: Data?
        if let library {
            var cached = try JSONDecoder().decode(CachedLibrarySnapshot.self, from: library.payload)
            cached.owned.removeAll { $0.id == gistID }
            cached.starred.removeAll { $0.id == gistID }
            cached.details[gistID] = nil
            cached.fileContent = cached.fileContent.filter { !$0.key.hasPrefix(gistID + "/") }
            libraryPayload = try JSONEncoder().encode(cached)
        } else {
            libraryPayload = nil
        }
        for image in images { modelContext.delete(image) }
        for receipt in receipts { modelContext.delete(receipt) }
        for draft in candidates { modelContext.delete(draft) }
        if let libraryPayload { library?.payload = libraryPayload }
        try commit()
        return DeletedGistDrafts(removedDraftIDs: removed)
    }

    public func removeDraftsForDeletedFile(
        gistID: String, filename: String, updated gist: Gist, accountID: UUID
    ) throws -> DeletedGistDrafts {
        let candidates = try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate {
                $0.accountID == accountID && $0.gistID == gistID && $0.filename == filename
            }
        ))
        let removed = Set(candidates.map(\.id))
        let images = try modelContext.fetch(FetchDescriptor<StoredImageUpload>(
            predicate: #Predicate { $0.accountID == accountID }
        )).filter { removed.contains($0.draftID) }
        let receipts = try modelContext.fetch(FetchDescriptor<StoredCommandReceipt>()).filter {
            let command = try JSONDecoder().decode(SharedDraftCommand.self, from: $0.payload)
            return command.accountID == accountID && removed.contains(command.draftID)
        }
        let library = try modelContext.fetch(FetchDescriptor<StoredLibrary>(
            predicate: #Predicate { $0.accountID == accountID }
        )).first
        let libraryPayload: Data?
        if let library {
            var cached = try JSONDecoder().decode(CachedLibrarySnapshot.self, from: library.payload)
            cached.owned = cached.owned.map { $0.id == gistID ? gist : $0 }
            cached.starred = cached.starred.map { $0.id == gistID ? gist : $0 }
            if cached.details[gistID] != nil { cached.details[gistID] = gist }
            cached.fileContent[gistID + "/" + filename] = nil
            libraryPayload = try JSONEncoder().encode(cached)
        } else {
            libraryPayload = nil
        }
        for image in images { modelContext.delete(image) }
        for receipt in receipts { modelContext.delete(receipt) }
        for draft in candidates { modelContext.delete(draft) }
        if let libraryPayload { library?.payload = libraryPayload }
        try commit()
        return DeletedGistDrafts(removedDraftIDs: removed)
    }

    @discardableResult
    public func discardLocalCopy(
        id: UUID, accountID: UUID, expectedGeneration: UInt64, onlyIfClean: Bool = false
    ) throws -> Bool {
        let draft = try find(id, accountID: accountID)
        guard draft.generation == expectedGeneration else { throw DraftError.staleGeneration }
        guard draft.gistID != nil || draft.attemptedGeneration == nil else {
            throw DraftError.ambiguousCreation
        }
        if case .savingToGitHub = Self.decode(draft.stateData) { throw DraftError.publishInProgress }
        let images = try modelContext.fetch(FetchDescriptor<StoredImageUpload>(
            predicate: #Predicate { $0.accountID == accountID && $0.draftID == id }))
        if onlyIfClean {
            guard draft.attemptedGeneration == nil, sourceEqual(draft.text, draft.baseContent),
                  try images.allSatisfy({
                      if case .inserted = try JSONDecoder().decode(ImageUploadState.self, from: $0.stateData) {
                          return true
                      }
                      return false
                  }) else { return false }
        }
        let receipts = try modelContext.fetch(FetchDescriptor<StoredCommandReceipt>()).filter {
            let command = try JSONDecoder().decode(SharedDraftCommand.self, from: $0.payload)
            return command.accountID == accountID && command.draftID == id
        }
        for image in images { modelContext.delete(image) }
        for receipt in receipts { modelContext.delete(receipt) }
        modelContext.delete(draft)
        try commit()
        return true
    }

    public func openDraft(
        accountID: UUID, githubUserID: Int64, gistID: String, filename: String,
        description: String, content: String, revision: String?
    ) throws -> DraftSnapshot {
        let existing = try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate {
                $0.accountID == accountID && $0.gistID == gistID && $0.filename == filename
            }
        ))
        if let draft = existing.first { return try snapshot(draft) }
        let text = GistConventions.decodeContent(content)
        let draft = StoredDraft(
            id: UUID(), accountID: accountID, githubUserID: githubUserID, gistID: gistID,
            filename: filename, description: description, text: text, baseContent: text,
            baseRevision: revision, stateData: try encode(.savedToGitHub)
        )
        modelContext.insert(draft)
        try commit()
        return try snapshot(draft)
    }

    public func refreshCleanDraft(
        id: UUID, accountID: UUID, expectedGeneration: UInt64,
        content: String, revision: String?
    ) throws -> DraftRefreshResult {
        let draft = try find(id, accountID: accountID)
        guard draft.generation == expectedGeneration else { throw DraftError.staleGeneration }
        let current = try snapshot(draft)
        guard current.gistID != nil, current.attemptedGeneration == nil,
              sourceEqual(current.text, current.baseContent) else {
            return .preservedLocalChanges(current)
        }
        return try refreshClean(draft, content: content, revision: revision)
    }

    private func refreshClean(
        _ draft: StoredDraft, content: String, revision: String?
    ) throws -> DraftRefreshResult {
        let fresh = GistConventions.decodeContent(content)
        let changed = !sourceEqual(draft.text, fresh)
        if changed {
            guard draft.generation < UInt64.max else { throw DraftError.staleGeneration }
            draft.generation += 1
            draft.text = fresh
        }
        draft.baseContent = fresh
        draft.baseRevision = revision
        draft.stateData = try encode(.savedToGitHub)
        try commit()
        let result = try snapshot(draft)
        return changed ? .refreshed(result) : .unchanged(result)
    }

    public func newFileDraft(
        accountID: UUID, githubUserID: Int64, gistID: String,
        filename: String, description: String, text: String
    ) throws -> DraftSnapshot {
        let existing = try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate {
                $0.accountID == accountID && $0.gistID == gistID && $0.filename == filename
            }
        )).first
        if let existing { return try snapshot(existing) }
        let draft = StoredDraft(
            id: UUID(), accountID: accountID, githubUserID: githubUserID, gistID: gistID,
            filename: filename, description: description, text: text,
            baseContent: nil, baseRevision: nil, stateData: try encode(.savedLocally)
        )
        modelContext.insert(draft)
        try commit()
        return try snapshot(draft)
    }

    public func createGistDraft(
        accountID: UUID, githubUserID: Int64, filename: String = "README.md",
        description: String = "", content: String? = nil
    ) throws -> DraftSnapshot {
        try newDraft(
            accountID: accountID, githubUserID: githubUserID, filename: filename,
            description: description,
            text: GistConventions.decodeContent(
                GistConventions.initialContent(description: description, content: content)
            )
        )
    }

    public func dailyGistDraft(
        accountID: UUID, githubUserID: Int64, target: DailyNoteTarget
    ) throws -> DraftSnapshot {
        let drafts = try drafts(accountID: accountID)
        if let pending = drafts.first(where: {
            $0.gistID == nil && $0.description == GistConventions.dailyNotesDescription
        }) {
            guard pending.filename == target.filename else {
                throw DailyNotesError.pendingCreation(draftID: pending.id)
            }
            return pending
        }
        return try createGistDraft(
            accountID: accountID, githubUserID: githubUserID, filename: target.filename,
            description: GistConventions.dailyNotesDescription,
            content: GistConventions.dailyContent(template: nil, dateFilename: target.filename)
        )
    }

    public func newDraft(
        accountID: UUID, githubUserID: Int64, filename: String = "README.md",
        description: String = "", text: String = ""
    ) throws -> DraftSnapshot {
        let draft = StoredDraft(
            id: UUID(), accountID: accountID, githubUserID: githubUserID, gistID: nil,
            filename: filename, description: description, text: text, baseContent: nil,
            baseRevision: nil, stateData: try encode(.savedLocally)
        )
        modelContext.insert(draft)
        try commit()
        return try snapshot(draft)
    }

    @discardableResult
    public func persist(
        id: UUID, accountID: UUID, text: String, generation: UInt64
    ) throws -> DraftSnapshot {
        let draft = try find(id, accountID: accountID)
        if generation == draft.generation, sourceEqual(text, draft.text) { return try snapshot(draft) }
        guard generation > draft.generation else { throw DraftError.staleGeneration }
        try replaceText(draft, text: text, generation: generation)
        try commit()
        return try snapshot(draft)
    }

    public func apply(_ command: SharedDraftCommand) throws -> DraftSnapshot {
        let result = try applyCommand(command)
        try commit()
        return result
    }

    func applyCommand(_ command: SharedDraftCommand) throws -> DraftSnapshot {
        let draft = try find(command.draftID, accountID: command.accountID)
        let id = command.id
        let payload = try encodedCommand(command)
        if let receipt = try modelContext.fetch(FetchDescriptor<StoredCommandReceipt>(
            predicate: #Predicate { $0.id == id }
        )).first {
            guard receipt.payload == payload else { throw SharedStoreError.duplicateCommand }
            return try snapshot(draft)
        }
        guard draft.generation == command.expectedGeneration, draft.generation < UInt64.max else {
            throw DraftError.staleGeneration
        }
        let text = try command.edit.apply(to: draft.text)
        try replaceText(draft, text: text, generation: draft.generation + 1)
        modelContext.insert(StoredCommandReceipt(id: id, payload: payload))
        return try snapshot(draft)
    }

    private func replaceText(_ draft: StoredDraft, text: String, generation: UInt64) throws {
        let previousState = Self.decode(draft.stateData)
        if !sourceEqual(draft.text, text) { draft.updatedAt = .now }
        draft.text = text
        draft.generation = generation
        if case .conflict(let conflict) = previousState {
            draft.stateData = try encode(.conflict(DraftConflict(
                generation: generation, base: conflict.base, local: text,
                remote: conflict.remote, remoteRevision: conflict.remoteRevision
            )))
        } else if let sent = draft.attemptedGeneration, case .savingToGitHub = previousState {
            draft.stateData = try encode(.savingToGitHub(generation: sent))
        } else if draft.attemptedGeneration != nil {
            draft.stateData = try encode(previousState)
        } else {
            draft.stateData = try encode(
                draft.gistID != nil && sourceEqual(text, draft.baseContent)
                    ? .savedToGitHub : .savedLocally
            )
        }
    }

    func beginAttempt(
        id: UUID, accountID: UUID, content: String, generation: UInt64
    ) throws {
        let draft = try find(id, accountID: accountID)
        guard draft.attemptedGeneration == nil else { throw DraftError.publishInProgress }
        draft.attemptedContent = content
        draft.attemptedGeneration = generation
        draft.stateData = try encode(.savingToGitHub(generation: generation))
        try commit()
    }

    func acknowledge(
        id: UUID, accountID: UUID, gistID: String, content: String,
        revision: String?, generation: UInt64, publishedGist: Gist? = nil
    ) throws -> DraftSnapshot {
        let draft = try find(id, accountID: accountID)
        guard draft.gistID == nil || draft.gistID == gistID else { throw DraftError.staleGeneration }
        let publicationCache: (StoredLibrary, Data)?
        if let publishedGist {
            guard publishedGist.id == gistID else { throw DraftError.remoteDidNotAcknowledge }
            publicationCache = try self.publicationCache(
                gist: publishedGist, accountID: accountID, githubUserID: draft.githubUserID,
                filename: draft.filename, content: content)
        } else {
            publicationCache = nil
        }
        draft.gistID = gistID
        draft.baseContent = content
        draft.baseRevision = revision
        draft.attemptedContent = nil
        draft.attemptedGeneration = nil
        let currentIsAcknowledged = draft.generation == generation && sourceEqual(draft.text, content)
        draft.stateData = try encode(currentIsAcknowledged ? .savedToGitHub : .savedLocally)
        if let (record, payload) = publicationCache { record.payload = payload }
        try commit()
        return try snapshot(draft)
    }

    func clearAttempt(id: UUID, accountID: UUID) throws {
        let draft = try find(id, accountID: accountID)
        draft.attemptedContent = nil
        draft.attemptedGeneration = nil
        draft.stateData = try encode(.savedLocally)
        try commit()
    }

    public func confirmNewCreation(
        id: UUID, accountID: UUID, expectedGeneration: UInt64
    ) throws -> DraftSnapshot {
        _ = try uncertainCreation(id: id, accountID: accountID, expectedGeneration: expectedGeneration)
        try clearAttempt(id: id, accountID: accountID)
        return try snapshot(find(id, accountID: accountID))
    }

    public func discardUncertainCreation(
        id: UUID, accountID: UUID, expectedGeneration: UInt64
    ) throws {
        let draft = try uncertainCreation(
            id: id, accountID: accountID, expectedGeneration: expectedGeneration)
        let images = try modelContext.fetch(FetchDescriptor<StoredImageUpload>(
            predicate: #Predicate { $0.accountID == accountID && $0.draftID == id }))
        for image in images {
            guard try JSONDecoder().decode(ImageUploadState.self, from: image.stateData) != .uploading else {
                throw ImageUploadError.uploadInProgress
            }
        }
        let receipts = try modelContext.fetch(FetchDescriptor<StoredCommandReceipt>()).filter {
            let command = try JSONDecoder().decode(SharedDraftCommand.self, from: $0.payload)
            return command.accountID == accountID && command.draftID == id
        }
        for image in images { modelContext.delete(image) }
        for receipt in receipts { modelContext.delete(receipt) }
        modelContext.delete(draft)
        try commit()
    }

    private func uncertainCreation(
        id: UUID, accountID: UUID, expectedGeneration: UInt64
    ) throws -> StoredDraft {
        let draft = try find(id, accountID: accountID)
        guard draft.generation == expectedGeneration else { throw DraftError.staleGeneration }
        guard draft.gistID == nil, draft.attemptedGeneration != nil,
              case .failed(.creationUncertain) = Self.decode(draft.stateData) else {
            throw DraftError.ambiguousCreation
        }
        return draft
    }

    func setState(_ state: PublishState, id: UUID, accountID: UUID) throws {
        let draft = try find(id, accountID: accountID)
        draft.stateData = try encode(state)
        try commit()
    }

    public func refreshConflict(
        id: UUID, accountID: UUID, expectedGeneration: UInt64,
        expectedConflict: DraftConflict, remote: String?, revision: String?
    ) throws -> DraftSnapshot {
        let draft = try find(id, accountID: accountID)
        guard draft.generation == expectedGeneration else { throw DraftError.staleGeneration }
        guard case .conflict(let conflict) = Self.decode(draft.stateData),
              conflict.generation == expectedGeneration,
              conflict.generation == expectedConflict.generation,
              sourceEqual(conflict.base, expectedConflict.base),
              sourceEqual(conflict.local, expectedConflict.local),
              sourceEqual(conflict.remote, expectedConflict.remote),
              sourceEqual(conflict.remoteRevision, expectedConflict.remoteRevision) else {
            throw DraftError.unresolvedConflict
        }
        draft.stateData = try encode(.conflict(DraftConflict(
            generation: expectedGeneration, base: conflict.base, local: draft.text,
            remote: remote, remoteRevision: revision
        )))
        try commit()
        return try snapshot(draft)
    }

    public func inspectRemoteChange(
        id: UUID, accountID: UUID, expectedGeneration: UInt64,
        remote: String?, revision: String?
    ) throws -> DraftSnapshot {
        let draft = try find(id, accountID: accountID)
        guard draft.generation == expectedGeneration else { throw DraftError.staleGeneration }
        let state = Self.decode(draft.stateData)
        if case .conflict = state { return try snapshot(draft) }
        if let generation = draft.attemptedGeneration {
            if case .savingToGitHub = state { throw DraftError.publishInProgress }
            guard let gistID = draft.gistID, let attempted = draft.attemptedContent,
                  sourceEqual(remote, attempted) else { return try snapshot(draft) }
            return try acknowledge(
                id: id, accountID: accountID, gistID: gistID, content: attempted,
                revision: revision, generation: generation)
        }
        guard !sourceEqual(draft.baseContent, remote) else { return try snapshot(draft) }
        if let remote, try snapshot(draft).adoptsRemote(remote) {
            return try refreshClean(draft, content: remote, revision: revision).snapshot
        }
        draft.stateData = try encode(.conflict(DraftConflict(
            generation: draft.generation, base: draft.baseContent, local: draft.text,
            remote: remote, remoteRevision: revision)))
        try commit()
        return try snapshot(draft)
    }

    public func resolveConflict(
        id: UUID, accountID: UUID, expectedGeneration: UInt64,
        text: String, generation: UInt64
    ) throws -> DraftSnapshot {
        let draft = try find(id, accountID: accountID)
        guard draft.generation == expectedGeneration,
              generation > expectedGeneration
                || (generation == expectedGeneration && sourceEqual(text, draft.text)) else {
            throw DraftError.staleGeneration
        }
        guard case .conflict(let conflict) = Self.decode(draft.stateData),
              conflict.generation == expectedGeneration else { throw DraftError.unresolvedConflict }
        draft.baseContent = conflict.remote
        draft.baseRevision = conflict.remoteRevision
        if !sourceEqual(draft.text, text) { draft.updatedAt = .now }
        draft.text = text
        draft.generation = generation
        draft.attemptedContent = nil
        draft.attemptedGeneration = nil
        draft.autosavePaused = true
        draft.stateData = try encode(.savedLocally)
        try commit()
        return try snapshot(draft)
    }

    public func resumeAutosave(id: UUID, accountID: UUID) throws -> DraftSnapshot {
        let draft = try find(id, accountID: accountID)
        draft.autosavePaused = false
        try commit()
        return try snapshot(draft)
    }


    private func find(_ id: UUID, accountID: UUID) throws -> StoredDraft {
        guard let draft = try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate { $0.id == id }
        )).first else { throw DraftError.notFound }
        guard draft.accountID == accountID else { throw DraftError.accountMismatch }
        return draft
    }

    private func snapshot(_ draft: StoredDraft) throws -> DraftSnapshot {
        DraftSnapshot(
            id: draft.id, accountID: draft.accountID, githubUserID: draft.githubUserID,
            gistID: draft.gistID, filename: draft.filename, description: draft.gistDescription,
            text: draft.text, generation: draft.generation,
            baseContent: draft.baseContent, baseRevision: draft.baseRevision,
            attemptedContent: draft.attemptedContent, attemptedGeneration: draft.attemptedGeneration,
            autosavePaused: draft.autosavePaused,
            state: Self.decode(draft.stateData), updatedAt: draft.updatedAt
        )
    }

    private func encode(_ state: PublishState) throws -> Data { try JSONEncoder().encode(state) }
    // Older builds stored states that no longer exist, such as `offline`. Those drafts are simply unpublished.
    private static func decode(_ data: Data) -> PublishState {
        (try? JSONDecoder().decode(PublishState.self, from: data)) ?? .savedLocally
    }

    func commit() throws {
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
    }
}

func sourceEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): true
    case (.some(let lhs), .some(let rhs)): lhs.utf8.elementsEqual(rhs.utf8)
    default: false
    }
}
