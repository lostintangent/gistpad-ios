import Foundation

public enum LibrarySearchError: Error, Equatable, Sendable {
    case unclosedQuote
    case invalidEscape
    case unknownTag(String)
    case ambiguousTag(String)
}

public struct LibrarySearchQuery: Equatable, Sendable {
    public let terms: [String]
    public let tagIDs: Set<String>

    public init(text: String = "", tagIDs: Set<String> = []) {
        terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        self.tagIDs = tagIDs
    }

    public init(query: String, preferences: Preferences, tagIDs: Set<String> = []) throws {
        var terms: [String] = []
        var selected = tagIDs
        for token in try Self.tokens(query) {
            let value: String?
            if token.hasPrefix("tag:") { value = String(token.dropFirst(4)) }
            else if token.hasPrefix("#") { value = String(token.dropFirst()) }
            else { value = nil }
            guard let value else { terms.append(token); continue }
            if preferences.tags[value] != nil { selected.insert(value); continue }
            let matches = preferences.tags.filter {
                $0.value.objectValue?["name"]?.stringValue?.localizedCaseInsensitiveCompare(value) == .orderedSame
            }.map(\.key)
            guard !matches.isEmpty else { throw LibrarySearchError.unknownTag(value) }
            guard matches.count == 1 else { throw LibrarySearchError.ambiguousTag(value) }
            selected.insert(matches[0])
        }
        self.terms = terms
        self.tagIDs = selected
    }

    private static func tokens(_ query: String) throws -> [String] {
        var result: [String] = []
        var token = ""
        var quoted = false
        var escaped = false
        for character in query {
            if escaped {
                guard character == "\"" || character == "\\" else { throw LibrarySearchError.invalidEscape }
                token.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                if !token.isEmpty { result.append(token); token = "" }
            } else { token.append(character) }
        }
        guard !quoted else { throw LibrarySearchError.unclosedQuote }
        guard !escaped else { throw LibrarySearchError.invalidEscape }
        if !token.isEmpty { result.append(token) }
        return result
    }
}

public enum CachedLibraryCollection: Sendable {
    case all, gists, dailyNotes, starred, archive
}

public struct LibrarySearchMatch: Equatable, Identifiable, Sendable {
    public let id: String
    public let gistID: String?
    public let draftID: UUID?
    public let filename: String
    public let title: String
    public let text: String?
    public let updatedAt: Date?
    public let isPinned: Bool
    public let isStarred: Bool
    public let isArchived: Bool
    public let isDailyNote: Bool
    public let isSecret: Bool
    public let isRecovery: Bool
    public let tagIDs: Set<String>
    public let progress: TaskProgress?
    public let isOverdue: Bool
    public let contentIsCurrent: Bool
}

public struct LibrarySearchResult: Equatable, Sendable {
    public let matches: [LibrarySearchMatch]
    public let totalDocuments: Int
    public let documentsWithCachedContent: Int
    public let incompleteGistIDs: Set<String>
}

public enum LibrarySearch {
    public static func search(
        _ library: CachedLibrarySnapshot, query: LibrarySearchQuery = LibrarySearchQuery(),
        collection: CachedLibraryCollection = .all, drafts: [DraftSnapshot] = [],
        date: Date = .now, timeZone: TimeZone = .current
    ) -> LibrarySearchResult {
        let drafts = drafts.filter { $0.accountID == library.accountID }
        let owned = Set(library.owned.map(\.id))
        let availableGists = Set(library.gists.map(\.id))
        let starred = Set(library.starred.map(\.id))
        let validTagIDs = Set(library.preferences.tags.keys)
        let selectedTags = query.tagIDs.intersection(validTagIDs)
        let pinned = Set(library.preferences.pinnedGists)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: date)
        var documents: [LibrarySearchMatch] = []
        var incomplete: Set<String> = []
        for gist in library.gists {
            let isOwned = owned.contains(gist.id)
            switch collection {
            case .all: break
            case .gists: if !isOwned || gist.isDailyNote || gist.isArchived { continue }
            case .dailyNotes: if !isOwned || !gist.isDailyNote { continue }
            case .starred: if !starred.contains(gist.id) { continue }
            case .archive: if !isOwned || !gist.isArchived { continue }
            }
            if gist.truncated == true || library.details[gist.id]?.truncated == true { incomplete.insert(gist.id) }
            let filenames = Set(gist.markdownFilenames + drafts.filter {
                $0.gistID == gist.id && $0.filename.hasSuffix(".md")
            }.map(\.filename)).sorted()
            for filename in filenames {
                let day = gist.isDailyNote
                    ? DailyNotesIndex.parseDateFilename(filename, timeZone: timeZone) : nil
                if gist.isDailyNote, day == nil { continue }
                let draft = drafts.first { $0.gistID == gist.id && $0.filename == filename }
                let cached = library.cachedContent(gist: gist, filename: filename)
                let text = draft?.text ?? cached?.text
                let hasLocalChanges = draft.map {
                    $0.attemptedGeneration != nil || !sourceEqual($0.text, $0.baseContent)
                } ?? false
                let current = hasLocalChanges
                    || (cached?.isCurrent == true && sourceEqual(text, cached?.text))
                let progress = text.map(TaskProgress.init(markdown:))
                let tags = Set(library.preferences.gistTags[gist.id] ?? []).intersection(validTagIDs)
                documents.append(LibrarySearchMatch(
                    id: "\(gist.id)/\(filename)", gistID: gist.id, draftID: draft?.id,
                    filename: filename, title: gist.isDailyNote ? GistConventions.fileDisplayName(filename) : gist.displayName,
                    text: text, updatedAt: gist.updatedAt,
                    isPinned: pinned.contains(gist.id), isStarred: starred.contains(gist.id),
                    isArchived: gist.isArchived, isDailyNote: gist.isDailyNote, isSecret: !gist.isPublic,
                    isRecovery: false,
                    tagIDs: tags, progress: progress,
                    isOverdue: day.map { $0 < today && (progress?.remaining ?? 0) > 0 } ?? false,
                    contentIsCurrent: text != nil && current
                ))
            }
        }
        for draft in drafts where draft.gistID.map({ !availableGists.contains($0) }) ?? true {
            let daily = draft.description == GistConventions.dailyNotesDescription
            let archived = draft.description.range(of: #"\s*\[Archived\]$"#, options: .regularExpression) != nil
            if collection == .all || (collection == .gists && !daily && !archived)
                || (collection == .dailyNotes && daily) || (collection == .archive && archived) {
                let day = daily ? DailyNotesIndex.parseDateFilename(draft.filename, timeZone: timeZone) : nil
                if daily, day == nil { continue }
                let progress = TaskProgress(markdown: draft.text)
                let tags = Set(draft.gistID.flatMap { library.preferences.gistTags[$0] } ?? []).intersection(validTagIDs)
                documents.append(LibrarySearchMatch(
                    id: draft.id.uuidString, gistID: draft.gistID, draftID: draft.id,
                    filename: draft.filename, title: daily || draft.description.isEmpty
                        ? GistConventions.fileDisplayName(draft.filename) : draft.description,
                    text: draft.text, updatedAt: draft.updatedAt,
                    isPinned: false, isStarred: false,
                    isArchived: archived, isDailyNote: daily, isSecret: true, isRecovery: draft.gistID != nil,
                    tagIDs: tags, progress: progress,
                    isOverdue: day.map { $0 < today && progress.remaining > 0 } ?? false,
                    contentIsCurrent: true
                ))
            }
        }
        let matches = documents.filter { document in
            guard selectedTags.isSubset(of: document.tagIDs) else { return false }
            let fields = [document.title, document.filename, document.text ?? ""]
            return query.terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }.sorted { lhs, rhs in
            if collection == .dailyNotes {
                if lhs.isOverdue != rhs.isOverdue { return lhs.isOverdue }
                let left = DailyNotesIndex.parseDateFilename(lhs.filename, timeZone: timeZone) ?? .distantPast
                let right = DailyNotesIndex.parseDateFilename(rhs.filename, timeZone: timeZone) ?? .distantPast
                if left != right { return left > right }
            }
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.updatedAt != rhs.updatedAt {
                return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            }
            return lhs.id < rhs.id
        }
        return LibrarySearchResult(
            matches: matches, totalDocuments: documents.count,
            documentsWithCachedContent: documents.filter { $0.text != nil }.count,
            incompleteGistIDs: incomplete
        )
    }
}
