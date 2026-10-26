import Foundation
import Observation

public enum LibraryCollection: String, CaseIterable, Identifiable, Sendable {
    case gists, dailyNotes, starred, archive

    public var id: Self { self }
}

public struct LibraryTag: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let colorHex: String?

    public init(id: String, name: String, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

public struct LibraryNote: Equatable, Identifiable, Sendable {
    public let id: String
    public var gistID: String?
    public var title: String
    public var updatedAt: Date?
    public var owner: String?
    public var isOwned: Bool
    public var canDeleteFromGitHub: Bool
    public var isRecovery: Bool
    public var isSecret: Bool
    public var isPinned: Bool
    public var isStarred: Bool
    public var isArchived: Bool
    public var isDailyNote: Bool
    public var tagIDs: Set<String>
    public var filename: String?
    public var fileCount: Int?
    public var excerpt: String?
    public var progress: LibraryTaskProgress?
    public var isOverdue: Bool
    public var dailyDate: Date?
    public var commentCount: Int?

    public var supportsComments: Bool { gistID != nil && !isDailyNote }

    public var visibleCommentCount: Int? {
        guard supportsComments, let commentCount, commentCount > 0 else { return nil }
        return commentCount
    }

    public init(
        id: String, title: String, updatedAt: Date?, gistID: String? = nil, owner: String? = nil,
        isOwned: Bool = true, canDeleteFromGitHub: Bool = false, isRecovery: Bool = false,
        isSecret: Bool = true, isPinned: Bool = false,
        isStarred: Bool = false, isArchived: Bool = false, isDailyNote: Bool = false,
        tagIDs: Set<String> = [], filename: String? = nil, fileCount: Int? = nil, excerpt: String? = nil,
        progress: LibraryTaskProgress? = nil, isOverdue: Bool = false, dailyDate: Date? = nil,
        commentCount: Int? = nil
    ) {
        self.id = id
        self.gistID = gistID
        self.title = title
        self.updatedAt = updatedAt
        self.owner = owner
        self.isOwned = isOwned
        self.canDeleteFromGitHub = canDeleteFromGitHub
        self.isRecovery = isRecovery
        self.isSecret = isSecret
        self.isPinned = isPinned
        self.isStarred = isStarred
        self.isArchived = isArchived
        self.isDailyNote = isDailyNote
        self.tagIDs = tagIDs
        self.filename = filename
        self.fileCount = fileCount
        self.excerpt = excerpt
        self.progress = progress
        self.isOverdue = isOverdue
        self.dailyDate = dailyDate
        self.commentCount = commentCount
    }
}

public struct LibrarySnapshot: Equatable, Sendable {
    public var notes: [LibraryNote]
    public var tags: [LibraryTag]
    public var dailyNoteCount: Int?

    public init(
        notes: [LibraryNote], tags: [LibraryTag] = [], dailyNoteCount: Int? = nil
    ) {
        self.notes = notes
        self.tags = tags
        self.dailyNoteCount = dailyNoteCount
    }
}

public enum LibraryLoadState: Equatable, Sendable {
    case loading
    case ready
    case offline
    case failed(message: String)
    case reconnectRequired(message: String)
    case signedOut
}

@MainActor @Observable
public final class LibraryModel {
    public var snapshot: LibrarySnapshot
    public private(set) var hasKnownGistSnapshot: Bool
    public var loadState: LibraryLoadState
    public var gitHubStatus: GitHubStatusState?
    public var collection: LibraryCollection = .gists
    public var query = ""
    public var selectedTagIDs: Set<String> = []
    public var selectedNoteID: String?
    public var today: LibraryTodaySummary
    public var searchState: LibrarySearchState = .inactive

    public init(
        snapshot: LibrarySnapshot? = nil, loadState: LibraryLoadState = .loading,
        today: LibraryTodaySummary = .init(date: .now)
    ) {
        self.snapshot = snapshot ?? .init(notes: [])
        hasKnownGistSnapshot = snapshot != nil
        self.loadState = loadState
        self.today = today
    }

    public var hasFilters: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedTagIDs.isEmpty
    }

    public var visibleCollections: [LibraryCollection] {
        LibraryCollection.allCases.filter { candidate in
            switch candidate {
            case .gists, .dailyNotes:
                true
            case .starred, .archive:
                candidate == collection
                    || (hasKnownGistSnapshot && snapshot.notes.contains {
                        $0.gistID != nil && Self.includes($0, in: candidate)
                    })
            }
        }
    }

    var showsSearchScope: Bool {
        hasFilters && (collection != .gists || !selectedTagIDs.isEmpty)
    }

    public var matchingNotes: [LibraryNote] {
        switch searchState {
        case .results(let notes, _): return notes
        case .searching, .failed: return []
        case .inactive: break
        }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.notes.filter { note in
            let isIncluded = hasFilters
                ? Self.primaryCollection(for: note) != nil : Self.includes(note, in: collection)
            return isIncluded && selectedTagIDs.isSubset(of: note.tagIDs)
                && (search.isEmpty || note.title.localizedStandardContains(search))
        }.sorted {
            if $0.updatedAt != $1.updatedAt {
                return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            return $0.id < $1.id
        }
    }

    public func replaceSnapshot(_ snapshot: LibrarySnapshot?) {
        self.snapshot = snapshot ?? .init(notes: [])
        hasKnownGistSnapshot = snapshot != nil
    }

    public var dailyNoteCount: Int? {
        hasKnownGistSnapshot ? snapshot.dailyNoteCount : nil
    }

    public var mainGistCount: Int? {
        count(in: .gists)
    }

    public func count(in collection: LibraryCollection) -> Int? {
        guard hasKnownGistSnapshot else { return nil }
        if collection == .dailyNotes { return dailyNoteCount }
        return Self.gistCount(in: snapshot.notes.filter { Self.includes($0, in: collection) })
    }

    var secondaryCollections: [LibraryCollection] {
        [.dailyNotes, .starred, .archive].filter { collection in
            count(in: collection) != 0
                && snapshot.notes.contains { Self.includes($0, in: collection) }
        }
    }

    public func unfilteredNotes(in collection: LibraryCollection) -> [LibraryNote] {
        Self.ordered(snapshot.notes.filter { Self.includes($0, in: collection) }, in: collection)
    }

    public func matchingNotes(in collection: LibraryCollection) -> [LibraryNote] {
        guard hasFilters else { return unfilteredNotes(in: collection) }
        let notes = matchingNotes.filter { Self.primaryCollection(for: $0) == collection }
        return collection == .dailyNotes ? Self.ordered(notes, in: collection) : notes
    }

    private static func primaryCollection(for note: LibraryNote) -> LibraryCollection? {
        LibraryCollection.allCases.first { includes(note, in: $0) }
    }

    private static func ordered(
        _ notes: [LibraryNote], in collection: LibraryCollection
    ) -> [LibraryNote] {
        notes.sorted {
            if collection == .dailyNotes {
                if $0.isOverdue != $1.isOverdue { return $0.isOverdue }
                if $0.dailyDate != $1.dailyDate {
                    return ($0.dailyDate ?? .distantPast) > ($1.dailyDate ?? .distantPast)
                }
            } else if $0.updatedAt != $1.updatedAt {
                return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            return $0.id < $1.id
        }
    }

    public var collectionGistCount: Int? {
        guard hasKnownGistSnapshot else { return nil }
        return Self.gistCount(in: snapshot.notes.filter { Self.includes($0, in: collection) })
    }

    public var resultGistCount: Int? {
        switch searchState {
        case .results(let notes, _): Self.gistCount(in: notes)
        case .inactive: hasFilters && hasKnownGistSnapshot ? Self.gistCount(in: matchingNotes) : nil
        case .searching, .failed: nil
        }
    }

    public static func gistCount(in notes: [LibraryNote]) -> Int {
        Set(notes.compactMap(\.gistID)).count
    }

    public static func gistCountLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 gist", bundle: .module)
            : String(localized: "\(count) gists", bundle: .module)
    }

    public static func noteCountLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 note", bundle: .module)
            : String(localized: "\(count) notes", bundle: .module)
    }

    private static func includes(_ note: LibraryNote, in collection: LibraryCollection) -> Bool {
        switch collection {
        case .gists: !note.isArchived && !note.isDailyNote && note.isOwned
        case .dailyNotes: note.isDailyNote && !note.isArchived && note.isOwned
        case .starred: note.isStarred && !note.isArchived
        case .archive: note.isArchived && note.isOwned
        }
    }

    public var pinnedNotes: [LibraryNote] { matchingNotes.filter(\.isPinned) }
    public var unpinnedNotes: [LibraryNote] { matchingNotes.filter { !$0.isPinned } }

    var showsFeaturedNotes: Bool {
        guard collection == .gists, !hasFilters else { return false }
        if case .inactive = searchState { return true }
        return false
    }

    var featuredNotes: [LibraryNote] { showsFeaturedNotes ? pinnedNotes : [] }
    var listedNotes: [LibraryNote] { showsFeaturedNotes ? unpinnedNotes : matchingNotes }
    var showsListedNotesHeading: Bool {
        collection == .gists || hasFilters
    }

    public var visibleSelectedNoteID: String? {
        guard let selectedNoteID,
              (hasFilters ? matchingNotes : snapshot.notes).contains(where: {
                  $0.id == selectedNoteID && Self.primaryCollection(for: $0) != nil
              }) else { return nil }
        return selectedNoteID
    }

    public func clearFilters() {
        query = ""
        selectedTagIDs = []
    }

    public func tags(for note: LibraryNote) -> [LibraryTag] {
        snapshot.tags.filter { note.tagIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
