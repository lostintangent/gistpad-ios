import Foundation
import SwiftData

public struct CachedFile: Codable, Equatable, Sendable {
    public let text: String
    public let revision: String?
    public let updatedAt: Date
}

public struct CachedLibrary: Codable, Equatable, Sendable {
    public let accountID: UUID
    public var owned: [Gist]
    public var starred: [Gist]
    public var preferences: Preferences
    public var cachedAt: Date
    public var details: [String: Gist]
    public var fileContent: [String: CachedFile]

    public init(
        accountID: UUID, owned: [Gist], starred: [Gist],
        preferences: Preferences, cachedAt: Date = .now,
        details: [String: Gist] = [:], fileContent: [String: CachedFile] = [:]
    ) {
        self.accountID = accountID
        self.owned = owned
        self.starred = starred
        self.preferences = preferences
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
                return (GistFile.decodeContent(text), current)
            }
            if let saved = fileContent["\(gist.id)/\(filename)"] {
                let sameRevision = saved.revision != nil && saved.revision == candidate.revision
                let sameDate = candidate.revision == nil && saved.updatedAt == candidate.updatedAt
                if sameRevision || sameDate {
                    return (GistFile.decodeContent(saved.text), current)
                }
            }
        }
        return nil
    }
}

@Model
final class StoredLibrary {
    @Attribute(.unique) var accountID: UUID
    var payload: Data

    init(accountID: UUID, payload: Data) {
        self.accountID = accountID
        self.payload = payload
    }
}

extension DraftStore {
    func cachePublication(
        _ gist: Gist, accountID: UUID, githubUserID: Int64, filename: String, content: String
    ) throws {
        try updateLibrary(accountID) { cached in
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

    public func cachedLibrary(accountID: UUID) throws -> CachedLibrary? {
        guard let stored = try libraryRecord(accountID) else { return nil }
        return try JSONDecoder().decode(CachedLibrary.self, from: stored.payload)
    }

    /// Saves GitHub's fresh lists, which are the authority on what exists. A clean phone copy of a gist
    /// that's no longer listed goes with it, unless its gist is open (`keeping` holds gist IDs), while one
    /// holding unpublished text stays as a recovery copy.
    public func cacheLibrary(
        owned: [Gist], starred: [Gist], preferences: Preferences,
        accountID: UUID, cachedAt: Date = .now, keeping: Set<String> = []
    ) throws {
        let previous = try cachedLibrary(accountID: accountID)
        let ids = Set(owned.map(\.id) + starred.map(\.id))
        let gone = try modelContext.fetch(FetchDescriptor<StoredDraft>(
            predicate: #Predicate { $0.accountID == accountID }
        )).filter {
            guard let gistID = $0.gistID, !keeping.contains(gistID) else { return false }
            return try !ids.contains(gistID) && snapshot($0).isClean
        }
        for draft in gone { modelContext.delete(draft) }
        let snapshot = CachedLibrary(
            accountID: accountID, owned: owned, starred: starred,
            preferences: preferences, cachedAt: cachedAt,
            details: previous?.details.filter { ids.contains($0.key) } ?? [:],
            fileContent: previous?.fileContent.filter {
                ids.contains(String($0.key.prefix(while: { $0 != "/" })))
            } ?? [:]
        )
        let payload = try JSONEncoder().encode(snapshot)
        if let existing = try libraryRecord(accountID) { existing.payload = payload }
        else { modelContext.insert(StoredLibrary(accountID: accountID, payload: payload)) }
        try commit()
    }

    public func cacheGist(_ gist: Gist, accountID: UUID) throws {
        try updateLibrary(accountID) { library in
            if let existing = library.details[gist.id], existing.updatedAt > gist.updatedAt { return }
            library.details[gist.id] = gist
            library.owned = library.owned.map { $0.id == gist.id ? gist : $0 }
            library.starred = library.starred.map { $0.id == gist.id ? gist : $0 }
        }
        try commit()
    }

    public func cacheContent(
        _ text: String, gist: Gist, filename: String, accountID: UUID
    ) throws {
        guard gist.files[filename] != nil else { throw GitHubClientError.missingFile }
        try updateLibrary(accountID) { library in
            let key = "\(gist.id)/\(filename)"
            let value = CachedFile(text: text, revision: gist.revision, updatedAt: gist.updatedAt)
            if let previous = library.fileContent[key], previous.updatedAt > value.updatedAt { return }
            library.fileContent[key] = value
        }
        try commit()
    }

    /// Changes the cached library in place, if there is one. The caller commits.
    func updateLibrary(_ accountID: UUID, _ change: (inout CachedLibrary) -> Void) throws {
        guard let record = try libraryRecord(accountID) else { return }
        var cached = try JSONDecoder().decode(CachedLibrary.self, from: record.payload)
        change(&cached)
        record.payload = try JSONEncoder().encode(cached)
    }

    private func libraryRecord(_ id: UUID) throws -> StoredLibrary? {
        try modelContext.fetch(FetchDescriptor<StoredLibrary>(
            predicate: #Predicate { $0.accountID == id }
        )).first
    }
}
