import Foundation
import Sync

/// Layout preferences save modes by raw value, so Preview and Edit keep their original ones.
public enum FileMode: String, Sendable {
    case preview = "reading"
    case edit = "source"
    case split
}

extension PublishState {
    /// The file hasn't reached GitHub, and nothing needs you before it can.
    public var canPublish: Bool {
        switch self {
        case .savedLocally, .failed(.network), .failed(.http): true
        default: false
        }
    }

    /// Publish shows when autosave is off or a publish that can be retried didn't land.
    func showsPublish(isAutoSaveEnabled: Bool) -> Bool {
        if case .failed = self, canPublish { return true }
        return !isAutoSaveEnabled
    }
}

public enum FileAccess: Equatable, Sendable {
    case editable
    case readOnly

    public var canEdit: Bool { self == .editable }
}

public struct GistDetails: Equatable, Sendable {
    public struct File: Equatable, Identifiable, Sendable {
        public let id: String
        public let filename: String

        public init(id: String, filename: String) {
            self.id = id
            self.filename = filename
        }
    }

    public var title: String
    public var files: [File]
    public var selectedFileID: String
    public var access: FileAccess
    public var isPinned: Bool
    public var isStarred: Bool
    public var isArchived: Bool
    public var isDailyNote: Bool
    public var tags: [Tag]
    public var isAutoSaveEnabled: Bool
    public var commentCount: Int?
    /// The gistpad.dev link to this file, once it's on GitHub.
    public var shareURL: URL?

    var headerFilename: String? {
        guard files.count > 1,
              let filename = files.first(where: { $0.id == selectedFileID })?.filename,
              filename.caseInsensitiveCompare("README.md") != .orderedSame else { return nil }
        return filename
    }

    public init(
        title: String, files: [File], selectedFileID: String,
        access: FileAccess = .editable, isPinned: Bool = false,
        isStarred: Bool = false, isArchived: Bool = false, isDailyNote: Bool = false, tags: [Tag] = [],
        isAutoSaveEnabled: Bool = false, commentCount: Int? = nil, shareURL: URL? = nil
    ) {
        self.title = title
        self.files = files
        self.selectedFileID = selectedFileID
        self.access = access
        self.isPinned = isPinned
        self.isStarred = isStarred
        self.isArchived = isArchived
        self.isDailyNote = isDailyNote
        self.tags = tags
        self.isAutoSaveEnabled = isAutoSaveEnabled
        self.commentCount = commentCount
        self.shareURL = shareURL
    }
}

/// Actions every gist has. Optional members are capabilities only some gists have.
@MainActor
public struct GistActions {
    public var save: () -> Void = {}
    public var reconnect: () -> Void = {}
    public var reviewChanges: () -> Void = {}
    public var find: () -> Void = {}
    public var intelligence: () -> Void = {}
    public var openInGitHub: (() -> Void)?
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

    /// A daily note is a file, not a gist. It switches days, shares and deletes,
    /// but nothing pins, stars, archives, tags or renames the gist around it.
    var dailyNote: GistActions {
        var actions = self
        actions.togglePin = nil
        actions.toggleStar = nil
        actions.toggleArchive = nil
        actions.tags = nil
        actions.rename = nil
        actions.renameFile = nil
        actions.addFile = nil
        return actions
    }
}
