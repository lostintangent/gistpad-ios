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
    public var title: String
    public var updatedAt: Date
    public var owner: String?
    public var isOwned: Bool
    public var isSecret: Bool
    public var isPinned: Bool
    public var isStarred: Bool
    public var isArchived: Bool
    public var isDailyNote: Bool
    public var tagIDs: Set<String>
    public var filename: String?
    public var excerpt: String?
    public var progress: LibraryTaskProgress?
    public var isOverdue: Bool

    public init(
        id: String, title: String, updatedAt: Date, owner: String? = nil,
        isOwned: Bool = true, isSecret: Bool = true, isPinned: Bool = false,
        isStarred: Bool = false, isArchived: Bool = false, isDailyNote: Bool = false,
        tagIDs: Set<String> = [], filename: String? = nil, excerpt: String? = nil,
        progress: LibraryTaskProgress? = nil, isOverdue: Bool = false
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.owner = owner
        self.isOwned = isOwned
        self.isSecret = isSecret
        self.isPinned = isPinned
        self.isStarred = isStarred
        self.isArchived = isArchived
        self.isDailyNote = isDailyNote
        self.tagIDs = tagIDs
        self.filename = filename
        self.excerpt = excerpt
        self.progress = progress
        self.isOverdue = isOverdue
    }
}

public struct LibrarySnapshot: Equatable, Sendable {
    public var notes: [LibraryNote]
    public var tags: [LibraryTag]

    public init(notes: [LibraryNote], tags: [LibraryTag] = []) {
        self.notes = notes
        self.tags = tags
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
    public var loadState: LibraryLoadState
    public var collection: LibraryCollection = .gists
    public var query = ""
    public var selectedTagIDs: Set<String> = []
    public var selectedNoteID: String?
    public var today: LibraryTodaySummary
    public var searchState: LibrarySearchState = .inactive

    public init(
        snapshot: LibrarySnapshot = .init(notes: []), loadState: LibraryLoadState = .loading,
        today: LibraryTodaySummary = .init(date: .now)
    ) {
        self.snapshot = snapshot
        self.loadState = loadState
        self.today = today
    }

    public var hasFilters: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedTagIDs.isEmpty
    }

    public var matchingNotes: [LibraryNote] {
        switch searchState {
        case .results(let notes, _): return notes
        case .searching, .failed: return []
        case .inactive: break
        }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.notes.filter { note in
            let inCollection: Bool
            switch collection {
            case .gists: inCollection = !note.isArchived && !note.isDailyNote && note.isOwned
            case .dailyNotes: inCollection = note.isDailyNote && !note.isArchived && note.isOwned
            case .starred: inCollection = note.isStarred && !note.isArchived
            case .archive: inCollection = note.isArchived && note.isOwned
            }
            return inCollection && selectedTagIDs.isSubset(of: note.tagIDs)
                && (search.isEmpty || note.title.localizedStandardContains(search))
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    public var pinnedNotes: [LibraryNote] { matchingNotes.filter(\.isPinned) }
    public var unpinnedNotes: [LibraryNote] { matchingNotes.filter { !$0.isPinned } }

    public var openDocumentOutsideFilter: LibraryNote? {
        guard let selectedNoteID,
              !matchingNotes.contains(where: { $0.id == selectedNoteID }) else { return nil }
        return snapshot.notes.first { $0.id == selectedNoteID }
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
