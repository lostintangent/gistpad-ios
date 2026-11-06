import Foundation
import SwiftData

public enum PublishFailure: Codable, Equatable, Sendable {
    case network
    case http(status: Int)
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
    /// A publish in flight, which only the open file shows. The store never keeps it.
    case savingToGitHub(generation: UInt64)
    case savedToGitHub
    case reconnect
    case failed(PublishFailure)
    case conflict(DraftConflict)
}

public struct Draft: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let accountID: UUID
    public let githubUserID: Int64
    public let gistID: String?
    public let filename: String
    public let description: String
    public let text: String
    public let generation: UInt64
    /// GitHub's text when you started typing. A new gist or a new day has none.
    public let base: String?
    public let baseRevision: String?
    /// The text of a publish GitHub hasn't confirmed yet.
    public let sent: String?
    public let sentGeneration: UInt64?
    public internal(set) var state: PublishState
    public let updatedAt: Date?

    /// A note that leaving discards: a new gist that's still untitled and blank, or a day you opened
    /// and never typed in, whatever it started from. Neither has reached GitHub.
    public var isDiscardableBlank: Bool {
        guard base == nil, sent == nil, sentGeneration == nil,
              state == .savedLocally else { return false }
        if description == DailyNote.gistDescription, DailyNote.date(filename: filename) != nil {
            return generation == 0
        }
        return gistID == nil && description.isEmpty && text.allSatisfy(\.isWhitespace)
    }

    /// Whether this note has text that GitHub doesn't have yet, including a new note that was never created.
    public var hasUnpublishedEdits: Bool {
        guard !isDiscardableBlank else { return false }
        return base == nil || !sourceEqual(text, base)
    }

    /// Whether GitHub has this text: the note is published, unedited since, and no publish is waiting
    /// to be confirmed.
    public var isPublished: Bool {
        gistID != nil && sentGeneration == nil && sourceEqual(text, base)
    }

    /// Whether a published note silently takes on `remote` instead of raising a conflict.
    /// The store and the editor both use this, so they always agree on the outcome.
    public func adoptsRemote(_ remote: String) -> Bool {
        isPublished && !sourceEqual(base, remote)
    }
}

public enum DraftError: Error, Equatable, Sendable {
    case notFound
    case accountMismatch
    case staleGeneration
    case unresolvedConflict
    case readOnly
    case notConfirmed
    case invalidFilename
    case filenameInUse
    case publicationPending
}

extension DraftError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound: String(localized: "This file is no longer on this iPhone.")
        case .accountMismatch: String(localized: "This gist belongs to another GitHub account.")
        case .staleGeneration:
            String(localized: "This file changed. Review the latest version first.")
        case .unresolvedConflict:
            String(localized: "This file also changed on GitHub. Review both versions first.")
        case .readOnly: String(localized: "Only its owner can edit this gist.")
        case .notConfirmed: String(localized: "GitHub didn't confirm the change. Try again.")
        case .invalidFilename: String(localized: "Enter a filename without slashes.")
        case .filenameInUse: String(localized: "This gist already has a file with that name.")
        case .publicationPending: String(localized: "You can change this after the gist publishes.")
        }
    }
}

/// Text added to the end of a draft from outside the editor, like Add to Today. It lands only while
/// the draft is still at `expectedGeneration`, so a stale or repeated addition can't change newer text.
public struct DraftEdit: Equatable, Sendable {
    public let draftID: UUID
    public let accountID: UUID
    public let expectedGeneration: UInt64
    public let text: String

    public init(draftID: UUID, accountID: UUID, expectedGeneration: UInt64, text: String) {
        self.draftID = draftID
        self.accountID = accountID
        self.expectedGeneration = expectedGeneration
        self.text = text
    }
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
    // Earlier builds stored these under their first names.
    @Attribute(originalName: "baseContent") var base: String?
    var baseRevision: String?
    @Attribute(originalName: "attemptedContent") var sent: String?
    @Attribute(originalName: "attemptedGeneration") var sentGeneration: UInt64?
    var stateData: Data
    var updatedAt: Date? = nil

    init(
        id: UUID, accountID: UUID, githubUserID: Int64, gistID: String?,
        filename: String, description: String, text: String, base: String?,
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
        self.base = base
        self.baseRevision = baseRevision
        self.stateData = stateData
        updatedAt = .now
    }
}

@ModelActor
public actor DraftStore {
    public init(container: ModelContainer) {
        modelContainer = container
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
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
        // GistPad.entitlements gives the app's files complete protection, so drafts stay sealed
        // while the phone is locked.
        return DraftStore(container: try ModelContainer(for: schema, configurations: [configuration]))
    }

    public func drafts(accountID: UUID) throws -> [Draft] {
        try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate { $0.accountID == accountID }
        )).map(snapshot)
    }

    public func draft(id: UUID, accountID: UUID) throws -> Draft {
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
    ) throws -> Draft {
        let draft = try find(id, accountID: accountID)
        guard !filename.isEmpty, !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DraftError.invalidFilename
        }
        guard draft.filename == expectedFilename || draft.filename == filename else {
            throw DraftError.staleGeneration
        }
        guard draft.sentGeneration == nil else { throw DraftError.publicationPending }
        if let gistID = draft.gistID {
            let duplicates = try modelContext.fetch(FetchDescriptor<StoredDraft>(
                predicate: #Predicate {
                    $0.accountID == accountID && $0.gistID == gistID && $0.filename == filename
                }
            ))
            guard !duplicates.contains(where: { $0.id != id }) else { throw DraftError.filenameInUse }
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
    public func draft(
        accountID: UUID, githubUserID: Int64, gistID: String, filename: String,
        description: String, content: String, revision: String? = nil, isNewFile: Bool = false
    ) throws -> Draft {
        if let draft = try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate {
                $0.accountID == accountID && $0.gistID == gistID && $0.filename == filename
            }
        )).first { return try snapshot(draft) }
        let text = isNewFile ? content : GistFile.decodeContent(content)
        let draft = StoredDraft(
            id: UUID(), accountID: accountID, githubUserID: githubUserID, gistID: gistID,
            filename: filename, description: description, text: text,
            base: isNewFile ? nil : text, baseRevision: revision,
            stateData: try encode(.savedLocally)
        )
        modelContext.insert(draft)
        try commit()
        return try snapshot(draft)
    }

    /// Takes on GitHub's `content` when the draft has no edits of its own, and otherwise leaves it alone.
    public func refreshPublishedDraft(
        id: UUID, accountID: UUID, expectedGeneration: UInt64,
        content: String, revision: String?
    ) throws -> Draft {
        let draft = try find(id, accountID: accountID)
        guard draft.generation == expectedGeneration else { throw DraftError.staleGeneration }
        guard try snapshot(draft).isPublished else { return try snapshot(draft) }
        return try refreshPublished(draft, content: content, revision: revision)
    }

    private func refreshPublished(_ draft: StoredDraft, content: String, revision: String?) throws -> Draft {
        let fresh = GistFile.decodeContent(content)
        if !sourceEqual(draft.text, fresh) {
            draft.generation += 1
            draft.text = fresh
        }
        draft.base = fresh
        draft.baseRevision = revision
        draft.stateData = try encode(.savedLocally)
        try commit()
        return try snapshot(draft)
    }

    public func newGistDraft(
        accountID: UUID, githubUserID: Int64, filename: String = "README.md",
        description: String = "", content: String? = nil
    ) throws -> Draft {
        let text = GistFile.decodeContent(GistFile.initialContent(description: description, content: content))
        let draft = StoredDraft(
            id: UUID(), accountID: accountID, githubUserID: githubUserID, gistID: nil,
            filename: filename, description: description, text: text, base: nil,
            baseRevision: nil, stateData: try encode(.savedLocally)
        )
        modelContext.insert(draft)
        try commit()
        return try snapshot(draft)
    }

    @discardableResult
    public func persist(
        id: UUID, accountID: UUID, text: String, generation: UInt64
    ) throws -> Draft {
        let draft = try find(id, accountID: accountID)
        if generation == draft.generation, sourceEqual(text, draft.text) { return try snapshot(draft) }
        guard generation > draft.generation else { throw DraftError.staleGeneration }
        try replaceText(draft, text: text, generation: generation)
        try commit()
        return try snapshot(draft)
    }

    public func apply(_ edit: DraftEdit) throws -> Draft {
        let draft = try find(edit.draftID, accountID: edit.accountID)
        guard draft.generation == edit.expectedGeneration else { throw DraftError.staleGeneration }
        try replaceText(draft, text: draft.text + edit.text, generation: draft.generation + 1)
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
        } else {
            draft.stateData = try encode(.savedLocally)
        }
    }

    /// sent ← `content`, so the next publish or open can tell whether a publish cut off midway
    /// landed. Until one does, the note is saved on this iPhone. Typing since the draft
    /// was read means a newer publish follows, so this one stops here.
    func recordSent(
        id: UUID, accountID: UUID, content: String, generation: UInt64
    ) throws {
        let draft = try find(id, accountID: accountID)
        guard draft.generation == generation else { throw CancellationError() }
        draft.sent = content
        draft.sentGeneration = generation
        draft.stateData = try encode(.savedLocally)
        try commit()
    }

    func confirm(
        id: UUID, accountID: UUID, gistID: String, content: String,
        revision: String?, publishedGist: Gist? = nil
    ) throws -> Draft {
        let draft = try find(id, accountID: accountID)
        guard draft.gistID == nil || draft.gistID == gistID else { throw DraftError.staleGeneration }
        if let publishedGist {
            guard publishedGist.id == gistID else { throw DraftError.notConfirmed }
            try cachePublication(
                publishedGist, accountID: accountID, githubUserID: draft.githubUserID,
                filename: draft.filename, content: content)
        }
        draft.gistID = gistID
        draft.base = content
        draft.baseRevision = revision
        draft.sent = nil
        draft.sentGeneration = nil
        draft.stateData = try encode(.savedLocally)
        try commit()
        return try snapshot(draft)
    }

    /// Makes a new gist's draft a new file in `gist`, with no base. The gist joins the cached list,
    /// so the draft finds it before the next refresh even if this publish doesn't land.
    func join(_ gist: Gist, id: UUID, accountID: UUID) throws -> Draft {
        let draft = try find(id, accountID: accountID)
        draft.gistID = gist.id
        try updateLibrary(accountID) { cached in
            cached.owned.removeAll { $0.id == gist.id }
            cached.owned.insert(gist, at: 0)
        }
        try commit()
        return try snapshot(draft)
    }

    func forgetSent(id: UUID, accountID: UUID) throws -> Draft {
        let draft = try find(id, accountID: accountID)
        draft.sent = nil
        draft.sentGeneration = nil
        draft.stateData = try encode(.savedLocally)
        try commit()
        return try snapshot(draft)
    }

    func setState(_ state: PublishState, id: UUID, accountID: UUID) throws {
        let draft = try find(id, accountID: accountID)
        draft.stateData = try encode(state)
        try commit()
    }

    /// Compares GitHub's copy of the file with the draft, for a publish and for opening a note. If
    /// GitHub has the sent text or your text, it's confirmed. Any other change to GitHub's copy is a
    /// conflict, unless the note is published and can take the newer text. Sent text GitHub doesn't
    /// have is left for the next publish to forget. Typing since the draft was read means a newer
    /// publish or check follows, so this one stops here.
    public func compareWithGitHub(
        id: UUID, accountID: UUID, expectedGeneration: UInt64,
        remote: String?, revision: String?, gist: Gist? = nil
    ) throws -> Draft {
        let draft = try find(id, accountID: accountID)
        guard draft.generation == expectedGeneration else { throw CancellationError() }
        guard let gistID = draft.gistID else { return try snapshot(draft) }
        if case .conflict = Self.decode(draft.stateData) { return try snapshot(draft) }
        if let sent = draft.sent {
            guard sourceEqual(remote, sent) else { return try snapshot(draft) }
            return try confirm(
                id: id, accountID: accountID, gistID: gistID, content: sent,
                revision: revision, publishedGist: gist)
        }
        if sourceEqual(remote, draft.text) {
            return try confirm(
                id: id, accountID: accountID, gistID: gistID, content: draft.text,
                revision: revision, publishedGist: gist)
        }
        let current = try snapshot(draft)
        // A published note takes on newer text through the editor, so its undo history stays honest.
        if let remote, current.adoptsRemote(remote) { return current }
        guard !sourceEqual(remote, draft.base) else { return current }
        draft.stateData = try encode(.conflict(DraftConflict(
            generation: draft.generation, base: draft.base, local: draft.text,
            remote: remote, remoteRevision: revision)))
        try commit()
        return try snapshot(draft)
    }

    public func resolveConflict(
        id: UUID, accountID: UUID, expectedGeneration: UInt64,
        text: String, generation: UInt64
    ) throws -> Draft {
        let draft = try find(id, accountID: accountID)
        guard draft.generation == expectedGeneration,
              generation > expectedGeneration
                || (generation == expectedGeneration && sourceEqual(text, draft.text)) else {
            throw DraftError.staleGeneration
        }
        guard case .conflict(let conflict) = Self.decode(draft.stateData),
              conflict.generation == expectedGeneration else { throw DraftError.unresolvedConflict }
        draft.base = conflict.remote
        draft.baseRevision = conflict.remoteRevision
        if !sourceEqual(draft.text, text) { draft.updatedAt = .now }
        draft.text = text
        draft.generation = generation
        draft.sent = nil
        draft.sentGeneration = nil
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

    /// The draft as the app sees it. Only the states that need you are stored: a conflict, a failed
    /// publish and reconnecting. Whether it's saved to GitHub or only on this iPhone comes from its text.
    func snapshot(_ draft: StoredDraft) throws -> Draft {
        var snapshot = Draft(
            id: draft.id, accountID: draft.accountID, githubUserID: draft.githubUserID,
            gistID: draft.gistID, filename: draft.filename, description: draft.gistDescription,
            text: draft.text, generation: draft.generation,
            base: draft.base, baseRevision: draft.baseRevision,
            sent: draft.sent, sentGeneration: draft.sentGeneration,
            state: Self.decode(draft.stateData), updatedAt: draft.updatedAt
        )
        switch snapshot.state {
        case .conflict, .failed, .reconnect: break
        case .savedLocally, .savingToGitHub, .savedToGitHub:
            snapshot.state = snapshot.isPublished ? .savedToGitHub : .savedLocally
        }
        return snapshot
    }

    private func encode(_ state: PublishState) throws -> Data { try JSONEncoder().encode(state) }
    // Older builds stored states that no longer exist, such as `offline`. Those drafts have no problem.
    private static func decode(_ data: Data) -> PublishState {
        (try? JSONDecoder().decode(PublishState.self, from: data)) ?? .savedLocally
    }

    func commit() throws {
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
    }
}

/// Byte-for-byte equality, since Swift's `==` treats canonically equivalent Unicode as equal and
/// GitHub doesn't.
public func sourceEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): true
    case (.some(let lhs), .some(let rhs)): lhs.utf8.elementsEqual(rhs.utf8)
    default: false
    }
}
