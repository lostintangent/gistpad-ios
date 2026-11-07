import Foundation
import SwiftData

/// A file's text as GitHub had it, at the gist revision GitHub said it was.
public struct GitHubVersion: Codable, Equatable, Sendable {
    public let text: String
    public let revision: String?

    public init(text: String, revision: String?) {
        self.text = text
        self.revision = revision
    }
}

/// The phone's copy of your gists: owned and starred gists, and the last text GitHub gave for each
/// file you've opened. It loads and saves itself in the drafts' SwiftData container, the way
/// `URLCache` keeps itself on disk.
public struct GistCache: Codable, Equatable, Sendable {
    public let accountID: UUID
    public private(set) var owned: [Gist] = []
    public private(set) var starred: [Gist] = []
    /// Each file's last text from GitHub, by `gistID/filename`.
    public private(set) var texts: [String: GitHubVersion] = [:]
    public private(set) var cachedAt = Date.now

    /// A cache of GitHub's lists, with the text of any file they include.
    public init(accountID: UUID, owned: [Gist] = [], starred: [Gist] = []) {
        self.accountID = accountID
        replaceLists(owned: owned, starred: starred)
        for gist in owned + starred { update(gist) }
    }

    public var gists: [Gist] {
        var values = Dictionary(starred.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for gist in owned { values[gist.id] = gist }
        return values.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    /// The file's last text from GitHub, to show right away.
    public func text(of filename: String, in gist: Gist) -> String? {
        texts[Self.key(gist.id, filename)]?.text
    }

    /// The file's last text and revision from GitHub.
    public func version(of filename: String, gistID: String) -> GitHubVersion? {
        texts[Self.key(gistID, filename)]
    }

    /// The file's text, only when it's as new as `gist`. A listed gist has no revision, so it's the
    /// one this cache read, as long as GitHub hasn't changed the gist since.
    public func currentText(of filename: String, in gist: Gist) -> String? {
        let revision = gist.revision
            ?? gists.first { $0.id == gist.id && $0.updatedAt == gist.updatedAt }?.revision
        guard let version = texts[Self.key(gist.id, filename)], let revision,
              version.revision == revision else { return nil }
        return version.text
    }

    /// Takes GitHub's fresh lists, which are the authority on what exists. A gist GitHub hasn't
    /// changed keeps the revision this cache read for it.
    public mutating func replaceLists(owned: [Gist], starred: [Gist], at date: Date = .now) {
        let known = Dictionary(gists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keep: (Gist) -> Gist = { listed in
            guard let cached = known[listed.id], cached.updatedAt == listed.updatedAt else { return listed }
            return listed.with(history: cached.history)
        }
        self.owned = owned.map(keep)
        self.starred = starred.map(keep)
        let ids = Set(gists.map(\.id))
        texts = texts.filter { ids.contains(String($0.key.prefix(while: { $0 != "/" }))) }
        cachedAt = date
    }

    /// A gist as GitHub just returned it, with the text of every file it includes.
    public mutating func update(_ gist: Gist) {
        let replace: (Gist) -> Gist = { $0.id == gist.id && $0.updatedAt <= gist.updatedAt ? gist.withoutContent : $0 }
        owned = owned.map(replace)
        starred = starred.map(replace)
        for (filename, file) in gist.files where file.truncated != true {
            guard let content = file.content else { continue }
            store(Gist.File.decodeContent(content), of: filename, in: gist)
        }
    }

    /// A gist you just published to or joined, first in your list.
    public mutating func insert(_ gist: Gist) {
        owned.removeAll { $0.id == gist.id }
        owned.insert(gist.withoutContent, at: 0)
        update(gist)
    }

    public mutating func store(_ text: String, of filename: String, in gist: Gist) {
        let key = Self.key(gist.id, filename)
        if let cached = gists.first(where: { $0.id == gist.id }), cached.updatedAt > gist.updatedAt { return }
        texts[key] = GitHubVersion(text: text, revision: gist.revision)
    }

    /// Forgets a gist deleted on GitHub, or one of its files when `filename` is set and `updated` is
    /// the gist GitHub returned without it.
    public mutating func remove(gistID: String, filename: String? = nil, updated gist: Gist? = nil) {
        if let filename, let gist {
            update(gist)
            texts[Self.key(gistID, filename)] = nil
        } else {
            owned.removeAll { $0.id == gistID }
            starred.removeAll { $0.id == gistID }
            texts = texts.filter { !$0.key.hasPrefix(gistID + "/") }
        }
    }

    public mutating func setStarred(_ isStarred: Bool, _ gist: Gist) {
        starred.removeAll { $0.id == gist.id }
        if isStarred { starred.append(gist.withoutContent) }
    }

    public mutating func setCommentCount(_ total: Int, gistID: String) {
        let update: (Gist) -> Gist = { $0.id == gistID ? $0.withCommentCount(total) : $0 }
        owned = owned.map(update)
        starred = starred.map(update)
    }

    private static func key(_ gistID: String, _ filename: String) -> String { "\(gistID)/\(filename)" }
}

extension GistCache {
    /// The account's cache as this iPhone last saved it, or nil before its first list.
    public static func load(accountID: UUID, from container: ModelContainer) throws -> GistCache? {
        guard let row = try row(accountID, in: ModelContext(container)) else { return nil }
        // A cache from an earlier build doesn't decode, and the next refresh rebuilds it.
        return try? JSONDecoder().decode(GistCache.self, from: row.payload)
    }

    public func save(to container: ModelContainer) throws {
        let context = ModelContext(container)
        let payload = try JSONEncoder().encode(self)
        if let row = try Self.row(accountID, in: context) { row.payload = payload }
        else { context.insert(StoredLibrary(accountID: accountID, payload: payload)) }
        try context.save()
    }

    private static func row(_ id: UUID, in context: ModelContext) throws -> StoredLibrary? {
        try context.fetch(FetchDescriptor<StoredLibrary>(predicate: #Predicate { $0.accountID == id })).first
    }
}

/// Keeps its original name, so existing stores open without a migration.
@Model
final class StoredLibrary {
    @Attribute(.unique) var accountID: UUID
    var payload: Data

    init(accountID: UUID, payload: Data) {
        self.accountID = accountID
        self.payload = payload
    }
}

extension Gist {
    fileprivate func with(history: [GistRevision]?) -> Gist {
        Gist(
            id: id, description: description, files: files, updatedAt: updatedAt, createdAt: createdAt,
            isPublic: isPublic, owner: owner, truncated: truncated, history: history,
            commentCount: commentCount)
    }

    /// The gist without its files' text, which the cache keeps once, in `texts`.
    fileprivate var withoutContent: Gist {
        Gist(
            id: id, description: description,
            files: files.mapValues {
                Gist.File(
                    filename: $0.filename, language: $0.language, content: nil, truncated: $0.truncated,
                    rawURL: $0.rawURL, size: $0.size)
            },
            updatedAt: updatedAt, createdAt: createdAt, isPublic: isPublic, owner: owner,
            truncated: truncated, history: history, commentCount: commentCount)
    }
}
