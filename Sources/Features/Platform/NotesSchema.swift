import AppIntents
import Foundation

@AppEntity(schema: .notes.account)
public struct GistAccountEntity: Identifiable {
    public static let defaultQuery = GistAccountQuery()
    public let id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

public struct GistAccountQuery: EntityQuery {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Dependency private var dailyNotes: any DailyNoteActions
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [GistAccountEntity] {
        guard let id = try await notesSnapshot(validating: dailyNotes)?.accountID,
              identifiers.contains(id) else { return [] }
        return [GistAccountEntity(id: id, name: "GitHub")]
    }
}

@AppEntity(schema: .notes.folder)
public struct GistFolderEntity: Identifiable {
    public static let defaultQuery = GistFolderQuery()
    public let id: String
    public var name: String
    let accountID: UUID?
    public var parentFolder: GistFolderEntity? { nil }
    public var account: GistAccountEntity? {
        accountID.map { GistAccountEntity(id: $0, name: "GitHub") }
    }

    public init(id: String, name: String, accountID: UUID?) {
        self.id = id
        self.accountID = accountID
        self.name = name
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

public struct GistFolderQuery: EntityStringQuery {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Dependency private var dailyNotes: any DailyNoteActions
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [GistFolderEntity] {
        try await folders().filter { identifiers.contains($0.id) }
    }

    public func suggestedEntities() async throws -> [GistFolderEntity] {
        try await Array(folders().prefix(12))
    }

    public func entities(matching string: String) async throws -> [GistFolderEntity] {
        try await folders().filter { $0.name.localizedStandardContains(string) }
    }

    private func folders() async throws -> [GistFolderEntity] {
        let notes = try await notesSnapshot(validating: dailyNotes)?.gists ?? []
        return Dictionary(
            notes.compactMap(\.folder).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.name < $1.name }
    }
}

func notesSnapshot(validating actions: any DailyNoteActions) async throws -> LibrarySnapshot? {
    let snapshot = try LibrarySnapshot.read()
    if let accountID = snapshot?.accountID {
        try await actions.validateAccount(accountID)
    }
    return snapshot
}
