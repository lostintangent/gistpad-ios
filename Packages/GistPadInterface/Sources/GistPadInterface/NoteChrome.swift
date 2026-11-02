import Foundation
import GistPadSync

public enum NoteMode: String, Sendable {
    case reading, source, split
}

public struct NoteFile: Equatable, Identifiable, Sendable {
    public let id: String
    public let filename: String

    public init(id: String, filename: String) {
        self.id = id
        self.filename = filename
    }
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

public enum NoteAccess: Equatable, Sendable {
    case editable
    case readOnly
    case truncated

    public var canEdit: Bool { self == .editable }
}

public struct NoteChrome: Equatable, Sendable {
    public var title: String
    public var files: [NoteFile]
    public var selectedFileID: String
    public var access: NoteAccess
    public var isPinned: Bool
    public var isStarred: Bool
    public var isArchived: Bool
    public var tags: [LibraryTag]
    public var isAutoSaveEnabled: Bool
    public var commentCount: Int?

    var headerFilename: String? {
        guard files.count > 1,
              let filename = files.first(where: { $0.id == selectedFileID })?.filename,
              filename.caseInsensitiveCompare("README.md") != .orderedSame else { return nil }
        return filename
    }

    public init(
        title: String, files: [NoteFile], selectedFileID: String,
        access: NoteAccess = .editable, isPinned: Bool = false,
        isStarred: Bool = false, isArchived: Bool = false, tags: [LibraryTag] = [],
        isAutoSaveEnabled: Bool = false, commentCount: Int? = nil
    ) {
        self.title = title
        self.files = files
        self.selectedFileID = selectedFileID
        self.access = access
        self.isPinned = isPinned
        self.isStarred = isStarred
        self.isArchived = isArchived
        self.tags = tags
        self.isAutoSaveEnabled = isAutoSaveEnabled
        self.commentCount = commentCount
    }
}

/// Actions every note has. Optional members are capabilities only some gists have.
@MainActor
public struct NoteActions {
    public var save: () -> Void = {}
    public var reconnect: () -> Void = {}
    public var reviewChanges: () -> Void = {}
    public var share: () -> Void = {}
    public var copyLink: () -> Void = {}
    public var focus: () -> Void = {}
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
}
