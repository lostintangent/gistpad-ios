#if os(iOS)
import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

public struct NoteEntity: IndexedEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Note")
    public static let defaultQuery = NoteEntityQuery()
    public let note: SystemNote
    public var id: String { note.id }

    public init(note: SystemNote) { self.note = note }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(note.title)", subtitle: "\(note.filename)",
            image: .init(systemName: "doc.text"))
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = note.title
        attributes.displayName = note.title
        attributes.contentDescription = note.excerpt
        attributes.keywords = note.tags + [note.filename]
        attributes.contentModificationDate = note.updatedAt
        attributes.contentURL = note.route.url
        return attributes
    }
}

public struct NoteEntityQuery: EntityStringQuery, IndexedEntityQuery {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [NoteEntity] {
        let notes = try await currentSnapshot()?.notes ?? []
        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        return identifiers.compactMap { byID[$0].map(NoteEntity.init) }
    }

    public func suggestedEntities() async throws -> [NoteEntity] {
        try await currentSnapshot()?.notes.prefix(12).map(NoteEntity.init) ?? []
    }

    public func entities(matching string: String) async throws -> [NoteEntity] {
        let terms = string.split(whereSeparator: \.isWhitespace).map(String.init)
        return try await currentSnapshot()?.notes.filter { note in
            let content = ([note.title, note.filename] + note.tags).joined(separator: " ")
            return terms.allSatisfy { content.localizedStandardContains($0) }
        }.map(NoteEntity.init) ?? []
    }

    public func reindexEntities(
        for identifiers: [String], indexDescription: CSSearchableIndexDescription
    ) async throws {
        try await NotebookEntityIndex.index.indexAppEntities(entities(for: identifiers))
    }

    public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        let notes = try await currentSnapshot()?.notes ?? []
        try await NotebookEntityIndex.index.indexAppEntities(notes.map(NoteEntity.init))
    }

    private func currentSnapshot() async throws -> NotebookSystemSnapshot? {
        let snapshot = try SharedNotebookStore().read()
        if let accountID = snapshot?.accountID {
            try await NotebookIntentRuntime.service().validateAccount(accountID)
        }
        return snapshot
    }
}

public actor NotebookEntityIndex {
    public static let shared = NotebookEntityIndex()
    private var indexedIDs: Set<String>?
    private var operation: Task<Void, any Error>?
    static var index: CSSearchableIndex {
        CSSearchableIndex(name: "GistPadNotes", protectionClass: .complete)
    }

    public func update(_ current: NotebookSystemSnapshot) async throws {
        let previousOperation = operation
        let task = Task {
            if let previousOperation { _ = await previousOperation.result }
            try await replaceIndex(with: current)
        }
        operation = task
        try await task.value
    }

    private func replaceIndex(with current: NotebookSystemSnapshot) async throws {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let currentIDs = Set(current.notes.map(\.id))
        if let indexedIDs {
            let removed = indexedIDs.subtracting(currentIDs)
            if !removed.isEmpty {
                try await Self.index.deleteAppEntities(
                    identifiedBy: Array(removed), ofType: NoteEntity.self)
            }
        } else {
            try await Self.index.deleteAppEntities(ofType: NoteEntity.self)
        }
        indexedIDs = nil
        try await Self.index.indexAppEntities(current.notes.map(NoteEntity.init))
        indexedIDs = currentIDs
    }
}

public struct OpenNoteIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open Note"
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Note") public var target: NoteEntity
    public init() {}
    public init(note: NoteEntity) { target = note }

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await NotebookIntentRuntime.service().validateAccount(target.note.accountID)
        let snapshot = try SharedNotebookStore().read()
        guard snapshot?.accountID == target.note.accountID else {
            throw NotebookPlatformError.accountChanged
        }
        guard snapshot?.notes.contains(where: { $0.id == target.id }) == true else {
            throw NotebookPlatformError.noteUnavailable
        }
        NotebookRouteInbox.shared.submit(target.note.route)
        return .result()
    }
}

public struct OpenTodayIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Today"
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        NotebookRouteInbox.shared.submit(.today)
        return .result()
    }
}

public struct GistPadPlatformIntents: AppIntentsPackage {}
#endif
