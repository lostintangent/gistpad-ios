import Foundation
#if os(iOS)
import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers
#endif

public struct GistEntity: Codable, Equatable, Identifiable, Sendable {
    public var id: String { route.url.absoluteString }
    let title: String
    let excerpt: String?
    let tags: [String]
    let updatedAt: Date?
    let route: NotebookRoute
}

#if os(iOS)
extension GistEntity: IndexedEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Gist")
    public static let defaultQuery = GistEntityQuery()

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)", subtitle: excerpt.map { "\($0)" },
            image: .init(systemName: "doc.text"))
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = excerpt
        attributes.keywords = tags
        attributes.contentModificationDate = updatedAt
        attributes.contentURL = route.url
        return attributes
    }
}

public struct GistEntityQuery: EntityStringQuery, IndexedEntityQuery {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Dependency private var notebook: any NotebookIntentServing
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [GistEntity] {
        try await currentSnapshot()?.gists.filter { identifiers.contains($0.id) } ?? []
    }

    public func suggestedEntities() async throws -> [GistEntity] {
        try await Array(currentSnapshot()?.gists.prefix(12) ?? [])
    }

    public func entities(matching string: String) async throws -> [GistEntity] {
        let terms = string.split(whereSeparator: \.isWhitespace).map(String.init)
        return try await currentSnapshot()?.gists.filter { gist in
            let content = ([gist.title] + gist.tags).joined(separator: " ")
            return terms.allSatisfy { content.localizedStandardContains($0) }
        } ?? []
    }

    public func reindexEntities(
        for identifiers: [String], indexDescription: CSSearchableIndexDescription
    ) async throws {
        try await NotebookEntityIndex.index.indexAppEntities(entities(for: identifiers))
    }

    public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await NotebookEntityIndex.index.indexAppEntities(currentSnapshot()?.gists ?? [])
    }

    private func currentSnapshot() async throws -> NotebookSystemSnapshot? {
        let snapshot = try SharedNotebookStore().read()
        if let accountID = snapshot?.accountID {
            try await notebook.validateAccount(accountID)
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
        let currentIDs = Set(current.gists.map(\.id))
        if let indexedIDs {
            let removed = indexedIDs.subtracting(currentIDs)
            if !removed.isEmpty {
                try await Self.index.deleteAppEntities(
                    identifiedBy: Array(removed), ofType: GistEntity.self)
            }
        } else {
            try await Self.index.deleteAllSearchableItems()
        }
        indexedIDs = nil
        try await Self.index.indexAppEntities(current.gists)
        indexedIDs = currentIDs
    }
}

public struct OpenNoteIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open Note"
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Gist") public var target: GistEntity
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        NotebookRouteInbox.shared.submit(target.route)
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
