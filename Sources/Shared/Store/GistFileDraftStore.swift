import CryptoKit
import Foundation
import SwiftData

/// Why a publish didn't land.
public enum PublishFailure: Equatable, Sendable {
    case network
    case http(status: Int)
    case readOnly
    case incompleteRemote
    case reconnect
}

/// One file's writing that GitHub doesn't have yet: which file, what you wrote, and what GitHub had.
/// The store keeps it from your first keystroke until GitHub has the text. Before that, the same
/// value describes the file as you open it, so your first keystroke has a draft to save.
public struct GistFileDraft: Equatable, Sendable, Identifiable {
    /// The file on this iPhone: its account, gist or day, and filename. Each new gist is its own.
    public let id: UUID
    // Which file
    public let accountID: UUID
    /// None until the first publish creates the gist.
    public internal(set) var gistID: String?
    /// A new gist's name, or the Daily notes gist for a new day.
    public internal(set) var newGistName: String?
    public internal(set) var filename: String
    // What you wrote
    public internal(set) var text: String
    public internal(set) var editedAt: Date
    // What GitHub had
    /// GitHub's text when you started typing. A new gist or a new day has none.
    public internal(set) var base: GitHubVersion?
    /// The text of a publish GitHub hasn't confirmed yet.
    public internal(set) var sent: String?
    /// GitHub's newer text, once it moved past `base`. It waits for you to choose.
    public internal(set) var conflict: GitHubVersion?

    /// Whether GitHub has this text: the note is published, unedited since, and no publish or
    /// conflict is waiting.
    public var isPublished: Bool {
        gistID != nil && sent == nil && conflict == nil && sourceEqual(text, base?.text)
    }

    /// Whether there's nothing here to keep: GitHub has the text, or it's a new gist without a name or
    /// any writing. The store lets such a draft go, and a conflict always waits for you.
    public var isDisposable: Bool {
        conflict == nil && (isPublished
            || gistID == nil && sent == nil && (newGistName ?? "").isEmpty
                && text.allSatisfy(\.isWhitespace))
    }

    /// GitHub's newer `version`, for a note you haven't typed in.
    public func adopting(_ version: GitHubVersion) -> GistFileDraft {
        var adopted = self
        adopted.text = version.text
        adopted.base = version
        return adopted
    }

    /// The note under the name GitHub now gives its file.
    public func renamed(_ filename: String) -> GistFileDraft {
        var renamed = self
        renamed.filename = filename
        return renamed
    }
}

extension GistFileDraft {
    /// A note before you type in it: a gist's file, a new day or a new gist. Every copy of a file or a
    /// day shares one identity, so the draft your typing stores is the same one wherever you type.
    public init(
        accountID: UUID, gistID: String? = nil, newGistName: String? = nil,
        filename: String = "README.md", text: String = "", base: GitHubVersion? = nil
    ) {
        let file = gistID ?? (newGistName == DailyNote.gistDescription ? newGistName : nil)
        self.init(
            id: file.map { UUID(naming: "\(accountID)/\($0)/\(filename)") } ?? UUID(),
            accountID: accountID, gistID: gistID, newGistName: newGistName, filename: filename,
            text: text, editedAt: .distantPast, base: base, sent: nil, conflict: nil)
    }

    /// A gist's file as GitHub has it.
    public init(accountID: UUID, gist: Gist, filename: String, text: String) {
        self.init(
            accountID: accountID, gistID: gist.id, filename: filename, text: text,
            base: GitHubVersion(text: text, revision: gist.revision))
    }

    /// A new gist called `name`, starting with `content` or else the web's heading for its name.
    public init(accountID: UUID, newGistName name: String, content: String?) {
        self.init(
            accountID: accountID, newGistName: name,
            text: Gist.File.decodeContent(Gist.File.initialContent(description: name, content: content)))
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
    case changed
    case readOnly
    case notConfirmed
}

extension DraftError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound: String(localized: "This file is no longer on this iPhone.")
        case .changed: String(localized: "This file changed. Review the latest version first.")
        case .readOnly: String(localized: "Only its owner can edit this gist.")
        case .notConfirmed: String(localized: "GitHub didn't confirm the change. Try again.")
        }
    }
}

/// Text added to the end of a draft from outside the editor, like Add to Today. It lands only while
/// the draft is still as `draft` has it, so a stale or repeated addition can't change newer text.
public struct DraftEdit: Equatable, Sendable {
    public let draft: GistFileDraft
    public let text: String

    public init(draft: GistFileDraft, text: String) {
        self.draft = draft
        self.text = text
    }
}

@Model
final class StoredDraft {
    @Attribute(.unique) var id: UUID
    var accountID: UUID
    // Earlier builds read these three. They're kept so their stores open unchanged.
    var githubUserID: Int64
    var generation: UInt64
    @Attribute(originalName: "attemptedGeneration") var sentGeneration: UInt64?
    var gistID: String?
    var filename: String
    /// The new gist's name. Earlier builds kept every gist's description here.
    var gistDescription: String
    var text: String
    // Earlier builds stored these under their first names.
    @Attribute(originalName: "baseContent") var base: String?
    var baseRevision: String?
    @Attribute(originalName: "attemptedContent") var sent: String?
    /// The conflict, as a JSON `GitHubVersion?`.
    var stateData: Data
    var updatedAt: Date? = nil

    init(_ draft: GistFileDraft) {
        id = draft.id
        accountID = draft.accountID
        githubUserID = 0
        generation = 0
        gistID = draft.gistID
        filename = draft.filename
        gistDescription = draft.newGistName ?? ""
        text = draft.text
        base = draft.base?.text
        baseRevision = draft.base?.revision
        sent = draft.sent
        stateData = Self.encode(draft.conflict)
        updatedAt = .now
    }

    var draft: GistFileDraft {
        GistFileDraft(
            id: id, accountID: accountID, gistID: gistID,
            newGistName: gistDescription.isEmpty ? nil : gistDescription, filename: filename,
            text: text, editedAt: updatedAt ?? .distantPast,
            base: base.map { GitHubVersion(text: $0, revision: baseRevision) }, sent: sent,
            conflict: Self.decode(stateData))
    }

    var conflict: GitHubVersion? {
        get { Self.decode(stateData) }
        set { stateData = Self.encode(newValue) }
    }

    func setBase(_ version: GitHubVersion) {
        base = version.text
        baseRevision = version.revision
    }

    func setText(_ text: String) {
        guard !sourceEqual(self.text, text) else { return }
        self.text = text
        updatedAt = .now
    }

    private static func encode(_ conflict: GitHubVersion?) -> Data {
        (try? JSONEncoder().encode(conflict)) ?? Data("null".utf8)
    }

    /// Earlier builds stored a publish state, whose conflict carried GitHub's text and revision.
    /// Any other state has no conflict.
    private static func decode(_ data: Data) -> GitHubVersion? {
        struct Legacy: Decodable {
            struct State: Decodable { let _0: Conflict }
            struct Conflict: Decodable {
                let remote: String?
                let remoteRevision: String?
            }
            let conflict: State
        }
        if let version = try? JSONDecoder().decode(GitHubVersion.self, from: data) { return version }
        return (try? JSONDecoder().decode(Legacy.self, from: data)).map {
            GitHubVersion(text: $0.conflict._0.remote ?? "", revision: $0.conflict._0.remoteRevision)
        }
    }
}

@ModelActor
public actor GistFileDraftStore {
    public init(container: ModelContainer) {
        modelContainer = container
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    public static func open(url: URL? = nil, inMemory: Bool = false) throws -> GistFileDraftStore {
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
        return GistFileDraftStore(container: try ModelContainer(for: schema, configurations: [configuration]))
    }

    public func drafts(accountID: UUID) throws -> [GistFileDraft] {
        try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate { $0.accountID == accountID }
        )).map(\.draft)
    }

    public func draft(id: UUID, accountID: UUID) throws -> GistFileDraft? {
        try stored(id, accountID: accountID)?.draft
    }

    /// The stored draft of `draft`'s file, if you've typed in it since GitHub last had its text.
    public func current(_ draft: GistFileDraft) throws -> GistFileDraft? {
        try stored(draft)?.draft
    }

    /// Saves your typing over `draft`, the note as you started typing. A note's first keystroke
    /// stores it, starting from `github` when GitHub has exactly what you typed over, as when a
    /// publish just landed. It's let go once there's nothing left to keep.
    @discardableResult
    public func save(_ draft: GistFileDraft, text: String, github: GitHubVersion?) throws -> GistFileDraft {
        var started = draft
        if let github, sourceEqual(github.text, draft.text) { started.base = github }
        let row = try stored(draft) ?? insert(started)
        row.setText(text)
        return try settle(row)
    }

    /// Stores a note before you type in it, for a name you give a new gist or a note made from
    /// outside the app, or a new gist you publish before you type in it.
    public func keep(_ draft: GistFileDraft) throws -> GistFileDraft {
        if let row = try stored(draft) { return row.draft }
        let row = insert(draft)
        try commit()
        return row.draft
    }

    private func insert(_ draft: GistFileDraft) -> StoredDraft {
        let row = StoredDraft(draft)
        modelContext.insert(row)
        return row
    }

    /// Commits the draft, and lets it go when there's nothing left in it to keep.
    private func settle(_ row: StoredDraft) throws -> GistFileDraft {
        let draft = row.draft
        if draft.isDisposable { modelContext.delete(row) }
        try commit()
        return draft
    }

    /// Names a draft's file, or its new gist, as you or GitHub named it. A new gist you name keeps
    /// its name before you type in it.
    public func rename(
        _ draft: GistFileDraft, filename: String? = nil, newGistName: String? = nil
    ) throws -> GistFileDraft {
        let row = try stored(draft) ?? insert(draft)
        if let filename { row.filename = filename }
        if let newGistName { row.gistDescription = newGistName }
        return try settle(row)
    }

    /// Forgets the drafts of a gist deleted on GitHub, or of one of its files.
    public func removeDrafts(gistID: String, filename: String? = nil, accountID: UUID) throws {
        for draft in try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate { $0.accountID == accountID && $0.gistID == gistID }
        )) where filename == nil || draft.filename == filename {
            modelContext.delete(draft)
        }
        try commit()
    }

    public func discardLocalCopy(id: UUID, accountID: UUID) throws {
        guard let draft = try stored(id, accountID: accountID) else { return }
        modelContext.delete(draft)
        try commit()
    }

    /// Adds text to the end of the draft, only while it's still as `edit` read it.
    public func apply(_ edit: DraftEdit, github: GitHubVersion?) throws -> GistFileDraft {
        guard sourceEqual(try stored(edit.draft)?.text ?? edit.draft.text, edit.draft.text)
        else { throw DraftError.changed }
        return try save(edit.draft, text: edit.draft.text + edit.text, github: github)
    }

    /// Records the text a publish sends, so the next publish or open can tell whether a publish cut
    /// off midway landed. Typing since the draft was read means a newer publish follows, so this one
    /// stops here.
    public func recordSent(_ draft: GistFileDraft) throws {
        let row = try find(draft.id, accountID: draft.accountID)
        guard sourceEqual(row.text, draft.text) else { throw CancellationError() }
        row.sent = draft.text
        try commit()
    }

    /// GitHub has `base`, which the draft now starts from.
    public func confirm(_ draft: GistFileDraft, gistID: String, base: GitHubVersion) throws -> GistFileDraft {
        let row = try find(draft.id, accountID: draft.accountID)
        guard row.gistID == nil || row.gistID == gistID else { throw DraftError.changed }
        row.gistID = gistID
        row.setBase(base)
        row.sent = nil
        return try settle(row)
    }

    /// Makes a new gist's draft a new file in the gist `gistID`, with no base.
    public func join(_ draft: GistFileDraft, gistID: String) throws -> GistFileDraft {
        let row = try find(draft.id, accountID: draft.accountID)
        row.gistID = gistID
        try commit()
        return row.draft
    }

    public func forgetSent(_ draft: GistFileDraft) throws -> GistFileDraft {
        let row = try find(draft.id, accountID: draft.accountID)
        row.sent = nil
        return try settle(row)
    }

    /// Compares GitHub's copy of the file, `remote` or none, with your draft, for a publish and for
    /// opening a note. If GitHub has the sent text or your text, it's confirmed. GitHub's copy
    /// changing from the base is a conflict. Sent text GitHub doesn't have is left for the next
    /// publish to forget. Typing since the draft was read means a newer publish or check follows, so
    /// this one stops here.
    public func compareWithGitHub(_ read: GistFileDraft, remote: String?, revision: String?) throws -> GistFileDraft {
        guard let row = try stored(read.id, accountID: read.accountID), sourceEqual(row.text, read.text)
        else { throw CancellationError() }
        let draft = row.draft
        guard let gistID = row.gistID, draft.conflict == nil else { return draft }
        let version = GitHubVersion(text: remote ?? "", revision: revision)
        if let sent = row.sent {
            guard sourceEqual(remote, sent) else { return draft }
            return try confirm(draft, gistID: gistID, base: version)
        }
        if sourceEqual(remote, row.text) { return try confirm(draft, gistID: gistID, base: version) }
        // A file GitHub deleted is a conflict with no text.
        let moved = draft.base.map { !sourceEqual(remote ?? "", $0.text) } ?? (remote != nil)
        guard moved else { return draft }
        row.conflict = version
        try commit()
        return row.draft
    }

    /// Settles a conflict with `text`, which starts from GitHub's newer version. It lands only while
    /// the draft and its conflict are still as `read` has them.
    public func resolveConflict(_ read: GistFileDraft, text: String) throws -> GistFileDraft {
        let row = try find(read.id, accountID: read.accountID)
        guard let conflict = row.conflict, conflict == read.conflict, sourceEqual(row.text, read.text)
        else { throw DraftError.changed }
        row.setBase(conflict)
        row.setText(text)
        row.sent = nil
        row.conflict = nil
        return try settle(row)
    }

    private func find(_ id: UUID, accountID: UUID) throws -> StoredDraft {
        guard let draft = try stored(id, accountID: accountID) else { throw DraftError.notFound }
        return draft
    }

    /// The row that stores `draft`, found by its file too, since a renamed file or a day that found
    /// its gist keeps the identity it started with.
    private func stored(_ draft: GistFileDraft) throws -> StoredDraft? {
        if let row = try stored(draft.id, accountID: draft.accountID) { return row }
        guard let gistID = draft.gistID else { return nil }
        let accountID = draft.accountID, filename = draft.filename
        return try modelContext.fetch(FetchDescriptor<StoredDraft>(predicate: #Predicate {
            $0.accountID == accountID && $0.gistID == gistID && $0.filename == filename
        })).first
    }

    private func stored(_ id: UUID, accountID: UUID) throws -> StoredDraft? {
        try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate { $0.id == id && $0.accountID == accountID }
        )).first
    }

    private func commit() throws {
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
