import Foundation
import SwiftData

/// The phone's copy of your gists: owned and starred gists, their details and the text of files
/// you've opened.
public struct GistCache: Codable, Equatable, Sendable {
    public struct FileContent: Codable, Equatable, Sendable {
        public let text: String
        public let revision: String?
        public let updatedAt: Date
    }

    public let accountID: UUID
    public var owned: [Gist]
    public var starred: [Gist]
    public var cachedAt: Date
    public var details: [String: Gist]
    public var fileContent: [String: FileContent]

    public init(
        accountID: UUID, owned: [Gist], starred: [Gist], cachedAt: Date = .now,
        details: [String: Gist] = [:], fileContent: [String: FileContent] = [:]
    ) {
        self.accountID = accountID
        self.owned = owned
        self.starred = starred
        self.cachedAt = cachedAt
        self.details = details
        self.fileContent = fileContent
    }

    public var gists: [Gist] {
        var values = Dictionary(starred.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for gist in owned { values[gist.id] = gist }
        return values.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    public func content(gist: Gist, filename: String) -> String? {
        cachedContent(gist: gist, filename: filename)?.text
    }

    /// A file's cached text, only when it's as new as `gist`.
    public func currentContent(gist: Gist, filename: String) -> String? {
        cachedContent(gist: gist, filename: filename).flatMap { $0.isCurrent ? $0.text : nil }
    }

    func cachedContent(gist: Gist, filename: String) -> (text: String, isCurrent: Bool)? {
        let candidates = [details[gist.id], gist].compactMap { $0 }.sorted { $0.updatedAt > $1.updatedAt }
        for candidate in candidates {
            guard let file = candidate.files[filename] else { continue }
            let current = candidate.updatedAt >= gist.updatedAt
            if file.truncated != true, let text = file.content {
                return (Gist.File.decodeContent(text), current)
            }
            if let saved = fileContent["\(gist.id)/\(filename)"] {
                let sameRevision = saved.revision != nil && saved.revision == candidate.revision
                let sameDate = candidate.revision == nil && saved.updatedAt == candidate.updatedAt
                if sameRevision || sameDate {
                    return (Gist.File.decodeContent(saved.text), current)
                }
            }
        }
        return nil
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

extension GistFileDraftStore {
    func cachePublication(
        _ gist: Gist, accountID: UUID, githubUserID: Int64, filename: String, content: String
    ) throws {
        try updateCache(accountID) { cached in
            if gist.owner?.id == githubUserID {
                cached.owned.removeAll { $0.id == gist.id }
                cached.owned.insert(gist, at: 0)
            }
            cached.starred = cached.starred.map { $0.id == gist.id ? gist : $0 }
            cached.details[gist.id] = gist
            cached.fileContent["\(gist.id)/\(filename)"] = .init(
                text: content, revision: gist.revision, updatedAt: gist.updatedAt)
        }
    }

    public func gistCache(accountID: UUID) throws -> GistCache? {
        guard let stored = try cacheRecord(accountID) else { return nil }
        return try JSONDecoder().decode(GistCache.self, from: stored.payload)
    }

    /// Saves GitHub's fresh lists, which are the authority on what exists. A draft of a gist that's no
    /// longer listed stays as a recovery copy.
    public func cacheGists(
        owned: [Gist], starred: [Gist], accountID: UUID, cachedAt: Date = .now
    ) throws {
        let previous = try gistCache(accountID: accountID)
        let ids = Set(owned.map(\.id) + starred.map(\.id))
        let snapshot = GistCache(
            accountID: accountID, owned: owned, starred: starred, cachedAt: cachedAt,
            details: previous?.details.filter { ids.contains($0.key) } ?? [:],
            fileContent: previous?.fileContent.filter {
                ids.contains(String($0.key.prefix(while: { $0 != "/" })))
            } ?? [:]
        )
        let payload = try JSONEncoder().encode(snapshot)
        if let existing = try cacheRecord(accountID) { existing.payload = payload }
        else { modelContext.insert(StoredLibrary(accountID: accountID, payload: payload)) }
        try commit()
    }

    public func cacheGist(_ gist: Gist, accountID: UUID) throws {
        try updateCache(accountID) { cache in
            if let existing = cache.details[gist.id], existing.updatedAt > gist.updatedAt { return }
            cache.details[gist.id] = gist
            cache.owned = cache.owned.map { $0.id == gist.id ? gist : $0 }
            cache.starred = cache.starred.map { $0.id == gist.id ? gist : $0 }
        }
        try commit()
    }

    public func cacheContent(
        _ text: String, gist: Gist, filename: String, accountID: UUID
    ) throws {
        guard gist.files[filename] != nil else { throw GitHubClientError.missingFile }
        try updateCache(accountID) { cache in
            let key = "\(gist.id)/\(filename)"
            let value = GistCache.FileContent(text: text, revision: gist.revision, updatedAt: gist.updatedAt)
            if let previous = cache.fileContent[key], previous.updatedAt > value.updatedAt { return }
            cache.fileContent[key] = value
        }
        try commit()
    }

    /// Changes the cache in place, if there is one. The caller commits.
    func updateCache(_ accountID: UUID, _ change: (inout GistCache) -> Void) throws {
        guard let record = try cacheRecord(accountID) else { return }
        var cached = try JSONDecoder().decode(GistCache.self, from: record.payload)
        change(&cached)
        record.payload = try JSONEncoder().encode(cached)
    }

    private func cacheRecord(_ id: UUID) throws -> StoredLibrary? {
        try modelContext.fetch(FetchDescriptor<StoredLibrary>(
            predicate: #Predicate { $0.accountID == id }
        )).first
    }
}
