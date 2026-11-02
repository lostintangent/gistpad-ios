import Foundation
import SwiftData

public enum PublishFailure: Codable, Equatable, Sendable {
    case network
    case http(status: Int, retryAfter: Date?)
    case readOnly
    case incompleteRemote
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
    case invalidEdit
    case publishInProgress
    case unresolvedConflict
    case readOnly
    case remoteDidNotAcknowledge
}

/// One replacement in a draft's text from outside the editor, like a widget's task check or Add to
/// Today. It lands only while the draft is still at `expectedGeneration` and `range` still holds
/// `expectedText`, so a stale or repeated edit can't change newer text.
public struct DraftEdit: Equatable, Sendable {
    public let draftID: UUID
    public let accountID: UUID
    public let expectedGeneration: UInt64
    public let range: NSRange
    public let expectedText: String
    public let replacement: String

    public init(
        draftID: UUID, accountID: UUID, expectedGeneration: UInt64,
        range: NSRange, expectedText: String, replacement: String
    ) {
        self.draftID = draftID
        self.accountID = accountID
        self.expectedGeneration = expectedGeneration
        self.range = range
        self.expectedText = expectedText
        self.replacement = replacement
    }

    func apply(to text: String) throws -> String {
        let source = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= source.length,
              range.length <= source.length - range.location,
              isScalarBoundary(range.location, in: source),
              isScalarBoundary(NSMaxRange(range), in: source),
              sourceEqual(source.substring(with: range), expectedText)
        else { throw DraftError.invalidEdit }
        return source.replacingCharacters(in: range, with: replacement)
    }

    private func isScalarBoundary(_ offset: Int, in source: NSString) -> Bool {
        guard offset > 0, offset < source.length else { return true }
        return !(0xD800...0xDBFF).contains(source.character(at: offset - 1))
            || !(0xDC00...0xDFFF).contains(source.character(at: offset))
    }
}

public enum DraftMetadataError: Error, Equatable, Sendable {
    case invalidFilename
    case filenameInUse
    case staleMetadata
    case publicationPending
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

@ModelActor
public actor DraftStore {
    public init(container: ModelContainer) throws {
        modelContainer = container
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        for draft in try context.fetch(FetchDescriptor<StoredDraft>()) {
            // A publish cut off by the app quitting resumes on the next publish, which checks GitHub first.
            if case .savingToGitHub = Self.decode(draft.stateData) {
                draft.stateData = try JSONEncoder().encode(PublishState.savedLocally)
            }
        }
        try context.save()
    }

    public static func open(url: URL? = nil, inMemory: Bool = false) throws -> DraftStore {
        let schema = Schema([StoredDraft.self, StoredLibrary.self])
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

    /// Forgets a gist deleted on GitHub, or one of its files when `filename` is set and `updated` is
    /// the gist GitHub returned without it.
    public func removeDrafts(
        gistID: String, filename: String? = nil, updated gist: Gist? = nil, accountID: UUID
    ) throws {
        for draft in try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate { $0.accountID == accountID && $0.gistID == gistID }
        )) where filename == nil || draft.filename == filename {
            modelContext.delete(draft)
        }
        try updateLibrary(accountID) { cached in
            if let filename, let gist {
                cached.owned = cached.owned.map { $0.id == gistID ? gist : $0 }
                cached.starred = cached.starred.map { $0.id == gistID ? gist : $0 }
                if cached.details[gistID] != nil { cached.details[gistID] = gist }
                cached.fileContent["\(gistID)/\(filename)"] = nil
            } else {
                cached.owned.removeAll { $0.id == gistID }
                cached.starred.removeAll { $0.id == gistID }
                cached.details[gistID] = nil
                cached.fileContent = cached.fileContent.filter { !$0.key.hasPrefix(gistID + "/") }
            }
        }
        try commit()
    }

    public func discardLocalCopy(id: UUID, accountID: UUID, expectedGeneration: UInt64) throws {
        let draft = try find(id, accountID: accountID)
        guard draft.generation == expectedGeneration else { throw DraftError.staleGeneration }
        modelContext.delete(draft)
        try commit()
    }

    /// Your draft of a gist's file, made on first open from GitHub's `content`, or from your new text
    /// when `isNewFile` says the file isn't on GitHub yet.
    public func openDraft(
        accountID: UUID, githubUserID: Int64, gistID: String, filename: String,
        description: String, content: String, revision: String? = nil, isNewFile: Bool = false
    ) throws -> DraftSnapshot {
        if let draft = try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate {
                $0.accountID == accountID && $0.gistID == gistID && $0.filename == filename
            }
        )).first { return try snapshot(draft) }
        let text = isNewFile ? content : GistConventions.decodeContent(content)
        let draft = StoredDraft(
            id: UUID(), accountID: accountID, githubUserID: githubUserID, gistID: gistID,
            filename: filename, description: description, text: text,
            baseContent: isNewFile ? nil : text, baseRevision: revision,
            stateData: try encode(isNewFile ? .savedLocally : .savedToGitHub)
        )
        modelContext.insert(draft)
        try commit()
        return try snapshot(draft)
    }

    /// Takes on GitHub's `content` when the draft has no edits of its own, and otherwise leaves it alone.
    public func refreshCleanDraft(
        id: UUID, accountID: UUID, expectedGeneration: UInt64,
        content: String, revision: String?
    ) throws -> DraftSnapshot {
        let draft = try find(id, accountID: accountID)
        guard draft.generation == expectedGeneration else { throw DraftError.staleGeneration }
        guard draft.gistID != nil, draft.attemptedGeneration == nil,
              sourceEqual(draft.text, draft.baseContent) else { return try snapshot(draft) }
        return try refreshClean(draft, content: content, revision: revision)
    }

    private func refreshClean(_ draft: StoredDraft, content: String, revision: String?) throws -> DraftSnapshot {
        let fresh = GistConventions.decodeContent(content)
        if !sourceEqual(draft.text, fresh) {
            draft.generation += 1
            draft.text = fresh
        }
        draft.baseContent = fresh
        draft.baseRevision = revision
        draft.stateData = try encode(.savedToGitHub)
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

    public func apply(_ edit: DraftEdit) throws -> DraftSnapshot {
        let draft = try find(edit.draftID, accountID: edit.accountID)
        guard draft.generation == edit.expectedGeneration else { throw DraftError.staleGeneration }
        try replaceText(draft, text: edit.apply(to: draft.text), generation: draft.generation + 1)
        try commit()
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

    /// Records what's about to be sent, so a publish cut off midway can tell whether it landed.
    /// Typing since the draft was read means a newer publish follows, so this one stops here.
    func beginAttempt(
        id: UUID, accountID: UUID, content: String, generation: UInt64
    ) throws {
        let draft = try find(id, accountID: accountID)
        guard draft.generation == generation else { throw CancellationError() }
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
        if let publishedGist {
            guard publishedGist.id == gistID else { throw DraftError.remoteDidNotAcknowledge }
            try cachePublication(
                publishedGist, accountID: accountID, githubUserID: draft.githubUserID,
                filename: draft.filename, content: content)
        }
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

    func clearAttempt(id: UUID, accountID: UUID) throws -> DraftSnapshot {
        let draft = try find(id, accountID: accountID)
        draft.attemptedContent = nil
        draft.attemptedGeneration = nil
        draft.stateData = try encode(.savedLocally)
        try commit()
        return try snapshot(draft)
    }

    func setState(_ state: PublishState, id: UUID, accountID: UUID) throws {
        let draft = try find(id, accountID: accountID)
        draft.stateData = try encode(state)
        try commit()
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
            return try refreshClean(draft, content: remote, revision: revision)
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
        draft.stateData = try encode(.savedLocally)
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
