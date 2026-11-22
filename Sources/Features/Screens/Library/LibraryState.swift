import Foundation
import Store
import Observation

public enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case gists, dailyNotes, starred
    /// Expanded sections are saved by raw value, so Archived keeps its original one.
    case archived = "archive"

    public var id: Self { self }

    var title: String {
        switch self {
        case .gists: String(localized: "Your Gists", bundle: .module)
        case .dailyNotes: String(localized: "Daily Notes", bundle: .module)
        case .starred: String(localized: "Starred Gists", bundle: .module)
        case .archived: String(localized: "Archived Gists", bundle: .module)
        }
    }

    var symbol: String {
        switch self {
        case .gists: "doc.text"
        case .dailyNotes: "calendar"
        case .starred: "star"
        case .archived: "archivebox"
        }
    }
}

public struct GistItem: Equatable, Identifiable, Sendable {
    public let id: String
    public var gistID: String?
    public var title: String
    public var updatedAt: Date?
    public var owner: String?
    public var isOwned: Bool
    public var isDeletedOnGitHub: Bool
    public var isSecret: Bool
    public var isPinned: Bool
    public var isStarred: Bool
    public var isArchived: Bool
    public var isDailyNote: Bool
    public var tagIDs: Set<String>
    public var filename: String?
    public var progress: TaskProgress?
    public var isOverdue: Bool
    public var dailyDate: Date?
    public var fileCount: Int
    public var commentCount: Int?

    public var visibleFileCount: Int? { fileCount > 1 ? fileCount : nil }

    var supportsComments: Bool { gistID != nil && !isDailyNote }

    /// Pin and Archive organize whole gists. A daily note is one file, so it only deletes.
    var canPinAndArchive: Bool { isOwned && !isDeletedOnGitHub && !isDailyNote }

    /// A daily note reads as its day, "Friday, Nov 6".
    func displayTitle(now: Date, locale: Locale, calendar: Calendar) -> String {
        guard isDailyNote, let dailyDate else { return title }
        return DailyNote.title(for: dailyDate, relativeTo: now, locale: locale, calendar: calendar)
    }

    var visibleCommentCount: Int? {
        guard supportsComments, let commentCount, commentCount > 0 else { return nil }
        return commentCount
    }

    public init(
        id: String, title: String, updatedAt: Date?, gistID: String? = nil, owner: String? = nil,
        isOwned: Bool = true, isDeletedOnGitHub: Bool = false,
        isSecret: Bool = true, isPinned: Bool = false,
        isStarred: Bool = false, isArchived: Bool = false, isDailyNote: Bool = false,
        tagIDs: Set<String> = [], filename: String? = nil,
        progress: TaskProgress? = nil, isOverdue: Bool = false, dailyDate: Date? = nil,
        fileCount: Int = 1, commentCount: Int? = nil
    ) {
        self.id = id
        self.gistID = gistID
        self.title = title
        self.updatedAt = updatedAt
        self.owner = owner
        self.isOwned = isOwned
        self.isDeletedOnGitHub = isDeletedOnGitHub
        self.isSecret = isSecret
        self.isPinned = isPinned
        self.isStarred = isStarred
        self.isArchived = isArchived
        self.isDailyNote = isDailyNote
        self.tagIDs = tagIDs
        self.filename = filename
        self.progress = progress
        self.isOverdue = isOverdue
        self.dailyDate = dailyDate
        self.fileCount = fileCount
        self.commentCount = commentCount
    }
}

extension DailyNote {
    /// The day as a daily note's title, with its year only when it isn't this year's.
    static func title(for day: Date, relativeTo now: Date, locale: Locale, calendar: Calendar) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.abbreviated).day()
        return day.formatted(calendar.isDate(day, equalTo: now, toGranularity: .year) ? style : style.year())
    }
}

@MainActor @Observable
public final class LibraryState {
    public var gists: [GistItem]
    public private(set) var tags: [Tag]
    /// Nil until the account's gists are known, and while the daily gist is too large to count.
    public private(set) var dailyNoteCount: Int?
    private(set) var hasKnownGists: Bool
    public var query = ""
    public var selectedTagIDs: Set<String> = []
    public var selectedID: String?
    public var today: DailyNote

    /// Nil gists mean the account's gists aren't known yet.
    public init(
        gists: [GistItem]? = nil, tags: [Tag] = [], dailyNoteCount: Int? = nil,
        today: DailyNote = .init()
    ) {
        self.gists = gists ?? []
        self.tags = tags
        self.dailyNoteCount = gists == nil ? nil : dailyNoteCount
        hasKnownGists = gists != nil
        self.today = today
    }

    var hasFilters: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedTagIDs.isEmpty
    }

    /// Like the web, a filter matches titles and tags, and the open gist stays listed.
    var matchingGists: [GistItem] {
        Self.ordered(gists.filter { gist in
            hasFilters
                ? Self.primarySection(for: gist) != nil && (gist.id == selectedID || matchesFilter(gist))
                : Self.includes(gist, in: .gists)
        }, in: .gists)
    }

    /// Until the account's gists are `known`, only gists still on the phone are listed and nothing is counted.
    public func replace(gists: [GistItem], tags: [Tag] = [], dailyNoteCount: Int? = nil, known: Bool = true) {
        self.gists = gists
        self.tags = tags
        self.dailyNoteCount = known ? dailyNoteCount : nil
        hasKnownGists = known
    }

    func count(in section: LibrarySection) -> Int? {
        guard hasKnownGists else { return nil }
        if section == .dailyNotes { return dailyNoteCount }
        return Self.gistCount(in: gists.filter { Self.includes($0, in: section) })
    }

    var secondarySections: [LibrarySection] {
        [.dailyNotes, .starred, .archived].filter { section in
            count(in: section) != 0
                && gists.contains { Self.includes($0, in: section) }
        }
    }

    func matchingGists(in section: LibrarySection) -> [GistItem] {
        guard hasFilters else { return Self.ordered(gists.filter { Self.includes($0, in: section) }, in: section) }
        let gists = matchingGists.filter { Self.primarySection(for: $0) == section }
        return section == .dailyNotes ? Self.ordered(gists, in: section) : gists
    }

    private static func primarySection(for gist: GistItem) -> LibrarySection? {
        LibrarySection.allCases.first { includes(gist, in: $0) }
    }

    private static func ordered(
        _ gists: [GistItem], in section: LibrarySection
    ) -> [GistItem] {
        gists.sorted {
            if section == .dailyNotes {
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

    /// Gists the filter matches. The open gist is listed without counting as a match.
    var resultGistCount: Int? {
        guard hasFilters, hasKnownGists else { return nil }
        return Self.gistCount(in: matchingGists.filter(matchesFilter))
    }

    /// Whether anything besides the open gist matches the filter.
    var hasMatches: Bool { matchingGists.contains(where: matchesFilter) }

    private func matchesFilter(_ gist: GistItem) -> Bool {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return selectedTagIDs.isSubset(of: gist.tagIDs)
            && (search.isEmpty || gist.title.localizedStandardContains(search))
    }

    /// Gists carrying the tag, counted over the same gists a tag filter searches.
    func gistCount(tagged tagID: String) -> Int {
        Self.gistCount(in: gists.filter {
            $0.tagIDs.contains(tagID) && Self.primarySection(for: $0) != nil
        })
    }

    static func gistCount(in gists: [GistItem]) -> Int {
        Set(gists.compactMap(\.gistID)).count
    }

    static func gistCountLabel(_ count: Int) -> String {
        String(localized: "\(count) gists", bundle: .module)
    }

    static func dailyNoteCountLabel(_ count: Int) -> String {
        String(localized: "\(count) daily notes", bundle: .module)
    }

    private static func includes(_ gist: GistItem, in section: LibrarySection) -> Bool {
        switch section {
        case .gists: !gist.isArchived && !gist.isDailyNote && gist.isOwned
        case .dailyNotes: gist.isDailyNote && !gist.isArchived && gist.isOwned
        case .starred: gist.isStarred && !gist.isOwned
        case .archived: gist.isArchived && gist.isOwned
        }
    }

    public func clearFilters() {
        query = ""
        selectedTagIDs = []
    }

    func tags(for gist: GistItem) -> [Tag] {
        tags.filter { gist.tagIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
