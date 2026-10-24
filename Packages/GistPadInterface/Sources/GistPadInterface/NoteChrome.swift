import Foundation

public enum NoteMode: String, Sendable {
    case reading, source
}

public struct NoteFile: Equatable, Identifiable, Sendable {
    public let id: String
    public let filename: String
    public let date: Date?

    public init(id: String, filename: String, date: Date? = nil) {
        self.id = id
        self.filename = filename
        self.date = date
    }
}

public enum NoteSaveState: Equatable, Sendable {
    case inMemoryFixture
    case unsaved
    case savedLocally
    case savingToGitHub
    case savedToGitHub
    case cloudFailure(message: String)
    case localFailure(message: String)
    case remoteChange
    case reconnectRequired
    case creationUncertain
    case publicationUncertain
    case publicationBlocked(message: String)

    public var canPublish: Bool {
        switch self {
        case .unsaved, .savedLocally, .cloudFailure: true
        default: false
        }
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

    public init(
        title: String, files: [NoteFile], selectedFileID: String,
        access: NoteAccess = .editable, isPinned: Bool = false,
        isStarred: Bool = false, isArchived: Bool = false, tags: [LibraryTag] = [],
        isAutoSaveEnabled: Bool = false
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
    }
}

@MainActor
public struct NoteActions {
    public var save: (() -> Void)?
    public var retry: (() -> Void)?
    public var reconnect: (() -> Void)?
    public var reviewChanges: (() -> Void)?
    public var share: (() -> Void)?
    public var copyLink: (() -> Void)?
    public var openInGitHub: (() -> Void)?
    public var focus: (() -> Void)?
    public var tags: (() -> Void)?
    public var rename: (() -> Void)?
    public var renameFile: (() -> Void)?
    public var togglePin: (() -> Void)?
    public var toggleStar: (() -> Void)?
    public var toggleArchive: (() -> Void)?
    public var delete: (() -> Void)?
    public var selectFile: ((String) -> Void)?
    public var addFile: (() -> Void)?
    public var didChangeMode: ((NoteMode) -> Void)?

    public init() {}
}
