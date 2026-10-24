import Foundation
import SwiftData

public enum SaveFailure: Codable, Equatable, Sendable {
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
    public let suggestedMerge: String?
}

public enum SaveState: Codable, Equatable, Sendable {
    case savedLocally
    case savingToGitHub(generation: UInt64)
    case savedToGitHub
    case offline
    case reconnect
    case failed(SaveFailure)
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
    public let state: SaveState
}

public struct RecoverySnapshot: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let base: String?
    public let local: String
    public let remote: String?
    public let sent: String
    public let generation: UInt64
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
    public let retainedDrafts: [DraftSnapshot]
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
    }
}

@Model
final class StoredRecovery {
    @Attribute(.unique) var id: UUID
    var accountID: UUID
    var draftID: UUID
    var createdAt: Date
    var base: String?
    var local: String
    var remote: String?
    var sent: String
    var generation: UInt64

    init(draft: StoredDraft, sent: String, generation: UInt64, remote: String?) {
        id = UUID()
        accountID = draft.accountID
        draftID = draft.id
        createdAt = .now
        base = draft.baseContent
        local = draft.text
        self.remote = remote
        self.sent = sent
        self.generation = generation
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
            if case .savingToGitHub = try JSONDecoder().decode(SaveState.self, from: draft.stateData) {
                let failure: SaveFailure = draft.gistID == nil ? .creationUncertain : .publicationUncertain
                draft.stateData = try JSONEncoder().encode(SaveState.failed(failure))
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
            StoredDraft.self, StoredRecovery.self, StoredLibrary.self, StoredCommandReceipt.self, StoredImageUpload.self
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
        draft.filename = filename
        draft.gistDescription = description
        try commit()
        return try snapshot(draft)
    }

    public func removeCleanDraftsForDeletedGist(gistID: String, accountID: UUID) throws -> DeletedGistDrafts {
        let candidates = try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate { $0.accountID == accountID && $0.gistID == gistID }
        ))
        var removed: Set<UUID> = []
        var retained: [DraftSnapshot] = []
        for draft in candidates {
            let id = draft.id
            let hasRecovery = try modelContext.fetchCount(FetchDescriptor<StoredRecovery>(
                predicate: #Predicate { $0.accountID == accountID && $0.draftID == id }
            )) > 0
            let value = try snapshot(draft)
            let hasImage = try imageUploads(accountID: accountID).contains { $0.draftID == id && !$0.isInserted }
            if value.state == .savedToGitHub, value.attemptedGeneration == nil,
               sourceEqual(value.text, value.baseContent), !hasRecovery, !hasImage {
                modelContext.delete(draft)
                removed.insert(id)
            } else {
                retained.append(value)
            }
        }
        try commit()
        return DeletedGistDrafts(removedDraftIDs: removed, retainedDrafts: retained)
    }

    public func recoveries(id: UUID, accountID: UUID) throws -> [RecoverySnapshot] {
        _ = try find(id, accountID: accountID)
        return try modelContext.fetch(FetchDescriptor<StoredRecovery>(
            predicate: #Predicate { $0.accountID == accountID && $0.draftID == id },
            sortBy: [SortDescriptor(\.createdAt)]
        )).map {
            RecoverySnapshot(
                id: $0.id, createdAt: $0.createdAt, base: $0.base, local: $0.local,
                remote: $0.remote, sent: $0.sent, generation: $0.generation
            )
        }
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
        guard draft.gistID != nil, draft.attemptedGeneration == nil,
              sourceEqual(draft.text, draft.baseContent) else {
            return .preservedLocalChanges(try snapshot(draft))
        }
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
        let previousState = try decode(draft.stateData)
        draft.text = text
        draft.generation = generation
        if case .conflict(let conflict) = previousState {
            let suggestion: String?
            if let base = conflict.base, let remote = conflict.remote {
                suggestion = ThreeWayMerge.merge(base: base, local: text, remote: remote)
            } else { suggestion = nil }
            draft.stateData = try encode(.conflict(DraftConflict(
                generation: generation, base: conflict.base, local: text,
                remote: conflict.remote, remoteRevision: conflict.remoteRevision,
                suggestedMerge: suggestion
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
        id: UUID, accountID: UUID, content: String, generation: UInt64, remote: String?
    ) throws {
        let draft = try find(id, accountID: accountID)
        guard draft.attemptedGeneration == nil else { throw DraftError.publishInProgress }
        modelContext.insert(StoredRecovery(
            draft: draft, sent: content, generation: generation, remote: remote
        ))
        draft.attemptedContent = content
        draft.attemptedGeneration = generation
        draft.stateData = try encode(.savingToGitHub(generation: generation))
        try commit()
    }

    func acknowledge(
        id: UUID, accountID: UUID, gistID: String, content: String,
        revision: String?, generation: UInt64
    ) throws -> DraftSnapshot {
        let draft = try find(id, accountID: accountID)
        guard draft.gistID == nil || draft.gistID == gistID else { throw DraftError.staleGeneration }
        draft.gistID = gistID
        draft.baseContent = content
        draft.baseRevision = revision
        draft.attemptedContent = nil
        draft.attemptedGeneration = nil
        let currentIsAcknowledged = draft.generation == generation && sourceEqual(draft.text, content)
        draft.stateData = try encode(currentIsAcknowledged ? .savedToGitHub : .savedLocally)
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

    func setState(_ state: SaveState, id: UUID, accountID: UUID) throws {
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
        guard case .conflict(let conflict) = try decode(draft.stateData),
              conflict.generation == expectedGeneration,
              conflict.generation == expectedConflict.generation,
              sourceEqual(conflict.base, expectedConflict.base),
              sourceEqual(conflict.local, expectedConflict.local),
              sourceEqual(conflict.remote, expectedConflict.remote),
              sourceEqual(conflict.remoteRevision, expectedConflict.remoteRevision),
              sourceEqual(conflict.suggestedMerge, expectedConflict.suggestedMerge) else {
            throw DraftError.unresolvedConflict
        }
        let suggestion: String?
        if let base = conflict.base, let remote {
            suggestion = ThreeWayMerge.merge(base: base, local: draft.text, remote: remote)
        } else { suggestion = nil }
        draft.stateData = try encode(.conflict(DraftConflict(
            generation: expectedGeneration, base: conflict.base, local: draft.text,
            remote: remote, remoteRevision: revision, suggestedMerge: suggestion
        )))
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
        guard case .conflict(let conflict) = try decode(draft.stateData),
              conflict.generation == expectedGeneration else { throw DraftError.unresolvedConflict }
        modelContext.insert(StoredRecovery(
            draft: draft, sent: text, generation: generation, remote: conflict.remote
        ))
        draft.baseContent = conflict.remote
        draft.baseRevision = conflict.remoteRevision
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

    public func hasUnsyncedWork(accountID: UUID) throws -> Bool {
        try drafts(accountID: accountID).contains {
            $0.gistID == nil || !sourceEqual($0.text, $0.baseContent) || $0.attemptedGeneration != nil
        } || imageUploads(accountID: accountID).contains { !$0.isInserted }
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
            state: try decode(draft.stateData)
        )
    }

    private func encode(_ state: SaveState) throws -> Data { try JSONEncoder().encode(state) }
    private func decode(_ data: Data) throws -> SaveState { try JSONDecoder().decode(SaveState.self, from: data) }

    private func commit() throws {
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
