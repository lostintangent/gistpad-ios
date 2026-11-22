import Foundation
import Store

/// Layout preferences save modes by raw value, so Preview and Edit keep their original ones.
public enum FileMode: String, Sendable {
    case preview = "reading"
    case edit = "source"
    case split
}

/// Where the open file stands with GitHub.
public enum PublishStatus: Equatable, Sendable {
    case published
    /// Saved on this iPhone, with text GitHub doesn't have yet.
    case unpublished
    case publishing
    /// GitHub's text moved past the draft's base, and you choose what to keep.
    case conflict
    case failed(GitHubProblem)

    /// The file hasn't reached GitHub, and nothing needs you before it can.
    public var canPublish: Bool {
        switch self {
        case .unpublished, .failed(.offline): true
        default: false
        }
    }
}

public struct GistDetails: Equatable, Sendable {
    public var title: String
    public var filenames: [String]
    /// The open file.
    public var filename: String
    /// Your own gist, which you can edit, rather than one you starred.
    public var isOwned: Bool
    public var isPinned: Bool
    public var isStarred: Bool
    public var isArchived: Bool
    public var isDailyNote: Bool
    public var commentCount: Int?
    /// The gistpad.dev link to this file, once it's on GitHub.
    public var shareURL: URL?

    /// A daily note reads as its day, exactly like its Library row.
    func displayTitle(now: Date, locale: Locale, calendar: Calendar) -> String {
        guard isDailyNote, let day = DailyNote.date(filename: filename) else { return title }
        return DailyNote.title(for: day, relativeTo: now, locale: locale, calendar: calendar)
    }

    /// The file among several, except README.md. A daily note's title already names its day.
    var headerFilename: String? {
        guard !isDailyNote, filenames.count > 1,
              filename.caseInsensitiveCompare("README.md") != .orderedSame else { return nil }
        return filename
    }

    public init(
        title: String, filenames: [String], filename: String,
        isOwned: Bool = true, isPinned: Bool = false,
        isStarred: Bool = false, isArchived: Bool = false, isDailyNote: Bool = false,
        commentCount: Int? = nil, shareURL: URL? = nil
    ) {
        self.title = title
        self.filenames = filenames
        self.filename = filename
        self.isOwned = isOwned
        self.isPinned = isPinned
        self.isStarred = isStarred
        self.isArchived = isArchived
        self.isDailyNote = isDailyNote
        self.commentCount = commentCount
        self.shareURL = shareURL
    }
}

/// Actions every gist has. Optional members are capabilities only some gists have.
public struct GistActions {
    public var reconnect: () -> Void = {}
    public var reviewChanges: () -> Void = {}
    public var find: () -> Void = {}
    public var intelligence: () -> Void = {}
    public var comments: (() -> Void)?
    public var tags: (() -> Void)?
    public var rename: (() -> Void)?
    public var renameFile: (() -> Void)?
    public var togglePin: (() -> Void)?
    public var toggleStar: (() -> Void)?
    public var toggleArchive: (() -> Void)?
    public var delete: (() -> Void)?
    public var selectFile: ((String) -> Void)?
    public var addFile: (() -> Void)?

    public init() {}
}
