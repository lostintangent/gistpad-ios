import Foundation
import SwiftData

public struct CachedFileContent: Codable, Equatable, Sendable {
    public let text: String
    public let revision: String?
    public let updatedAt: Date
}

public struct CachedLibrarySnapshot: Codable, Equatable, Sendable {
    public let accountID: UUID
    public var owned: [Gist]
    public var starred: [Gist]
    public var preferences: Preferences
    public var cachedAt: Date
    public var details: [String: Gist]
    public var fileContent: [String: CachedFileContent]

    public init(
        accountID: UUID, owned: [Gist], starred: [Gist],
        preferences: Preferences, cachedAt: Date = .now,
        details: [String: Gist] = [:], fileContent: [String: CachedFileContent] = [:]
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

    func cachedContent(gist: Gist, filename: String) -> (text: String, isCurrent: Bool)? {
        let candidates = [details[gist.id], gist].compactMap { $0 }.sorted { $0.updatedAt > $1.updatedAt }
        for candidate in candidates {
            guard let file = candidate.files[filename] else { continue }
            let current = candidate.updatedAt >= gist.updatedAt
            if file.truncated != true, let text = file.content {
                return (GistConventions.decodeContent(text), current)
            }
            if let saved = fileContent["\(gist.id)/\(filename)"] {
                let sameRevision = saved.revision != nil && saved.revision == candidate.revision
                let sameDate = candidate.revision == nil && saved.updatedAt == candidate.updatedAt
                if sameRevision || sameDate {
                    return (GistConventions.decodeContent(saved.text), current)
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
    func publicationCache(
        gist: Gist, accountID: UUID, githubUserID: Int64, filename: String, content: String
    ) throws -> (StoredLibrary, Data)? {
        guard let record = try libraryRecord(accountID) else { return nil }
        var cached = try JSONDecoder().decode(CachedLibrarySnapshot.self, from: record.payload)
        if gist.owner?.id == githubUserID {
            cached.owned.removeAll { $0.id == gist.id }
            cached.owned.insert(gist, at: 0)
        }
        cached.starred = cached.starred.map { $0.id == gist.id ? gist : $0 }
        cached.details[gist.id] = gist
        cached.fileContent["\(gist.id)/\(filename)"] = .init(
            text: content, revision: gist.revision, updatedAt: gist.updatedAt)
        return (record, try JSONEncoder().encode(cached))
    }

    public func cachedLibrary(accountID: UUID) throws -> CachedLibrarySnapshot? {
        guard let stored = try libraryRecord(accountID) else { return nil }
        return try JSONDecoder().decode(CachedLibrarySnapshot.self, from: stored.payload)
    }

    public func cacheLibrary(
        owned: [Gist], starred: [Gist], preferences: Preferences,
        accountID: UUID, cachedAt: Date = .now
    ) throws {
        let previous = try cachedLibrary(accountID: accountID)
        let ids = Set(owned.map(\.id) + starred.map(\.id))
        let snapshot = CachedLibrarySnapshot(
            accountID: accountID, owned: owned, starred: starred,
            preferences: preferences, cachedAt: cachedAt,
            details: previous?.details.filter { ids.contains($0.key) } ?? [:],
            fileContent: previous?.fileContent.filter {
                ids.contains(String($0.key.prefix(while: { $0 != "/" })))
            } ?? [:]
        )
        try saveLibrary(snapshot)
    }

    public func cacheGist(_ gist: Gist, accountID: UUID) throws {
        guard var library = try cachedLibrary(accountID: accountID) else {
            throw LibraryCacheError.missingLibrary
        }
        if let existing = library.details[gist.id], existing.updatedAt > gist.updatedAt { return }
        library.details[gist.id] = gist
        library.owned = library.owned.map { $0.id == gist.id ? gist : $0 }
        library.starred = library.starred.map { $0.id == gist.id ? gist : $0 }
        try saveLibrary(library)
    }

    public func cacheContent(
        _ text: String, gist: Gist, filename: String, accountID: UUID
    ) throws {
        guard gist.files[filename] != nil else { throw GitHubClientError.missingFile }
        guard var library = try cachedLibrary(accountID: accountID) else {
            throw LibraryCacheError.missingLibrary
        }
        let key = "\(gist.id)/\(filename)"
        let value = CachedFileContent(text: text, revision: gist.revision, updatedAt: gist.updatedAt)
        if let previous = library.fileContent[key], previous.updatedAt > value.updatedAt { return }
        library.fileContent[key] = value
        try saveLibrary(library)
    }

    private func libraryRecord(_ id: UUID) throws -> StoredLibrary? {
        try modelContext.fetch(FetchDescriptor<StoredLibrary>(
            predicate: #Predicate { $0.accountID == id }
        )).first
    }

    private func saveLibrary(_ snapshot: CachedLibrarySnapshot) throws {
        let payload = try JSONEncoder().encode(snapshot)
        if let existing = try libraryRecord(snapshot.accountID) { existing.payload = payload }
        else { modelContext.insert(StoredLibrary(accountID: snapshot.accountID, payload: payload)) }
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
    }
}

public enum LibraryCacheError: Error, Equatable, Sendable {
    case missingLibrary
}
