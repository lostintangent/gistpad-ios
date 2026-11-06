import CryptoKit
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
    public internal(set) var filename: String
    public let description: String
    public internal(set) var text: String
    public internal(set) var generation: UInt64
    /// GitHub's text when you started typing. A new gist or a new day has none.
    public internal(set) var base: String?
    public internal(set) var baseRevision: String?
    /// The text of a publish GitHub hasn't confirmed yet.
    public let sent: String?
    public let sentGeneration: UInt64?
    public internal(set) var state: PublishState
    public let updatedAt: Date?
    /// Whether this iPhone stores the draft, which it does from your first keystroke until GitHub has
    /// your text.
    public internal(set) var isSaved = false

    /// Whether this note has text that GitHub doesn't have yet, including a new note that was never created.
    public var hasUnpublishedEdits: Bool { isSaved && !isPublished }

    /// Whether GitHub has this text: the note is published, unedited since, and no publish is waiting
    /// to be confirmed.
    public var isPublished: Bool {
        gistID != nil && sentGeneration == nil && sourceEqual(text, base)
    }

    /// Whether there's nothing here to keep: GitHub has the text, or it's a new gist without a name or
    /// any writing. A conflict always waits for you.
    var isDisposable: Bool {
        if case .conflict = state { return false }
        return isPublished
            || gistID == nil && sentGeneration == nil && description.isEmpty && text.allSatisfy(\.isWhitespace)
    }

    /// GitHub's newer `remote`, as the next generation of a note you haven't typed in.
    public func adopting(_ remote: String, revision: String?) -> Draft {
        var adopted = self
        if !sourceEqual(text, remote) { adopted.generation += 1 }
        adopted.text = remote
        adopted.base = remote
        adopted.baseRevision = revision
        adopted.state = .savedToGitHub
        return adopted
    }

    /// The note under the name GitHub now gives its file.
    public func renamed(_ filename: String) -> Draft {
        var renamed = self
        renamed.filename = filename
        return renamed
    }
}

extension Draft {
    /// A note before you type in it: a gist's file as GitHub has it, a new day, or a new gist. Every
    /// copy of a file or a day shares one identity, so the draft your typing stores is the same one
    /// wherever you type. Each new gist is its own.
    public init(
        accountID: UUID, githubUserID: Int64, gistID: String? = nil, filename: String = "README.md",
        description: String = "", text: String = "", base: String? = nil, baseRevision: String? = nil
    ) {
        let file = gistID ?? (description == DailyNote.gistDescription ? description : nil)
        self.init(
            id: file.map { UUID(naming: "\(accountID)/\($0)/\(filename)") } ?? UUID(),
            accountID: accountID, githubUserID: githubUserID, gistID: gistID, filename: filename,
            description: description, text: text, generation: 0, base: base, baseRevision: baseRevision,
            sent: nil, sentGeneration: nil, state: .savedLocally, updatedAt: nil)
        if isPublished { state = .savedToGitHub }
    }

    /// A gist's file as GitHub has it.
    public init(accountID: UUID, githubUserID: Int64, gist: Gist, filename: String, text: String) {
        self.init(
            accountID: accountID, githubUserID: githubUserID, gistID: gist.id, filename: filename,
            description: gist.description ?? "", text: text, base: text, baseRevision: gist.revision)
    }

    /// A new gist called `description`, starting with `content` or else the web's heading for its name.
    public init(accountID: UUID, githubUserID: Int64, description: String, content: String?) {
        self.init(
            accountID: accountID, githubUserID: githubUserID, description: description,
            text: GistFile.decodeContent(GistFile.initialContent(description: description, content: content)))
    }
}

extension UUID {
    /// The same UUID for the same name.
    init(naming name: String) {
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x80
        bytes[8] = bytes[8] & 0x3F | 0x80
        self = (NSUUID(uuidBytes: bytes) as UUID)
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
        case .publicationPending: String(localized: "You can change this after the gist publishes.")
        }
    }
}

/// Text added to the end of a draft from outside the editor, like Add to Today. It lands only while
/// the draft is still as `draft` has it, so a stale or repeated addition can't change newer text.
public struct DraftEdit: Equatable, Sendable {
    public let draft: Draft
    public let text: String

    public init(draft: Draft, text: String) {
        self.draft = draft
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
    /// Drafts a publish let go of, so typing that was already on its way continues from what GitHub has.
    private var released: [UUID: Draft] = [:]

    public init(container: ModelContainer) {
        modelContainer = container
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // Earlier builds kept a draft for every note you opened, every day they started and every
        // note they published.
        for row in (try? context.fetch(FetchDescriptor<StoredDraft>())) ?? []
        where Self.snapshot(row).isDisposable
            || row.generation == 0 && row.base == nil && row.gistDescription == DailyNote.gistDescription {
            context.delete(row)
        }
        try? context.save()
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
        )).map(Self.snapshot)
    }

    /// The draft this iPhone stores, which it does only while it has text GitHub doesn't.
    public func draft(id: UUID, accountID: UUID) throws -> Draft? {
        try stored(id, accountID: accountID).map(Self.snapshot)
    }

    /// `draft` as this iPhone has it now: as stored, as its last publish left it, or as it is.
    public func current(_ draft: Draft) throws -> Draft {
        if let row = try stored(draft) { return Self.snapshot(row) }
        if let released = released[draft.id], released.generation >= draft.generation { return released }
        return draft
    }

    /// Saves your typing. A note's first keystroke stores it, and it's let go once GitHub has the text.
    @discardableResult
    public func save(_ draft: Draft, text: String, generation: UInt64) throws -> Draft {
        let current = try current(draft)
        if generation == current.generation, sourceEqual(text, current.text) { return current }
        guard generation > current.generation else { throw DraftError.staleGeneration }
        let row = try current.isSaved ? find(current.id, accountID: current.accountID) : insert(current)
        try replaceText(row, text: text, generation: generation)
        return try settle(row)
    }

    /// Stores a note before you type in it, for a name you give a new gist or a note made from
    /// outside the app.
    public func keep(_ draft: Draft) throws -> Draft {
        let current = try current(draft)
        guard !current.isSaved else { return current }
        let row = try insert(current)
        try commit()
        return Self.snapshot(row)
    }

    private func insert(_ draft: Draft) throws -> StoredDraft {
        released[draft.id] = nil
        let row = StoredDraft(
            id: draft.id, accountID: draft.accountID, githubUserID: draft.githubUserID,
            gistID: draft.gistID, filename: draft.filename, description: draft.description,
            text: draft.text, base: draft.base, baseRevision: draft.baseRevision,
            stateData: try encode(.savedLocally))
        row.generation = draft.generation
        modelContext.insert(row)
        return row
    }

    /// Commits the draft, and lets it go when there's nothing left in it to keep.
    private func settle(_ row: StoredDraft) throws -> Draft {
        var draft = Self.snapshot(row)
        let isDisposable = draft.isDisposable
        if isDisposable { modelContext.delete(row) }
        try commit()
        if isDisposable {
            draft.isSaved = false
            released[draft.id] = draft
        }
        return draft
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
        if !sourceEqual(draft.filename, filename) || !sourceEqual(draft.gistDescription, description) {
            draft.updatedAt = .now
        }
        draft.filename = filename
        draft.gistDescription = description
        try commit()
        return Self.snapshot(draft)
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
        released[id] = nil
        guard let draft = try stored(id, accountID: accountID) else { return }
        guard draft.generation == expectedGeneration else { throw DraftError.staleGeneration }
        modelContext.delete(draft)
        try commit()
    }

    /// Adds text to the end of the draft, only while it's still as `edit` read it.
    public func apply(_ edit: DraftEdit) throws -> Draft {
        try save(edit.draft, text: edit.draft.text + edit.text, generation: edit.draft.generation + 1)
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

    /// Records the text a publish sends, so the next publish or open can tell whether a publish cut
    /// off midway landed. Typing since the draft was read means a newer publish follows, so this one
    /// stops here.
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

    /// GitHub has `content`, which becomes the base.
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
        return try settle(draft)
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
        return Self.snapshot(draft)
    }

    func forgetSent(id: UUID, accountID: UUID) throws -> Draft {
        let draft = try find(id, accountID: accountID)
        draft.sent = nil
        draft.sentGeneration = nil
        draft.stateData = try encode(.savedLocally)
        return try settle(draft)
    }

    func setState(_ state: PublishState, id: UUID, accountID: UUID) throws {
        guard let draft = try stored(id, accountID: accountID) else { return }
        draft.stateData = try encode(state)
        try commit()
    }

    /// Compares GitHub's copy of the file with your draft, for a publish and for opening a note. If
    /// GitHub has the sent text or your text, it's confirmed. GitHub's copy changing from the base
    /// is a conflict. Sent text GitHub doesn't have is left for the next publish to forget. Typing
    /// since the draft was read means a newer publish or check follows, so this one stops here.
    public func compareWithGitHub(
        _ read: Draft, remote: String?, revision: String?, gist: Gist? = nil
    ) throws -> Draft {
        guard let draft = try stored(read.id, accountID: read.accountID) else { return try current(read) }
        guard draft.generation == read.generation else { throw CancellationError() }
        guard let gistID = draft.gistID else { return Self.snapshot(draft) }
        if case .conflict = Self.decode(draft.stateData) { return Self.snapshot(draft) }
        if let sent = draft.sent {
            guard sourceEqual(remote, sent) else { return Self.snapshot(draft) }
            return try confirm(
                id: draft.id, accountID: draft.accountID, gistID: gistID, content: sent,
                revision: revision, publishedGist: gist)
        }
        if sourceEqual(remote, draft.text) {
            return try confirm(
                id: draft.id, accountID: draft.accountID, gistID: gistID, content: draft.text,
                revision: revision, publishedGist: gist)
        }
        guard !sourceEqual(remote, draft.base) else { return Self.snapshot(draft) }
        draft.stateData = try encode(.conflict(DraftConflict(
            generation: draft.generation, base: draft.base, local: draft.text,
            remote: remote, remoteRevision: revision)))
        try commit()
        return Self.snapshot(draft)
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
        return try settle(draft)
    }

    private func find(_ id: UUID, accountID: UUID) throws -> StoredDraft {
        guard let draft = try stored(id, accountID: accountID) else { throw DraftError.notFound }
        return draft
    }

    /// The row that stores `draft`, found by its file too, since a renamed file or a day that found
    /// its gist keeps the identity it started with.
    private func stored(_ draft: Draft) throws -> StoredDraft? {
        if let row = try stored(draft.id, accountID: draft.accountID) { return row }
        guard let gistID = draft.gistID else { return nil }
        let accountID = draft.accountID, filename = draft.filename
        return try modelContext.fetch(FetchDescriptor<StoredDraft>(predicate: #Predicate {
            $0.accountID == accountID && $0.gistID == gistID && $0.filename == filename
        })).first
    }

    private func stored(_ id: UUID, accountID: UUID) throws -> StoredDraft? {
        guard let draft = try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate { $0.id == id }
        )).first else { return nil }
        guard draft.accountID == accountID else { throw DraftError.accountMismatch }
        return draft
    }

    /// The draft as the app sees it. Only the states that need you are stored: a conflict, a failed
    /// publish and reconnecting. Whether it's saved to GitHub or only on this iPhone comes from its text.
    static func snapshot(_ draft: StoredDraft) -> Draft {
        var snapshot = Draft(
            id: draft.id, accountID: draft.accountID, githubUserID: draft.githubUserID,
            gistID: draft.gistID, filename: draft.filename, description: draft.gistDescription,
            text: draft.text, generation: draft.generation,
            base: draft.base, baseRevision: draft.baseRevision,
            sent: draft.sent, sentGeneration: draft.sentGeneration,
            state: decode(draft.stateData), updatedAt: draft.updatedAt, isSaved: true
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
